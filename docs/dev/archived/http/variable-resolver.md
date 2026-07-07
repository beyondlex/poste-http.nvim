# HTTP 变量解析统一方案

## 1. 背景

### 当前问题

Poste 目前有 9 种变量机制，分布在 **3 个独立的解析器**中：

| 解析路径 | 位置 | 覆盖的变量源 |
|----------|------|-------------|
| 实际执行（Rust） | `parser.rs:substitute_vars()` | 注入 @var + 文件 @var + env.json + magic |
| K 键查询 | `nav.lua:show_var_value()` | magic + client.global + script_vars + 文件 @var + env.json |
| `<leader>rc` 复制 | `copy.lua:collect_vars()` | 文件 @var + env.json + client.global + script_vars + magic |
| Verbose 预览 | `run.lua:build_pending_request()` | buffer @var + env.json（无注入） |

**四个路径查同一个变量，可能拿到四个不同的值。**

这不是实现细节差异——变量在 Lua 和 Rust 两侧各自解析，优先级顺序不一致，且部分路径不感知所有变量源。

### 根因

1. **双引擎架构** — Lua 和 Rust 各自维护一套变量解析逻辑，没有中央权威
2. **优先级定义不明确** — `client.global` 注入成 `@var` 行（最高优先级）vs 语义上"全局变量"不应覆盖显式文件定义
3. **注入机制耦合** — Rust 解析器不知道 `client.global` / `script_variables` 的存在，只能通过 Lua 注入的 `@var` 行间接感知
4. **K / copy / verbose 各自实现** — 没有复用，每次新增变量源都要改 3 个文件

---

## 2. 设计目标

1. **单一权威源** — 所有变量查询走同一个解析器，消除多值不一致
2. **符合直觉的优先级** — 作用域越窄优先级越高，类比编程语言
3. **全路径一致** — K 查询、`<leader>rc`、Verbose 预览、实际执行，查同一个变量得到同一个值
4. **向后兼容** — 已有的 `.http` 文件和 `env.json` 无须改动
5. **增量迁移** — 不需要一次性重写所有东西，可以分阶段上线

---

## 3. 变量优先级模型

### 核心原则：作用域越窄，优先级越高

```
 窄 ┌───────────────────────────────────────┐  高
    │  1. Import parameter overrides        │  ← 函数参数
    │     run #Login (@token=xyz)           │     调用者显式传递
    ├───────────────────────────────────────┤
    │  2. Request-local                     │  ← 局部变量
    │     pre-script request.variables.set  │     当前 ### 块内
    │     << prompt 选择值                  │     @var 定义
    ├───────────────────────────────────────┤
    │  3. File-level                        │  ← 模块常量
    │     @var 写在文件头部                 │     文件内共享
    ├───────────────────────────────────────┤
    │  4. Session/Global                    │  ← 全局变量
    │     client.global.set                 │     跨请求/跨文件
    ├───────────────────────────────────────┤
    │  5. Environment                       │  ← 环境配置
    │     env.json                          │     dev/staging/prod
    ├───────────────────────────────────────┤
 广 │  6. Magic (built-in)                  │  ← 内置函数
    │     $timestamp / $uuid / ...          │     运行时生成
    └───────────────────────────────────────┘  低
```

### 跨文件传参规则

```
file_a.http:
  run #Login (@env=staging, @timeout=30)

file_b.http:
  @timeout = 10         ← 文件级默认值

  ### Login
  POST {{host}}/login
  Content-Type: application/json

  {"timeout": {{timeout}}}
```

`run #Login (@env=staging, @timeout=30)`：
  1. 从 file_a 读取 `import ./file_b.http`
  2. 解析 `#Login` 引用到 file_b.http 的 `### Login` 块
  3. 参数 `@timeout=30` 注入为 import-param 层（优先级 1）
  4. file_b 自身的 `@timeout = 10` 是 file-level（优先级 3）
  5. 解析 `{{timeout}}` → 命中 import-param → `30`
  6. 如果 `run #Login` 不传 `@timeout`，则 fallback 到 file_b 的 `@timeout = 10`

**类比编程语言：**
- Import params → 函数实参
- Request-local → 函数内局部变量
- File-level → 函数默认参数
- Session/Global → 进程全局变量
- Environment → 环境变量
- Magic → 语言内置函数

### Cross-request refs 独立路径

`{{Login.res.body.token}}` **不参与优先级链**。它的语义是"显式引用另一个请求的响应"，单独解析：

```
遇到 {{Name.res.body.X}}
  → 如果 cache 中有 Name 块的响应 → 提取 body.X 的值
  → 如果 cache 中没有 → 顺序执行 Name 块（已有机制）
  → 直接用该值替换，不经过优先级查找
```

---

## 4. 统一解析器架构

### CLI 新增子命令

```
poste resolve --help
Usage: poste resolve [OPTIONS]

Options:
  --file <PATH>          .http 文件路径
  --block <LINE>         目标 ### 块所在行号
  --var <NAME>           解析单个变量（用于 K 键查询）
  --format <FORMAT>      输出格式：value | content | verbose | curl
  --import-params <JSON> 导入参数, {"key": "value"}
  --session-vars <JSON>  client.global 变量表
  --script-vars <JSON>   script_variables 表
  --env <NAME>           环境名称
```

### 使用场景

```
# K 键查询单个变量
poste resolve --file requests.http --block 42 --var session_id \
  --session-vars '{"session_id":"sess-123"}' \
  --env dev
→ {"value": "sess-123", "source": "session/global"}
→ "sess-123"                    ← 纯文本模式

# <leader>rc 复制 curl
poste resolve --file requests.http --block 42 \
  --format curl \
  --session-vars '{"session_id":"sess-123"}' \
  --env dev
→ curl -X GET https://api.example.com/get?session=sess-123 ...

# Verbose 预览
poste resolve --file requests.http --block 42 \
  --format verbose \
  --session-vars '{"session_id":"sess-123"}' \
  --env dev
→ GET https://api.example.com/get?session=sess-123
  Headers: ...
  Body: ...

# 实际执行（复用已有逻辑）
poste run requests.http --line 42 --stdin ...
```

### Lua 侧变更

所有查询路径统一调用 `poste resolve`，消除自身解析逻辑：

```
K 键 (nav.lua:show_var_value)
  → 删除 50 行自解析代码
  → 改为 vim.system({"poste resolve", "--file", ..., "--var", ...})
  → 显示返回的值 + source 标签

<leader>rc (copy.lua:copy_as_curl)
  → 删除 100 行自解析代码
  → 改为 vim.system({"poste resolve", "--file", ..., "--format", "curl"})
  → 直接使用返回的 curl 命令

Verbose 预览 (run.lua:build_pending_request + format.lua:format_verbose)
  → 删除 build_pending_request 中的自解析逻辑
  → 捕获 poste run 之前的 resolved content 用于显示

import 传参 (import.lua:apply_variable_overrides)
  → 仍保留 Lua 侧注入 @var 行逻辑
  → 但 `poste resolve` 通过 --import-params 感知这些参数
```

### Rust 侧变更

Parser 新增优先级层级：

```rust
// 变量解析器（新增 poste resolve 子命令共享）
struct VarResolver {
    // 按优先级排序的变量源
    import_params: HashMap<String, String>,  // 层级 1
    request_vars: HashMap<String, String>,   // 层级 2（原 block @var + 注入 @var）
    file_vars: HashMap<String, String>,      // 层级 3
    session_vars: HashMap<String, String>,   // 层级 4（从 Lua 传入）
    script_vars: HashMap<String, String>,    // 层级 4（从 Lua 传入，与 session 同级）
    env: HashMap<String, String>,            // 层级 5
}

impl VarResolver {
    fn resolve(&self, name: &str) -> Option<&str> {
        // 按优先级顺序检查
        self.import_params.get(name)
            .or_else(|| self.request_vars.get(name))
            .or_else(|| self.file_vars.get(name))
            .or_else(|| self.session_vars.get(name))
            .or_else(|| self.script_vars.get(name))
            .or_else(|| self.env.get(name))
            .or_else(|| self.resolve_magic(name))   // 层级 6
    }
}
```

`poste run` 路径保持不变（仍然接受 stdin 注入的 @var 行），`poste resolve` 和 `poste run` 共享同一个 `VarResolver`。

---

## 5. 涉及变更的文件

### Rust

| 文件 | 变更 |
|------|------|
| `crates/poste-core/src/parser.rs` | 提取 `VarResolver`，新增 `session_vars` / `script_vars` / `import_params` 层级 |
| `crates/poste-cli/src/main.rs` | 新增 `resolve` 子命令 |
| `crates/poste-cli/src/run.rs` | `build_resolver()` 或重构 `substitute_vars()` 迁移到 `VarResolver` |
| `crates/poste-exec/src/executor.rs` | 无须变更（仍接收已解析的内容） |

### Lua

| 文件 | 变更 |
|------|------|
| `lua/poste/http/nav.lua` | `show_var_value()` → 调用 `poste resolve --var` |
| `lua/poste/http/copy.lua` | `copy_as_curl()` → 调用 `poste resolve --format curl` |
| `lua/poste/state.lua` | 保留 `global_vars` / `script_variables`（传递给 Rust） |
| `lua/poste/http/run.lua` | `build_pending_request()` 简化，只捕获内容 |

---

## 6. TDD 实施原则

整个迁移过程严格遵循测试驱动开发：

```
红 → 写一个会失败的测试（描述期望行为）
  ↓
绿 → 实现最小代码让测试通过
  ↓
重构 → 清理实现，保持测试绿
```

### 测试分类

| 层级 | 工具 | 位置 | 运行 |
|------|------|------|------|
| Rust 单元测试 | `#[cfg(test)]` | `crates/poste-core/src/parser.rs` + 新 `resolver.rs` | `cargo test` |
| Rust 集成测试 | `#[test]`（集成级） | `crates/poste-cli/tests/` | `cargo test --test *` |
| Lua 单元测试 | `tests/run.sh` (busted) | `tests/test_*.lua` | `tests/run.sh` |
| Lua 集成测试 | Lua 调 `poste resolve` 子进程 | `tests/test_*_spec.lua` | `tests/run.sh` |

### 编写测试的顺序

每个 phase 内的子任务按此顺序：

1. **定 fixture** — 准备好 `.http` 文件片段、`env.json`、`session_vars` JSON
2. **写测试** — 描述期望的解析结果（红）
3. **写实现** — 最小代码让测试通过（绿）
4. **查覆盖** — 边界情况：未定义变量、空传参、多层级同名变量

---

## 7. 迁移策略

### Phase 1：Rust 侧新增 `VarResolver`

**TDD 步骤：**

```
1. 写 `VarResolver` 结构体 + `new()` 方法（红：parser.rs 尚无此声明）
2. 写 resolve("simple_key") 返回 None（红 → 绿：空解析器）
3. 写每个层级的单元测试：
   ┌──────────────────────────────────────────────────┐
   │ #[test]                                          │
   │ fn import_params_highest_priority() {            │
   │   let r = VarResolver::new()                     │
   │     .with_import_params([("key", "import")])     │
   │     .with_request_vars([("key", "request")])     │
   │     .with_file_vars([("key", "file")])           │
   │     .with_session_vars([("key", "session")])     │
   │     .with_env_vars([("key", "env")]);            │
   │   assert_eq!(r.resolve("key"), Some("import"));  │
   │ }                                                │
   │                                                  │
   │ #[test]                                          │
   │ fn fallback_to_next_layer_when_missing() {       │
   │   let r = VarResolver::new()                     │
   │     .with_import_params([("a", "1")])            │
   │     .with_request_vars([("b", "2")]);            │
   │   assert_eq!(r.resolve("a"), Some("1"));         │
   │   assert_eq!(r.resolve("b"), Some("2"));         │
   │   assert_eq!(r.resolve("c"), None);              │
   │ }                                                │
   │                                                  │
   │ #[test]                                          │
   │ fn magic_var_fallback() { /* $timestamp 等 */ }  │
   └──────────────────────────────────────────────────┘
4. 移除 poste run 路径中重复的 substitute_vars()
5. 添加 poste resolve CLI 命令
6. CLI 集成测试：poste resolve --var key --file ... --session-vars ...
```

### Phase 2：Lua 侧迁移 K 键查询

```
1. 写测试 fixture：包含 session_vars / import_params 的场景
   tests/fixtures/http/http_persistence_test.http
       @host = http://postman-echo.com
       ### Login
       POST {{host}}/login

       ### GetUser
       GET {{host}}/user?token={{session_token}}

2. 写 Lua 测试（红）：模拟 nav.show_var_value 在 session_token 上的行为
   调用 poste resolve --var session_token --session-vars '{"session_token":"abc"}'
   期望返回 "abc"

3. 改造 nav.lua:show_var_value（绿）：
   - 删除 ~50 行自解析逻辑
   - 改为 vim.system({"poste resolve", "--var", name, "--file", buf, ...})
   - 保留 fallback 只作为 CLI 不可用时的降级

4. 更新 test: 按 K 键在正常 CLI 下显示正确值
```

### Phase 3：Lua 侧迁移 `<leader>rc`

```
1. 写 test fixture：包含 session var 的请求块
2. 写 test（红）：copy_as_curl() 调 poste resolve --format curl
   期望返回的 curl 命令中包含 -H "Authorization: Bearer abc"
3. 改造 copy.lua（绿）：
   - copy_as_curl() 调 poste resolve --format curl
   - 删除 collect_vars() / resolve_request_content()
4. 移除依赖：shell_escape / substitute_vars / collect_var_defs / load_env_vars
5. 写边角 case test：
   - poste resolve 超时 → fallback 到旧逻辑
   - poste resolve 返回错误 → 报错提示
```

### Phase 4：Verbose 对齐

```
1. 写 test fixture：带多层级变量的请求
2. 写 test（红）：build_pending_request + format_verbose 显示的值
   调 poste resolve --format verbose
   期望不包含 {{var}} 占位符
3. 改造 run.lua + format.lua（绿）：
   - build_pending_request 简化
   - format_verbose 调 poste resolve
4. 写边角 case test：
   - 变量来自 env.json → 显示 env.json 的值
   - 变量被 import param 覆盖 → 显示覆盖后的值
```

### Phase 5：清理

```
1. 写 test（红）：确认旧函数不存在了
   - require("poste.http.copy").collect_vars → nil
2. 删除 nav.lua 中的 magic/var/env fallback 代码
3. 删除 copy.lua 中的 collect_var_defs / load_env_vars / substitute_vars / shell_escape
4. 删除 run.lua 中的 build_pending_request 自解析部分
5. 更新测试确认所有路径仍正常工作
6. 运行完整测试套件：cargo test && tests/run.sh
```

### 每阶段验收标准

| Phase | 红 | 绿 | 重构 |
|-------|-----|------|------|
| P1 | `VarResolver` 不存在 | `poste resolve` 返回正确值 | 移除 parser.rs 中的重复逻辑 |
| P2 | K 显示 `(unresolved)` | K 显示 session var 值 | 删除 ~50 行 nav.lua 代码 |
| P3 | curl 含 `{{var}}` | curl 含解析值 | 删除 ~100 行 copy.lua 代码 |
| P4 | Verbose 含 `{{var}}` | Verbose 显示解析值 | 简化 run.lua / format.lua |
| P5 | 旧函数还存在 | 旧函数已删除 | 全测试套件通过 |

---

## 7. 预期效果

| 场景 | 改进前 | 改进后 |
|------|--------|--------|
| `{{session_id}}` 按 K | 显示 `(unresolved)` | 显示 `sess-123`，标注来源 |
| `<leader>rc` 含 session var | `{{session_id}}` 未解析 | `session=sess-123` |
| Verbose 含 session var | 显示 `{{session_id}}` | 显示 `sess-123` |
| import 传参复制 | 参数可能丢失 | 参数正确注入 |
| 新增变量源 | 改 3-4 个文件 | 只改 Rust 解析器 |

同步性：所有路径用同一 `VarResolver`，`{{var}}` 在任何地方看到的值完全一致。

---

## 8. 未考虑的场景（将来可能扩展）

- `env.json` 嵌套变量引用（如 `{{base_url}}/api` 在 env.json 中）
- Rust 侧的 `client.global` 持久化（当前在 Lua 内存，重启丢失）
- 变量解析的缓存/去重（当前每次 K 键都调 CLI）
- `poste resolve` 返回的 JSON 格式定义（需要和 Lua 对齐 schema）
