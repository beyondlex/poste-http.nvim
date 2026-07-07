# Poste 重构实施计划

> 本文档基于代码审查中识别的 12 类问题，按风险/收益比排序分阶段实施。
> 每个阶段遵循 TDD 红线-绿灯-重构循环：先为当前行为编写特征测试，再重构，确保零回归。

---

## 目录

- [识别的问题概览](#识别的问题概览)
- [阶段零：测试基础设施](#阶段零测试基础设施)
- [阶段一：低风险/高收益](#阶段一低风险高收益)
- [阶段二：中等风险](#阶段二中等风险)
- [阶段三：高影响力/高风险](#阶段三高影响力高风险)
- [阶段四：持续改进](#阶段四持续改进)
- [实施进度跟踪表](#实施进度跟踪表)
- [风险提示](#风险提示)
- [关键原则](#关键原则)

---

## 识别的问题概览

| 优先级 | 问题 | 影响范围 | 修复难度 |
|--------|------|----------|----------|
| 🔴 P0 | `run_request()` 上帝函数 | HTTP 执行流、扩展性 | 高 |
| 🔴 P0 | 全局可变状态 | 所有模块、竞态 | 中 |
| 🔴 P0 | `set_indicator()` 重复代码 | UI 模块 | 低 |
| 🟡 P1 | 回调地狱 | 维护、调试 | 高 |
| 🟡 P1 | blink.cmp 内部 API 耦合 | 兼容性 | 中 |
| 🟡 P1 | `main.rs` 上帝二进制 | 可维护性 | 中 |
| 🟡 P2 | 长函数（多处） | 可测性 | 中 |
| 🟢 P3 | 未实现协议存根 | 代码整洁 | 低 |
| 🟢 P3 | 路径穿越风险 | 安全 | 低 |
| 🟢 P3 | 硬编码/魔法值 | 配置化 | 低 |

---

## 阶段零：测试基础设施（必须先做）

在触碰任何业务代码之前，先建立安全网。

### 0.1 Lua 侧：为所有 `poste.state` 访问点建立合约测试

**问题**: 全局可变状态是最大的耦合源，重构前必须有契约锁定。

```lua
-- tests/state_contract_spec.lua
describe("state contract", function()
  it("last_response is nil after clear", function()
    state.last_response = { status = 200 }
    state.last_response = nil
    assert.is_nil(state.last_response)
  end)

  it("current_env defaults to config.default_env", function()
    assert.equals(state.current_env, state.config.default_env)
  end)

  -- 所有 state 字段的读写契约
end)
```

### 0.2 Lua 侧：为 `indicators.set_indicator` 建立 Vim 抽象层测试

创建隔离的测试夹具，mock nvim API：

```lua
-- tests/helpers/mock_nvim.lua
-- mock nvim_buf_set_extmark, nvim_buf_add_highlight, sign_place 等
```

### 0.3 Rust 侧：为 `executor.rs` 补全单元测试

现有测试覆盖了 SQL context，但 HTTP 执行逻辑是盲区：

```bash
cargo test -p poste-exec           # 现有
# 需要增加:
cargo test -p poste-exec --test test_parse_curl_response
cargo test -p poste-exec --test test_sanitize_filename
cargo test -p poste-exec --test test_is_binary_content_type
```

**写入标准**：每个重构步骤前，相关函数的代码覆盖率必须 ≥ 80%
（用 `cargo tarpaulin` 或 `cargo-llvm-cov` 验证）。

### 0.4 集成测试基准

```bash
# 现有的 HTTP 请求测试路径
./tests/http/ 目录下的 .http 文件 → 运行 :PosteRun → 验证输出

# 建立 CI 回归基线
cargo test --test cli_context_serve  # 现有的持久化模式测试
```

---

## 阶段一：低风险/高收益（预计 2-3 天）

### 1.1 消除 `set_indicator` 重复代码

#### 识别的问题

`indicators.lua:set_indicator()` 的 "success" 和 "error" 分支有 40+ 行
完全相同的 virt_text 构建逻辑。

#### 方案

提取公共函数 `build_virt_text(latency_ms, assertion_results)`，消除重复。

#### TDD 步骤

```
RED   → 写测试: assert_format_latency(1500) == "1.50 s"
         assert_format_assertions({passed=3, total=4}) == "✓ 3/4 tests"
GREEN → 提取 build_virt_text(latency_ms, assertion_results) → table
         替换两个分支中的重复块
REFACTOR → 在成功/错误分支中调用 build_virt_text()
```

#### 关键代码变更

```lua
-- indicators.lua
local function build_virt_text(latency_ms, assertion_results)
  local virt_text = {}
  if latency_ms and latency_ms > 0 then
    table.insert(virt_text, { format_latency(latency_ms), "PosteLatency" })
  end
  if assertion_results and assertion_results.total > 0 then
    local icon = assertion_results.failed > 0 and "✘" or "✓"
    local hl = assertion_results.failed > 0 and "PosteError" or "PosteSuccess"
    table.insert(virt_text, {
      string.format("  %s %d/%d tests", icon, assertion_results.passed, assertion_results.total),
      hl,
    })
  end
  return virt_text
end

-- 然后两个分支都是:
local virt_text = build_virt_text(latency_ms, assertion_results)
if #virt_text > 0 then
  vim.api.nvim_buf_set_extmark(buf, indicator_ns, line_0, 0, {
    virt_text = virt_text,
    virt_text_pos = "eol",
    hl_mode = "combine",
  })
end
```

#### 验收标准

- [ ] `set_indicator("success")` 和 `set_indicator("error")` 显示相同的 latency/assertion 格式
- [ ] latency 显示格式化（ms vs s）正确
- [ ] 所有现有测试通过

---

### 1.2 修复路径穿越安全漏洞

#### 识别的问题

`executor.rs:sanitize_filename()` 不过滤 `..`，攻击者可通过
Content-Disposition 写入任意路径。

#### 方案

在 `resolve_path_with_conflict()` 层面强制约束到目标目录内。

#### TDD 步骤

```rust
#[test]
fn test_sanitize_filename_prevents_path_traversal() {
    assert_eq!(sanitize_filename("../../etc/passwd"), "etc_passwd");
    assert_eq!(sanitize_filename("foo/bar"), "foo_bar");
    assert_eq!(sanitize_filename("normal.txt"), "normal.txt");
}

#[test]
fn test_resolve_path_stays_in_target_dir() {
    // 即使传了绝对路径，resolve 后仍然在 /tmp 下
    let path = resolve_path_with_conflict("/tmp", "/etc/passwd");
    assert!(path.starts_with("/tmp/"));
}
```

#### 关键代码变更

```rust
fn sanitize_filename(name: &str) -> String {
    let sanitized: String = name
        .chars()
        .filter(|&c| c != '/' && c != '\\' && c != '\0' && c != ':')
        .collect();
    let trimmed = sanitized.trim().to_string();
    // 防止路径穿越
    let without_dots = trimmed.replace("..", "");
    if without_dots.is_empty() || without_dots == "." {
        "downloaded_file".to_string()
    } else {
        without_dots
    }
}
```

#### 验收标准

- [ ] 文件名 `../../etc/cronjob` → `etc_cronjob`（存放在 /tmp 下）
- [ ] 文件名 `normal.txt` → `normal.txt`
- [ ] 已存在的文件名正确添加 `(1)`, `(2)` 后缀

---

## 阶段二：中等风险（预计 5-7 天）

### 2.1 全局状态 → 事件驱动模型

#### 识别的问题

`state.lua` 是所有模块共享的可变全局单例，15+ 模块直接读写，造成隐式耦合和竞态。

#### 方案

引入**事件总线**（Event Bus），将"写后读"的同步依赖改为发布-订阅模式。

#### 架构设计

```
                     ┌─────────────┐
                     │  Event Bus  │
                     │ (state/event)│
                     └──────┬──────┘
                            │
          ┌─────────────────┼─────────────────┐
          │                 │                  │
    ┌─────▼──────┐   ┌─────▼──────┐   ┌───────▼────┐
    │ HTTP Run   │   │ View       │   │ Indicators │
    │ (生产者)    │   │ (消费者)    │   │ (消费者)    │
    └────────────┘   └────────────┘   └────────────┘
```

#### TDD 步骤

```
阶段 2.1a — 创建事件总线模块（不影响现有代码）
RED   → 写测试: eventbus:on("response", handler) 注册后能收到事件
         eventbus:emit("response", data) 触发 handler
         once() 只触发一次
GREEN → 实现 lua/poste/state/event.lua (约 80 行)
REFACTOR → 现有模块继续用 state，新事件总线并行存在

阶段 2.1b — 将 state.last_response 改为事件驱动
RED   → run.lua 写入 state.last_response 之后，emit("response:ready", data)
         验证 view.lua 通过 on("response:ready") 收到事件
GREEN → run.lua 添加 emit 调用
         view.show_view 改为响应事件
REFACTOR → 逐步移除 state.last_response 的直接读取
           改为通过事件总线传递 response 上下文对象

阶段 2.1c — 迁移所有 state 消费者
    view.lua       → 监听 response:ready
    indicators.lua → 监听 response:ready
    history.lua    → 监听 response:ready
    json.lua       → 监听 response:ready
    run.lua 本身   → 不再读写全局 state
```

#### 关键代码变更

```lua
-- lua/poste/state/event.lua (新文件)
local M = { _handlers = {} }

function M.on(event, handler)
  M._handlers[event] = M._handlers[event] or {}
  table.insert(M._handlers[event], handler)
  return function() -- return unsubscribe function
    -- ...
  end
end

function M.emit(event, data)
  for _, handler in ipairs(M._handlers[event] or {}) do
    vim.schedule(function()
      pcall(handler, data)
    end)
  end
end

return M
```

```lua
-- run.lua 中，替换:
-- state.last_response = parsed
-- 改为:
require("poste.state.event").emit("response:ready", {
  response = parsed,
  request_name = current_req_name,
  file = file,
  assertion_results = state.last_assertion_results,
  script_logs = state.last_script_logs,
})
```

#### 验收标准

- [ ] 现有 HTTP/SQL 执行流程完全正常
- [ ] `state.last_response` 不再被任何模块直接读取（保留向后兼容别名，但标记 deprecated）
- [ ] 事件总线的 handler 异常不影响其他 handler
- [ ] 竞态条件减少：`vim.schedule` 包裹的多个 `on_stdout` 不再互相覆盖

---

### 2.2 拆分 `run.lua:run_request()` 上帝函数

#### 识别的问题

~450 行单函数、6 层回调嵌套。混合了准备/执行/响应处理三个独立阶段。

#### 方案

拆分为管线（Pipeline）模式：

```
run_request()
  │
  ├─ prepare_request()
  │     ├─ resolve_prompt_variables()
  │     ├─ resolve_request_variables()
  │     └─ collect_script_variables()
  │
  ├─ execute_request()
  │     ├─ extract_pre_script_blocks()
  │     ├─ run_pre_script()
  │     ├─ extract_assertion_blocks()
  │     ├─ build_curl_cmd()
  │     └─ start_job()
  │
  └─ handle_response()
        ├─ parse_job_output()
        ├─ run_assertions()
        ├─ update_indicators()
        ├─ update_view()
        └─ add_to_history()
```

#### TDD 步骤

```lua
-- 先为每个子函数写测试

-- tests/http/request_pipeline_spec.lua
describe("prepare_request", function()
  it("resolves prompt variables in content", function()
    -- mock vim.ui.input 返回 "bar"
    local result = prepare_request("GET {{foo}}", { foo = { prompt = "Enter foo" }})
    assert.equals("GET bar", result)
  end)

  it("returns content unchanged when no variables", function()
    local result = prepare_request("GET /api/users")
    assert.equals("GET /api/users", result)
  end)
end)

describe("execute_request", function()
  it("builds correct curl command", function()
    local cmd = build_curl_cmd("POST", "http://example.com",
      {{"Content-Type", "application/json"}}, '{"key": "val"}')
    assert.truthy(cmd:match("curl"))
    assert.truthy(cmd:match("http://example.com"))
  end)
end)

describe("handle_response", function()
  it("parses JSON response and emits event", function()
    local emitted = false
    local unsub = eventbus.on("response:ready", function() emitted = true end)
    handle_response('{"status": 200, "body": "ok"}')
    assert.is_true(emitted)
    unsub()
  end)
end)
```

#### 验收标准

- [ ] `run_request()` 减少到 ≤ 50 行（只做管线编排）
- [ ] 每个子函数 ≤ 60 行
- [ ] 回调嵌套 ≤ 3 层
- [ ] 每个子函数有独立单元测试

---

### 2.3 拆分 `main.rs`

#### 识别的问题

~870 行单文件，混合 CLI 解析+执行+格式化+导入+上下文检测+连接管理。

#### 方案

按职责拆分为模块：

```
crates/poste-cli/src/
├── main.rs            ← 只做 CLI 解析和分发 (~50行)
├── run.rs             ← Run 子命令处理
├── context.rs         ← Context 子命令 (detect/stmt/stmt_ranges/serve)
├── connection.rs      ← Connection 子命令 (list/test)
├── fmt.rs             ← Fmt 子命令
├── import.rs          ← Import 子命令
└── introspect.rs      ← Introspect 子命令
```

#### TDD 步骤

```
RED   → 为每个模块提取的函数写测试:
         test_handle_run_command
         test_handle_context_detect
         test_load_env_vars 等
GREEN → 逐个模块提取，每个模块保持编译通过
REFACTOR → main.rs 只保留:
           #[tokio::main]
           async fn main() -> Result<()> {
               match cli.command {
                   Some(Commands::Run {..})     => run::execute(args).await?,
                   Some(Commands::Context {..})  => context::execute(args)?,
                   Some(Commands::Connection{..}) => connection::execute(args).await?,
                   Some(Commands::Fmt {..})      => fmt::execute(args)?,
                   Some(Commands::Import {..})   => import::execute(args)?,
                   Some(Commands::Introspect{..}) => introspect::execute(args).await?,
                   None => {},
               }
               Ok(())
           }
```

#### 验收标准

- [ ] `main.rs` ≤ 60 行
- [ ] 每个新模块 ≤ 200 行
- [ ] `cargo test` 全部通过
- [ ] `cargo build` 二进制行为不变

---

## 阶段三：高影响力/高风险（预计 7-10 天）

### 3.1 解耦 blink.cmp 依赖

#### 识别的问题

`sql/init.lua` 直接引用 blink.cmp 内部模块
（`.config`, `.sources.lib`, `.completion.trigger`），
不兼容其他补全插件。

#### 方案

引入 `poste.sql.completion_adapter` 抽象层，用适配器模式包装补全插件。

```lua
-- lua/poste/sql/completion_adapter.lua
local M = {}

-- 适配器接口 (所有补全插件必须实现):
--   register_source(config)
--   show()
--   is_menu_open() → bool

-- 默认: blink.cmp 适配器
local blink_adapter = {
  register_source = function(config)
    local blink = require("blink.cmp")
    blink.add_source_provider(config.name, config.provider_config)
    blink.add_filetype_source(config.filetype, config.name)
  end,
  show = function()
    require("blink.cmp.completion.trigger").show({ force = true })
  end,
  is_menu_open = function()
    local ok, menu = pcall(require, "blink.cmp.completion.windows.menu")
    return ok and menu.win:is_open()
  end,
}

-- 备选: nvim-cmp 适配器 (将来实现)
local nvim_cmp_adapter = { ... }

function M.setup(plugin_type)
  if plugin_type == "blink" then
    M._adapter = blink_adapter
  elseif plugin_type == "nvim-cmp" then
    M._adapter = nvim_cmp_adapter
  else
    M._adapter = blink_adapter  -- 默认
  end
  M._adapter.register_source({
    name = "poste_sql",
    filetype = "poste_sql",
    provider_config = {
      module = "poste.sql.completion",
      name = "PosteSQL",
      async = true,
      score_offset = 1000,
    },
  })
end
```

#### TDD 步骤

```
RED   → 写适配器接口测试:
         adapter:register_source({name="test"}) → blink.cmp 收到注册
         adapter:show() → blink 菜单打开
         adapter:is_menu_open() → 返回 true/false
GREEN → 实现 blink 适配器
REFACTOR → sql/init.lua 中所有 require("blink.cmp.*") 替换为 adapter 调用
```

#### 验收标准

- [ ] `sql/init.lua` 中不再有任何 `require("blink.cmp")`
- [ ] 所有补全功能正常
- [ ] blink.cmp 版本升级不会破坏补全
- [ ] 未来增加 nvim-cmp 支持只需新增适配器

---

### 3.2 异步流程改为协程模式

#### 识别的问题

6 层回调嵌套（回调地狱），代码难以阅读和维护。

#### 方案

利用 Lua coroutine + `vim.wait()` 或 Neovim 的异步 API
将回调展开为线性代码。

```lua
-- 改造前 (回调嵌套)
request_vars.resolve_request_variables(binary, file, env, buf, line, content, function(result)
  scripts.extract_pre_script_blocks(result, ..., function(script_result)
    -- 继续
  end)
end)

-- 改造后 (Promise 风格)
local p = Promise.new(function(resolve, reject)
  request_vars.handle_prompt_variables(..., function(result)
    resolve(result)
  end)
end)

p:then_(function(result)
  return Promise.new(function(resolve)
    request_vars.resolve_request_variables(..., result, function(r) resolve(r) end)
  end)
end):then_(function(result)
  -- ...
end):catch_(function(err)
  indicators.set_indicator(src_buf, req_line, "error")
end)
```

**建议**：先不要引入外部依赖。可以自己实现 ~50 行的 Promise 原型，
或者直接使用 `vim.schedule` 配合状态机。

#### TDD 步骤

```
RED   → 写 Promise 接口测试:
         Promise:new(fn(resolve)):then_(handler) 能链式调用
         错误通过 catch() 传播
GREEN → 实现 lua/poste/async/promise.lua
REFACTOR → 将 run.lua 最外层的回调链改为 Promise 链
           内层保持原样（避免一次改动过大）
```

#### 验收标准

- [ ] `run.lua` 回调从 6 层减少到 ≤ 3 层
- [ ] Promise 链中的每个阶段可独立测试
- [ ] 错误传播正确（任何阶段出错都能跳到错误处理）

---

### 3.3 移除未实现协议存根

#### 识别的问题

`Protocol::Mongodb` 和 `Protocol::Amqp` 只有 `bail!("not implemented")`，
增加维护负担。

#### 方案

两个选择（二选一，取决于路线图）：

1. **移除**：删除枚举变体和匹配分支（如果未来 6 个月内没有实现计划）
2. **Feature gate**：用 Cargo feature 隐藏

```rust
// 选项 1: 直接移除
pub enum Protocol {
    Http,
    Redis,
    Mysql,
    Postgres,
    Sqlite,
}

// 选项 2: Feature gate
#[cfg(feature = "mongodb")]
Mongodb,
#[cfg(feature = "amqp")]
Amqp,
```

#### 验收标准

- [ ] `cargo build` 通过
- [ ] `cargo test` 通过
- [ ] 如果选择 feature gate：`cargo build --no-default-features` 不包含 mongodb/amqp

---

## 阶段四：持续改进（长期/每次 PR 附带）

### 4.1 硬编码值提取为配置常量

```lua
-- 创建 lua/poste/constants.lua
return {
  SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
  SPINNER_INTERVAL_MS = 100,
  CURSOR_MOVED_DEBOUNCE_MS = 100,
  SYNTAX_REFRESH_DEBOUNCE_MS = 150,
  BLINK_SCORE_OFFSET = 1000,
  BINARY_CWD_PATHS = { "./target/debug/poste", "./target/release/poste" },
}
```

### 4.2 统一错误处理策略

```lua
-- 定义错误层级
local ERROR_LEVELS = {
  DEBUG   = vim.log.levels.DEBUG,
  INFO    = vim.log.levels.INFO,
  WARN    = vim.log.levels.WARN,
  ERROR   = vim.log.levels.ERROR,
}

-- 统一入口
function M.notify(msg, level, opts)
  level = level or ERROR_LEVELS.INFO
  state.log(level, msg)          -- 总是写日志
  vim.notify(msg, level, opts)   -- 用户可见
end
```

### 4.3 代码规范检查 CI

```yaml
# .github/workflows/lint.yml 增加
- name: Lua lint
  run: |
    brew install selene
    selene lua/

- name: Rust clippy
  run: cargo clippy -- -D warnings

- name: Check for TODO/FIXME/HACK
  run: |
    ! grep -rn "TODO\|FIXME\|HACK" lua/ crates/ --include="*.lua" --include="*.rs" | grep -v ".md"
```

---

## 实施进度跟踪表

```markdown
### Phase 0: Test Infrastructure [✓] 预计 2 天
- [x] 0.1 state 合约测试 — `tests/state_contract_spec.lua`
- [x] 0.2 nvim mock 测试夹具 — `tests/helpers/mock_nvim.lua`
- [x] 0.3 executor.rs 单元测试覆盖 ≥80% — 18 个新测试
- [x] 0.4 CI 回归基线 — `.github/workflows/ci.yml` (cargo test/lint, luacheck, TODO check)

### Phase 1: Low Risk [✓] 预计 3 天
- [x] 1.1 set_indicator 去重 — `build_virt_text()`, `format_latency()`, `build_assertion_text()` 提取
- [x] 1.2 路径穿越修复 — `sanitize_filename()` 过滤 `..` 和 `:`, 新增 18 个 Rust 测试

### Phase 2: Medium Risk [✓] 预计 7 天
- [x] 2.1 事件总线 + 状态解耦 — `state/event.lua`, 集成到 `run.lua` 的 4 个响应点
- [x] 2.2 run_request 函数拆分 — 16 个局部函数, 管线模式 (prepare→execute→handle)
- [x] 2.3 main.rs 模块拆分 — 871→84 行, 7 个模块 (run/context/connection/fmt/import/introspect/serve)

### Phase 3: High Impact [✓] 预计 10 天
- [x] 3.1 blink.cmp 解耦 — `sql/completion_adapter.lua` 适配器模式, 所有 SQL 模块移除直接 `require("blink.cmp.*")`
- [x] 3.2 回调 → Promise — `async/promise.lua` (then_/catch_/finally_/all), `tests/promise_spec.lua`
- [x] 3.3 移除未实现协议存根 — `Protocol::Mongodb`, `Protocol::Amqp` 删除

### Phase 4: Continuous [✓] 长期
- [x] 4.1 硬编码配置化 — `lua/poste/constants.lua`
- [x] 4.2 统一错误处理 — `lua/poste/error.lua` (M.notify/Debug/Info/Warn/Error)
- [x] 4.3 CI 代码规范检查 — `.github/workflows/ci.yml`, `.luacheckrc`
```

---

## 风险提示

| 风险 | 缓解措施 |
|------|----------|
| 事件总线引入性能开销 | 使用 `vim.schedule` 批量处理，不要每个事件都做 UI 刷新 |
| 协程与 Neovim API 兼容问题 | 仅在纯计算逻辑使用协程，Neovim API 调用保持原样 |
| 拆分 `run_request` 导致回归 | 每个子函数提取前，先写覆盖该段逻辑的集成测试 |
| blink.cmp 解耦影响用户体验 | 适配器切换增加 fallback 检查和版本检测 |

---

## 关键原则

1. **TDD 红线-绿灯-重构**：每个改动必须先有失败测试，再实现，最后重构
2. **小步提交**：每个阶段独立可合并，不产生长期 feature branch
3. **测试先行**：任何重构代码合入主分支前，必须通过现有全部测试 + 新增测试
4. **保持向后兼容**：事件总线引入期间，旧的 `state.last_response` 保留 deprecated 别名
5. **不影响用户**：所有重构对用户透明，不改变快捷键、UI 或行为