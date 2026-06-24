# Poste HTTP 实施指南（TDD）

> 本文档是 **入口文档**。AI agent 以此文档为起点，按 Phase 顺序实施。
>
> 引用文档：
> - `syntax.md` — 语法规范，定义每个语法元素的精确格式
> - `format-design.md` — Formatter 设计，定义 Region 类型、格式化规则、CLI 集成
>
> 三份文档关系：
> ```
> http-impl-guide.md  ← 入口，告诉 agent 先做什么、怎么做
>     ├── 引用 syntax.md      → 某个语法的精确格式长什么样
>     └── 引用 format-design.md → formatter 的架构、Region、集成方式
> ```

## 原则

所有改动必须遵循 TDD：

1. **先写测试，再写实现**
2. **测试失败 → 实现 → 测试通过 → 重构**
3. **不做无测试覆盖的改动**

## 测试定位

| 层 | 工具 | 位置 |
|---|---|---|
| Rust parser 单元测试 | `#[cfg(test)] mod tests` | `crates/poste-core/src/parser.rs` 已有模式 |
| Rust parser 集成测试 | `#[cfg(test)] mod tests` | 同上 |
| Lua 单元测试 | `tests/run.sh` (busted) | `tests/` 目录 |
| Lua 集成测试 | `tests/run.sh` | `tests/` 目录 |
| Docker SQL 测试 | docker compose | `tests/sql/` |

## Phase 0：前置条件实施步骤

### 0.1 `{{$magic}}` Rust 端解析

**参考**：`syntax.md` 2.8 Magic variables

**测试先写**：
```rust
// parser.rs 新增测试
#[test]
fn test_substitute_magic_vars_preserved_in_body() {
    // {{$timestamp}} 在 Rust 端不作为普通 var 替换（env.json 找不到时保留原样）
    // 改为：Rust 端替换 $magic 为占位符，或直接生成值
}
```

**改什么**：`parser.rs` `substitute_vars()` — 增加 `$magic` 处理分支

### 0.2 Pre/Post script 语法高亮

**参考**：`syntax.md` 2.9 / 2.10

**测试先写**：
```lua
-- tests/http_highlight_spec.lua
describe("poste_http syntax", function()
  it("highlights < {% %} as PreScript region", function()
    -- feed lines → check syntax groups
  end)
  it("highlights > {% %} as PostScript region", function()
  end)
  it("highlights client.test, response.status inside PostScript", function()
  end)
end)
```

**改什么**：`syntax/poste_http.vim` — 扩展 `PostePreScript` / `PosteAssertion` 区域，内部匹配 Lua 关键词

### 0.3 Pre/Post script completion

**参考**：`syntax.md` 2.9 / 2.10

**测试先写**：
```lua
describe("poste_http completion", function()
  it("detects script context inside < {%", function()
  end)
  it("offers client.test, client.assert in PostScript", function()
  end)
  it("offers request.variables in PreScript", function()
  end)
end)
```

**改什么**：`lua/poste/http/completion.lua` — `detect_script_context` 已实现，补充 `get_items_for_context` 的 script 分支

### 0.4 `> ./path.lua` 支持

**参考**：`syntax.md` 2.10（外部断言脚本）

**测试先写**：
```rust
// parser.rs
#[test]
fn test_external_assertion_script_stripped() {
    let block = "### Request\nGET /api\n\n{}\n> ./scripts/check.lua\n";
    let req = parser.parse_block(block, Protocol::Http, &HashMap::new()).unwrap();
    assert!(!req.body.contains("check.lua"));
}
```

```lua
describe("assertions.extract_assertion_blocks", function()
  it("extracts > ./path.lua external scripts", function()
  end)
end)
```

**改什么**：
- `parser.rs:128` 后增加 `> ./path.lua` 剥离（仿照 `< ./path.lua` 行 105-108 逻辑）
- `assertions.lua` 的 `extract_assertion_blocks` 增加 `> ./path.lua` 匹配（仿照 `scripts.lua:241`）

### 0.5 Pre/Post script 沙盒注入 `variables` + `env`

**参考**：`syntax.md` 2.9 / 2.10（新增可用 API）

**测试先写**：
```lua
describe("pre_script sandbox variables", function()
  it("injects block-level @var as variables.name", function()
    local code = 'request.variables.set("url", variables.base_url .. "/api")'
    -- 运行脚本, variables = { base_url = "https://example.com" }
    -- assert 结果 == "https://example.com/api"
  end)
  it("injects file-level @var accessible", function()
  end)
  it("block-level var overrides file-level var", function()
  end)
  it("injects env.json keys as env.name", function()
  end)
end)

describe("post_script sandbox variables", function()
  it("injects variables and env into assertion sandbox", function()
  end)
end)
```

**改什么**：
- `run.lua:48-84` — 执行 pre-script 前，从 block 内容提取 `@var`（已有 `parse_variable_line` 逻辑）
- `scripts.lua:335-351` — 沙盒加 `variables` / `env` 表
- `run.lua:146` — 传 `variables` 给 `assertions.run_assertions`
- `assertions.lua:380-398` — 沙盒加 `variables` / `env` 表

### 0.6 `< path` 文件包含/上传

**参考**：`syntax.md` 2.7

**语法**：`< path/to/file`（`<` + 空格 + 路径）

语义取决于 Content-Type：
- **JSON** → 文件内容嵌入请求体（替换 `< path` 行）
- **multipart/form-data** → 文件上传

已实现于 `request_vars.lua:59`（`process_form_data`），需要集成测试验证完整链路。

> **注意**：旧设计 `</path/to/file>`（无空格、有 `>`）已废弃，代码中只有 `< path`（有空格）。

**测试先写**：
```lua
describe("request_vars.process_form_data", function()
  it("replaces < path with file contents in JSON body", function()
  end)
  it("handles relative paths", function()
  end)
  it("handles ~/ paths", function()
  end)
end)
```

### 0.7 `import` / `run` 跨文件引用

**参考**：`syntax.md#2.13`

**核心语义**：
```
import ./auth.http                    # 无别名，请求合并到全局作用域
import ./orders.http as orders        # 有别名，命名空间隔离
run  #Login                           # 只查无别名的 import
run  #orders.ListOrders               # 只查别名 orders 的 import
run  #Login (@token=xyz)              # 运行时变量覆盖
```

**设计决策**：
- 别名必须唯一（`import ./a as ns` + `import ./b as ns` → error）
- 有别名后，裸名 `#Login` 不再覆盖/查找别名内的请求
- 无别名 import 之间同名 → 后覆盖前，warning
- 变量覆盖：`run` 行内 `@var` > 块级 `@var` > 文件级 `@var`

**测试先写**：
```rust
// Rust: import/resolve 模块
#[test]
fn test_import_resolves_requests() {}
#[test]
fn test_import_alias_namespace_isolation() {}
#[test]
fn test_import_alias_conflict_errors() {}
#[test]
fn test_run_variable_override() {}
```

```lua
describe("import resolution", function()
  it("resolves aliased requests via #alias.Name", function()
  end)
  it("bare #Name does not match aliased requests", function()
  end)
end)
```

**改什么**：新建 `crates/poste-core/src/importer.rs`，负责：
1. 解析 `import`/`run` 指令
2. 构建别名索引
3. 请求名查找（优先精确别名匹配 → 降级到无别名全局搜索）
4. 冲突检测

## Phase 1-4 实施步骤

见 `format-design.md` 第 3 节（格式化规则）和第 4 节（CLI 集成）。

每阶段的核心任务：

- **Phase 1** — 实现 Tokenizer（`Region` enum，含 `Import`/`Run` variant）、`poste fmt` CLI、结构格式化规则（规则 1–9）
- **Phase 2** — JSON body 美化（规则 10，serde_json）
- **Phase 3** — Script 格式化（规则 11，`{% %}` 内部缩进）
- **Phase 4** — `--check` / `--diff` / pre-commit hook

每个子任务同样遵循：
1. 先写测试（定义预期行为）
2. 实现（通过测试）
3. 增量提交

## 测试运行命令

```bash
# Rust 测试
cargo test -p poste-core
cargo test -p poste-exec
cargo test -p poste-cli

# Lua 测试
tests/run.sh

# Rust + Lua 全部
cargo test && tests/run.sh
```

## 提交规范

每个 Phase 的子任务独立提交，提交信息格式：

```
feat(http-{scope}): {summary}

Ref: syntax.md#2.{section}
Ref: format-design.md#{phase}
```

示例：

```
feat(http-parser): support {{$magic}} variable substitution

Ref: syntax.md#2.8
Ref: format-design.md#71
```
