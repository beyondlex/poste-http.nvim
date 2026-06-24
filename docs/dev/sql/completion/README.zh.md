# Poste SQL Completion P0-P4 实施指南

本文档面向后续 AI agent 实施。目标是把 Poste 当前 SQL completion 从“Rust context + Lua heuristic fallback + 零散测试”收敛为可验证、可迭代、低延迟的上下文补全系统。

核心原则：

- 不直接重写成完整 LSP。
- 不立刻 fork `sqlparser-rs` 或手写完整 EBNF parser。
- 先把现有 Rust `sql_context` 产品化，统一边界和上下文判定。
- 尽量不破坏已实现的 SQL 执行、数据库浏览、结果面板、HTTP completion。
- 测试可以修改，但只能在旧测试明确固化了错误行为或旧架构细节时修改。

## 当前代码状态

相关文件：

- `lua/poste/sql/completion.lua`：completion orchestrator。当前会先用 Lua heuristic 判定，再尝试 Rust context，并按 context 分发候选项。
- `lua/poste/sql/completion_ctx.lua`：Lua fallback。包含正则式 `detect_context()` 和 `extract_from_tables()`，这是多数边界 bug 的来源。
- `lua/poste/sql/completion_data.lua`：关键字、函数、表/列 cache、binary 查找、metadata fetch。
- `lua/poste/sql/statement.lua`：SQL statement 提取。已能调用 `poste context stmt`，但仍有 Lua fallback 和 SQL-file-specific 补丁。
- `crates/poste-core/src/sql_context/`：Rust tokenizer/context detector/table extraction/statement span。
- `crates/poste-cli/src/main.rs`：已有 `poste context detect <offset> --dialect <dialect>` 和 `poste context stmt <cursor_line>`。
- `tests/sql_completion_spec.lua`、`tests/sql_completion_edge_spec.lua`：Lua completion 测试。注意：部分 edge spec 明确记录了“BEFORE FIX/CURRENT bug”，这些不是长期正确行为。
- `crates/poste-core/src/sql_context/tests.rs`：Rust context 单元测试。

禁止范围：

- 不改 HTTP completion：`lua/poste/http/*`、`lua/poste/completion.lua`。
- 不改 SQL executor 行为，除非某阶段明确需要 metadata/cache 支持。
- 不把 `-- @connection`、`-- @database` 语义交给通用 SQL parser；这是 Poste 文件格式的一部分。

## P0：定义 Poste SQL 文件语法和上下文契约

目标：先定义“什么是正确”，避免继续按 bug 零散补规则。

新增文档：

- `completion/poste-sql-file-syntax.zh.md`
- `completion/poste-sql-file-syntax.en.md`

最少要定义：

1. 文件结构
   - 指令 + SQL 语句（`;` 分隔）。指令可在文件顶部或语句间内联出现。
   - `.sql`/`.mysql`/`.sqlite` 共享同一文件结构，dialect 只影响 SQL context 和 metadata。

2. directive 规则
   - 文件级指令在文件顶部，对所有语句生效。
   - 内联指令在语句之间，从该位置起切换连接/数据库，后续语句持续生效，直到下一个同类型指令。
   - directive 行不参与 SQL statement 解析，不提供 SQL keyword/table/column completion。
   - cursor 在 `-- @connection ` 后补 connection。
   - cursor 在 `-- @database ` 后补 database/schema。

3. statement 边界
   - 强边界：`;`，但 string/comment/dollar quote 内的 `;` 不算。
   - EOF 是当前 statement 的结束。
   - 是否把空行作为软边界必须明确。当前 Rust `detect_context` 对 token range 有 blank-line separator 逻辑，但 `find_statement_span()` 主要基于 semicolon。P0 要决定并写清楚。建议：completion context 可把连续空行作为软边界，execution statement extraction 不应仅因单个空行分割。

4. cursor context 输出契约
   `poste context detect` 的 JSON 应稳定包含：
   - `ctx_type`
   - `ctx_data`
   - `ctx_schema`
   - `prefix`
   - `tables`
   - `functions`
   - `in_string`
   - `in_comment`

   建议新增但不强制一次完成：
   - `version`: 固定协议版本，如 `1`
   - `statement`: `{ "start_line": n, "end_line": n }`
   - `block`: `{ "start_line": n, "end_line": n }`

5. context 类型语义
   - `keyword`：SQL keyword、function、fallback items。
   - `table`：表、视图、可查询对象、必要时 database/schema。
   - `column`：当前 scope 可见列和函数。
   - `dot_column`：`alias.` 或 `table.` 后的列。
   - `schema_table`：`schema.` 后的表。
   - `insert_column`：`INSERT INTO t (` 内的列。
   - `connection`、`database`、`datatype`。

验收：

- 文档中每条规则都能映射到现有或计划中的测试。
- 明确哪些旧测试是“记录旧错误行为”，允许 P1/P2 修改。
- 不改代码也可以通过此阶段。

## P1：让 Rust context 成为默认唯一判定源

目标：消除 Lua/Rust 双真相。Lua 只负责 UI、metadata、fallback degraded mode。

当前问题：

- `lua/poste/sql/completion.lua` 中 `get_items()` 会先调用 `ctx.detect_context(line_before)`，再尝试 Rust。
- `completion_ctx.lua` 的 fallback 没有完整 string/comment/subquery/CTE awareness。
- `tests/sql_completion_edge_spec.lua` 仍大量直接测 Lua heuristic 的当前行为。

实施步骤：

1. 新增一个薄包装函数
   - 文件：`lua/poste/sql/completion.lua`
   - 建议命名：`detect_context_for_completion(bufnr, line_before, cursor_line)`
   - 默认流程：
     1. directive fast path 可以保留在 Lua，因为这是 Poste 文件语法，不是 SQL grammar。
     2. 非 directive 时调用 Rust `try_rust_context()`。
     3. Rust 成功时使用 Rust result。
     4. Rust 不可用时才调用 `completion_ctx.detect_context()`。

2. 收紧 legacy 开关语义
   - `vim.g.poste_sql_legacy_completion = true`：纯 Lua fallback，仅用于 debug 或无 binary 环境。
   - `vim.g.poste_sql_legacy_completion = "rust"`：纯 Rust，不允许 fallback，回归测试使用。
   - 默认 `nil`：Rust 优先；非 directive 的 Lua heuristic 不应覆盖 Rust result。

3. 让 `_test` 暴露区分清楚
   - 当前 tests 用 `sql_comp._test.detect_context` 直接测 Lua heuristic。
   - 建议新增：
     - `_test.detect_lua_context`
     - `_test.detect_rust_context`，可在 binary 存在时用。
     - `_test.get_items` 或 `_test.detect_context_for_completion`，用于真实 completion path。
   - 不要继续让 `_test.detect_context` 名字模糊地指向 Lua heuristic。

4. 保留 Lua fallback，但降低权威性
   - `completion_ctx.lua` 不要删除。
   - 文件头注释更新为：fallback-only when Rust binary unavailable.
   - 任何新 context feature 优先加到 Rust，不加到 Lua fallback，除非无 binary 场景必须支持。

5. completion item 分发仍留在 Lua
   - `table`、`column`、`dot_column` 等 item building 可继续在 `completion.lua`。
   - 这是合理分层：Rust 判定 context，Lua 结合 Neovim 和 cache 生成 items。

测试策略：

- Rust 单元测试继续放 `crates/poste-core/src/sql_context/tests.rs`。
- Lua completion path 测试应测最终 items 或 Rust strict mode，而不是 Lua heuristic 的错误行为。
- `tests/sql_completion_edge_spec.lua` 中标注 `BEFORE FIX` 且描述 bug 的断言可以改成新正确行为，或迁移到 Lua fallback 专用 describe。

验收命令：

```bash
cargo test -p poste-core sql_context
tests/run.sh
```

验收标准：

- 默认 completion 不再因为 Lua heuristic 覆盖 Rust context。
- Rust binary 不存在时，基础 keyword/table/directive completion 仍可 degraded 工作。
- `vim.g.poste_sql_legacy_completion = "rust"` 能用于复现 Rust-only 行为。

## P2：建立 cursor-marker golden tests

目标：把 completion context 从零散 bug 测试升级为稳定规格测试。

新增测试结构建议：

```text
tests/fixtures/sql_context/
  basic_select.json
  directives.json
  statement_boundaries.json
  strings_comments.json
  dot_context.json
  cte_subquery_scope.json
  dml_insert_update_delete.json
  dialect_postgres.json
  dialect_mysql.json
  dialect_sqlite.json
```

fixture 格式建议：

```json
[
  {
    "name": "dot column from alias",
    "dialect": "postgres",
    "sql": "SELECT u.█ FROM users u JOIN orders o ON u.id = o.user_id",
    "expect": {
      "ctx_type": "dot_column",
      "ctx_data": "u",
      "ctx_schema": null,
      "prefix": "",
      "tables": [
        { "name": "users", "alias": "u", "schema": null },
        { "name": "orders", "alias": "o", "schema": null }
      ],
      "in_string": false,
      "in_comment": false
    }
  }
]
```

规则：

- 使用 `█` 作为 cursor marker。
- 测试 runner 读取 SQL，移除 marker，计算 byte offset。
- 对 `tables` 比较建议先做 order-insensitive，除非顺序是明确 contract。
- `functions` 可以只校验包含/不包含关键函数，不要每条 case 都全量比较。
- 对 string/comment 内 cursor，期望 `in_string` 或 `in_comment` 必须准确。当前 CLI 在 `None` 时同时把二者设为 true，这是不够精确的，P2 可先记录为已知限制，也可在 P1/P2 修正 Rust 返回。

新增 runner：

- 首选 Rust integration/unit test，避免依赖 Neovim：
  - `crates/poste-core/tests/sql_context_golden.rs` 或 `crates/poste-core/src/sql_context/tests.rs` 内加载 fixtures。
  - 如果 workspace 不方便读取 JSON fixture，也可用 Rust macro/inline cases 起步。
- Lua 侧保留少量 end-to-end completion item 测试：
  - directive items
  - table items from cache
  - column items from cache
  - blink/nvim-cmp adapter shape

旧测试处理：

- `tests/sql_completion_spec.lua`：保留 UI/item/cache 测试。
- `tests/sql_completion_edge_spec.lua`：拆分为：
  - Lua fallback behavior tests：只在 legacy mode 下断言。
  - Rust context integration tests：改用 golden expectations。
- 如果旧测试注释写着 `BUG`、`BEFORE FIX`，实现修复后应更新测试，不要为了兼容旧错误保留错误行为。

验收命令：

```bash
cargo test -p poste-core sql_context
cargo test -p poste-core --test sql_context_golden
tests/run.sh
```

验收标准：

- 每个新增 context 行为先有 fixture。
- 新 bug 修复流程：先加 failing fixture，再改 Rust context。
- Lua tests 不再承担 SQL grammar 全覆盖职责。

## P3：抽出 ScopeResolver

目标：从“扫 token 顺便提表”升级为明确的 scope model，为 CTE/subquery/alias/dot context 提供稳定基础。

当前问题：

- `crates/poste-core/src/sql_context/tables.rs` 负责 token stream table extraction，但返回的是 flat `Vec<TableRef>`。
- flat table list 不足以表达 nested query、CTE、derived table、shadowing、scope visibility。
- `detect_context()` 每个 special detector 都重复调用 `tables::extract_tables(stmt_tokens, sql)`。

建议新增模块：

```text
crates/poste-core/src/sql_context/scope.rs
```

建议数据结构：

```rust
pub(crate) struct QueryScope {
    pub tables: Vec<TableRef>,
    pub ctes: Vec<CteRef>,
    pub aliases: Vec<AliasRef>,
}

pub(crate) struct CteRef {
    pub name: String,
}

pub(crate) struct AliasRef {
    pub alias: String,
    pub target: AliasTarget,
}

pub(crate) enum AliasTarget {
    Table { name: String, schema: Option<String> },
    Cte { name: String },
    DerivedTable,
}
```

第一阶段只要求：

- 顶层 `FROM` / `JOIN` / `UPDATE` / `INSERT INTO` / `DELETE FROM`。
- schema-qualified：`schema.table`。
- database/schema/table 三段式时保留可用于 lookup 的 schema/table。
- alias：bare alias 和 `AS alias`。
- CTE name 注册：`WITH cte AS (...) SELECT ... FROM cte`。
- 不把 CTE body 里的 table 泄露到 outer scope。
- 不把 subquery 内部 table 泄露到 outer scope。
- derived table alias 可见：`FROM (SELECT ...) x` 中 `x.` 可被识别为 `DerivedTable`，但列补全可先 fallback keyword/function，除非后续实现 derived output columns。

实现步骤：

1. 新增 `scope.rs`
   - 输入：statement token slice + sql source。
   - 输出：`QueryScope`。
   - 初期可以复用 `tables.rs` 的 helper，但不要让外部再直接依赖 flat extraction。

2. 让 `tables.rs` 变为兼容层
   - `extract_tables()` 可以内部调用 `scope::resolve_scope()`，再返回 `scope.tables`。
   - 保持现有 public behavior，减少一次性破坏。

3. 更新 `detect_context()`
   - 每次 detect 只解析一次 scope。
   - 通过 helper 构造 `ContextResult`，避免七八处重复 `functions::known_functions_for_dialect()` 和 `tables::extract_tables()`。

4. dot context lookup
   - `DotColumn { table: "u" }` 仍保持当前 JSON contract。
   - Lua 侧用 `tables` 中 alias map 查真实 table。
   - Rust 可附加 `ctx_schema` 但不要破坏旧字段。

5. CTE 和 subquery 测试
   必须覆盖：

```sql
WITH recent AS (SELECT * FROM orders)
SELECT * FROM recent r WHERE r.█
```

```sql
SELECT * FROM users u
WHERE EXISTS (SELECT 1 FROM orders o WHERE o.user_id = u.id)
AND █
```

第二条在 outer `AND` 后不应补 `orders` 的列。

验收标准：

- 原有 flat table tests 通过。
- 新 CTE/subquery golden fixtures 通过。
- `completion.lua` 的 column gathering 不需要了解 CTE/subquery 细节，只消费 Rust result。

## P4：实现 persistent context service，降低 completion 延迟

目标：避免每次补全都 `vim.fn.system()` spawn `poste context detect`，但不直接上完整 LSP。

当前问题：

- `completion.lua` 的 `try_rust_context()` 每次 cache miss 会执行：

```lua
vim.fn.system("<poste> context detect <offset> --dialect ...", sql_text)
```

- 进程启动成本会放大输入延迟。
- 当前 `_ctx_cache_key` 只缓存最后一次结果，无法覆盖多 buffer、多 cursor、多 block 的真实使用。

建议新增 CLI 子命令：

```bash
poste context serve
```

协议：stdin/stdout line-delimited JSON。每行一个 request，每行一个 response。

request 示例：

```json
{
  "id": 1,
  "method": "detect",
  "dialect": "postgres",
  "sql": "SELECT * FROM users WHERE ",
  "offset": 26
}
```

response 示例：

```json
{
  "id": 1,
  "ok": true,
  "result": {
    "ctx_type": "column",
    "ctx_data": null,
    "ctx_schema": null,
    "prefix": "",
    "tables": [{ "name": "users", "alias": null, "schema": null }],
    "functions": ["COUNT"],
    "in_string": false,
    "in_comment": false
  }
}
```

错误 response：

```json
{
  "id": 1,
  "ok": false,
  "error": "invalid request"
}
```

实施步骤：

1. Rust CLI
   - 在 `ContextAction` 新增 `Serve`。
   - `serve` loop 只做 context/stmt，不做 database introspection。
   - 复用 `make_detect_response()`。
   - 每行 request 独立处理；单个错误不能退出 server。
   - EOF 时退出。

2. Lua client
   - 新增 `lua/poste/sql/context_client.lua`。
   - 负责 `vim.fn.jobstart()`、request id、pending callbacks、stdout line buffer、restart。
   - 对外提供：

```lua
detect(sql_text, offset, dialect, callback)
stmt(sql_text, cursor_line, callback)
stop()
```

3. completion integration
   - `try_rust_context()` 优先走 persistent client。
   - client 不可用、job 启动失败、超时，再 fallback 到当前 `vim.fn.system()`。
   - 保留 `_ctx_cache_key`，但可扩展为 per-buffer LRU：
     - key = `bufnr|changedtick|block_start|block_end|offset|dialect`

4. 超时策略
   - completion path 不应永久等待。
   - 建议 50ms 内未返回时先 callback keyword/function fallback，迟到结果丢弃或用于下次 cache。
   - 初期也可使用同步 system fallback，先保证行为正确，再优化异步。

5. 不做事项
   - 不实现 LSP initialize/textDocument/didChange。
   - 不做跨编辑器协议。
   - 不让 server 访问 DB；metadata 仍由现有 `completion_data.lua` CLI introspect/cache 流程处理。

测试策略：

- Rust：
  - `poste context serve` 输入一行 detect request，输出正确 JSON。
  - 输入非法 JSON，输出 `ok=false` 并继续服务下一行。
- Lua：
  - 可 mock `context_client.detect()`，验证 `completion.lua` fallback 路径。
  - 不强制在普通 `tests/run.sh` 中启动真实 long-running job，避免 flaky。

验收标准：

- 默认 completion 行为不变。
- server 不可用时自动回到 `vim.fn.system()`，用户无感。
- debug log 能看出走的是 `serve` 还是 `system`。

## 分阶段提交建议

建议按以下 PR/commit 切分：

1. `docs: define sql completion p0-p4 plan`
2. `docs: define poste sql file syntax`
3. `refactor(sql): route completion context through rust`
4. `test(sql): add context golden fixtures`
5. `refactor(sql): introduce scope resolver`
6. `feat(sql): add context serve protocol`
7. `feat(sql): use persistent context client in completion`

每一步都应保持：

```bash
cargo test
tests/run.sh
```

如果 SQL integration Docker 未启动，不要求跑 `tests/sql`，但 final note 必须说明未运行。

## 允许修改测试的判断标准

可以修改：

- 测试注释明确写 `BUG`、`BEFORE FIX`、`known limitation`，且新行为符合 P0 contract。
- 测试直接调用 Lua heuristic，却声称验证 SQL completion 总体行为。
- 测试依赖 completion item 顺序，但产品 contract 只要求集合包含。

不应修改：

- SQL execution 行为测试。
- HTTP completion 测试。
- 数据库浏览器、结果面板、dataset 渲染测试，除非改动直接涉及这些模块。

修改测试时必须在 commit/message/final summary 中说明旧测试为什么不再代表正确行为。

## 实施风险和防护

- 风险：Rust context 返回字段变化破坏 Lua item 分发。
  - 防护：保持 JSON 字段向后兼容，只增字段，不删字段。

- 风险：Lua fallback 删除过早导致无 binary 环境不可用。
  - 防护：保留 `completion_ctx.lua`，但标记 fallback-only。

- 风险：scope resolver 一次做太大。
  - 防护：P3 第一阶段只处理 table/alias/CTE visibility，不推导 derived columns。

- 风险：persistent service 引入 flaky tests。
  - 防护：Rust 测 line protocol；Lua 测 client wrapper 和 fallback，不依赖真实异步时序。

- 风险：把 Poste file syntax 和 SQL grammar 混在一起。
  - 防护：P0 文档明确 directive 行在 SQL parser 之前处理。

## 最终目标状态

完成 P0-P4 后，架构应为：

```text
Neovim completion source
  -> Poste SQL file/block resolver
  -> Rust context service
       -> tokenizer
       -> statement span
       -> scope resolver
       -> context detector
  -> Lua metadata cache
  -> completion items
```

这时再评估 Tree-sitter 或 LSP 才有意义。Tree-sitter 可以替换 tokenizer/scope 的一部分；LSP 可以包住同一 context engine。但它们都不应重新定义 Poste 的文件语义。
