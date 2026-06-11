# SQL 补全 P0-P4 实施清单

> **进度**: P0 ✅ | P1 ✅ | P2 ✅ | P3 ✅ | P4 ✅
> **当前阶段**: P4 — 持久化上下文服务 ✅
> **下一步**: P0-P4 全部完成

---

## P1 — Rust 上下文为唯一真实源

**目标**: 默认情况下 Lua 启发式不再覆盖 Rust 上下文。

### Rust 侧 (`crates/poste-core/src/sql_context/`)

- [x] **P1a. `ContextType::String/Comment`** — 给 `ContextType` 枚举添加 `String` 和 `Comment` 变体。光标在字符串/注释内时返回对应类型，不再返回 `None`。
  - 文件: `context.rs`, `scanner.rs`, `detectors.rs`
  - 验收: `cargo test -p poste-core sql_context`

- [x] **P1b. `version` 字段** — `detect_context()` 输出 JSON 添加 `"version": 1`。
  - 文件: `context.rs`
  - 验收: `cargo test -p poste-core sql_context`

- [x] **P1c. `ctx_schema` 补全** — `SchemaTable` 上下文的 `ctx_schema` 填入 schema 名（当前为 null）。
  - 文件: `detectors.rs`
  - 验收: `cargo test -p poste-core sql_context`

- [x] **P1d. `try_directive()` 降级** — 遇到 `@connection`/`@database` 标记时返回 `None`（安全网），不再返回 `Connection`。
  - 文件: `detectors.rs`
  - 验收: `cargo test -p poste-core sql_context`

### Lua 侧 (`lua/poste/sql/`)

- [x] **P1e. 检测包装器** — 在 `completion.lua` 添加 `detect_context_for_completion(bufnr, line_before, cursor_line)`:
  - 保留 Lua 指令快速路径（`-- @connection`, `-- @database`）
  - SQL 正文优先调用 `try_rust_context()`（传完整正文，不预提取块）
  - 仅在 Rust 不可用时回退到 `completion_ctx.detect_context()`
  - `get_items()` 接入此新函数

- [x] **P1f. 旧版开关** — 在 `completion.lua`:
  - `vim.g.poste_sql_legacy_completion = true` → 仅 Lua 回退
  - `vim.g.poste_sql_legacy_completion = "rust"` → 仅 Rust，不回退
  - 默认 `nil` → Rust 优先，Lua 不覆盖

- [x] **P1g. 测试导出改名**:
  - `_test.detect_context` → `_test.detect_lua_context`
  - 添加 `_test.detect_rust_context`（二进制存在时）
  - 添加 `_test.detect_context_for_completion`
  - 更新 `tests/sql_completion_spec.lua` 和 `tests/sql_completion_edge_spec.lua` 中的所有引用

- [x] **P1h. `completion_ctx.lua` 标记废弃** — 添加头注释 `@deprecated` + "仅当 Rust 不可用时回退"。不再添加新 SQL 语法特性。

### P1 验收

```bash
cargo test -p poste-core sql_context
tests/run.sh
```

**标准**: 默认补全不再被 Lua 启发式覆盖。`vim.g.poste_sql_legacy_completion = "rust"` 可再现纯 Rust 行为。

---

## P2 — 光标标记黄金测试

**目标**: 每个上下文行为在改 Rust 代码前都有可验证的 fixture。

- [x] **P2a. 定义 fixture 格式** — 使用 `█` 光标标记，JSON fixture 格式见 `README.md` §P2。放入 `tests/fixtures/sql_context/` 或内联在 Rust 测试中。

- [x] **P2b. 编写 fixture 文件**:

| 文件 | 数量 | 内容 |
|------|------|------|
| `basic_select.json` | 8-10 | 基本 SELECT, FROM, WHERE |
| `directives.json` | 4-6 | `-- @connection`, `-- @database` 光标补全 |
| `statement_boundaries.json` | 6-8 | `;` 边界, 多语句 |
| `strings_comments.json` | 4-6 | 字符串/注释内光标 |
| `dot_context.json` | 6-8 | `alias.`, `table.` 后 |
| `cte_subquery_scope.json` | 4-6 | CTE, 子查询作用域 |
| `dml_insert_update_delete.json` | 6-8 | INSERT/UPDATE/DELETE |
| `dialect_postgres/mysql/sqlite.json` | 各 4-6 | 方言特有 |

- [x] **P2c. 测试运行器** — 添加 `crates/poste-core/tests/sql_context_golden.rs`。加载 fixture，去掉 `█`，调用 `detect_context()`，比较结果。

- [x] **P2d. 旧测试迁移**:
  - `tests/sql_completion_spec.lua`: 保留 UI/条目/缓存测试
  - `tests/sql_completion_edge_spec.lua`: 拆分 Lua 回退测试 + Rust 集成测试
  - 更新 `BUG`/`BEFORE FIX` 标记测试以匹配正确行为

### P2 验收

```bash
cargo test -p poste-core sql_context
cargo test -p poste-core --test sql_context_golden
tests/run.sh
```

---

## P3 — ScopeResolver

**目标**: CTE/子查询/别名/派生表的显式作用域模型。移除空行边界 + `completion_ctx.lua`。

- [x] **P3a. 新 `scope.rs` 模块** — 在 `crates/poste-core/src/sql_context/scope.rs`:
  - `QueryScope { tables, ctes, aliases }`, `CteRef`, `AliasRef`
  - `resolve_scope(tokens, sql) → QueryScope`
  - 处理: 顶级 FROM/JOIN, schema.table, 别名, CTE 注册
  - 子查询/CTE 体内的表不泄漏到外部作用域
  - 派生表别名可见

- [x] **P3b. 兼容层** — `tables::extract_tables()` 内部调用 `scope::resolve_scope()`，保持返回 `Vec<TableRef>`。

- [x] **P3c. 更新 `detect_context()`** — 每次调用只解析一次作用域，构建 `ContextResult`，移除重复 `extract_tables()` 调用。

- [x] **P3d. 移除空行边界** — 从 `context.rs` 移除 `is_blank_line_separator()` 逻辑。`find_statement_token_range()` 只依赖 `;`。

- [x] **P3e. 移除 `completion_ctx.lua` 启发式** — 删除 Lua SQL 启发式逻辑（非指令路径）。

### P3 验收

```bash
cargo test -p poste-core sql_context
cargo test -p poste-core --test sql_context_golden
tests/run.sh
```

---

## P4 — 持久化上下文服务

**目标**: 替换每按键 `vim.fn.system()` 为持久子进程。

### Rust CLI

- [x] **P4a. CLI 添加 serve 子命令** — `ContextAction::Serve`。读取 stdin 行分隔 JSON。
- [x] **P4b. 处理 detect 方法** → `make_detect_response()`。
- [x] **P4c. 处理 stmt 方法** → 语句跨度提取。
- [x] **P4d. 错误隔离** — 单坏请求不崩溃，返回 `{"id": N, "ok": false}`。
- [x] **P4e. EOF 时干净退出**。

### Lua 客户端

- [x] **P4f. `context_client.lua`** — `vim.fn.jobstart()`, 请求 ID 计数器, 回调映射, stderr 缓冲, 自动重启。
- [x] **P4g. 公有 API** — `detect(sql, offset, dialect, cb)`, `stmt(sql, cursor_line, cb)`, `stop()`。

### 补全集成

- [x] **P4h. `try_rust_context()` 优先走持久客户端** — 不可用时回退 `vim.fn.system()`。
- [x] **P4i. 扩展缓存** — per-buffer LRU: `bufnr|changedtick|offset|dialect`。
- [x] **P4j. 50ms 超时** — 超时返回 keyword/function 回退。

### P4 验收

```bash
cargo test -p poste-core sql_context
cargo test -p poste-cli --test cli_context_serve
tests/run.sh
```

---

## 全局提交清单 (每次提交检查)

- [ ] `cargo test -p poste-core sql_context` 通过
- [ ] `cargo clippy -p poste-core -p poste-cli -p poste-exec -- -D warnings` 无警告
- [ ] `tests/run.sh` 通过（或注明跳过 SQL 集成测试）
- [ ] 未修改 `lua/poste/http/*`, `lua/poste/completion.lua`, `lua/poste/sql/buffer.lua`
- [ ] 未修改 SQL 执行行为
