# SQL 开发进度

> 架构设计、文件隔离策略、JSON 格式规范 → 参见 `docs/sql-design.md`
> Dataset UI 交互设计 → 参见 `docs/dataset-ui-design.md`

---

## 总览

| Phase | 描述 | Steps | 状态 |
|-------|------|-------|------|
| 1A | Rust 基础设施 | 1-5 | ✅ |
| 1B | Lua Dataset 面板 | 6-12 | ✅ |
| 1C | MySQL/SQLite 执行器 | 13-14 | ✅ |
| 2 | 连接与上下文管理 | 15-19 | ✅ |
| 3 | 数据库结构浏览 | 20-23 | ✅ |
| 4 | 表操作 + DDL + 补全 | 24-27 | ✅ |
| 5 | 导入/导出 + 分页 | 28-31 | ⏳ |
| 6 | 高级特性 | 32-38 | ⏳ |

**Tests: 78 passed** · 27/38 steps done

---

## Phase 1A — Rust 基础设施

[x] **Step 1: 添加 sqlx 依赖**
- 操作文件: `Cargo.toml` (workspace), `crates/poste-exec/Cargo.toml`
- 验收: `cargo check -p poste-exec`

[x] **Step 2: Protocol 枚举添加 Sqlite**
- 操作文件: `crates/poste-core/src/request.rs`, `parser.rs`
- 验收: `cargo test -p poste-core`

[x] **Step 3: 创建 sql_dialect.rs — Dialect trait**
- 前置: Step 2
- 新建: `crates/poste-exec/src/sql_dialect.rs`
- 验收: 单元测试验证各 dialect 返回正确 SQL

[x] **Step 4: 创建 sql_parser.rs — SQL 解析器**
- 前置: Step 2
- 新建: `crates/poste-core/src/sql_parser.rs`
- 验收: 单元测试 — @connection/@database 提取、语句分割

[x] **Step 5: 创建 sql_executor.rs — PostgreSQL 执行器**
- 前置: Step 1, 3, 4
- 新建: `crates/poste-exec/src/sql_executor.rs`
- 改: `executor.rs` — SQL 协议委托给 sql_executor
- 验收: `cargo build` + CLI 执行 SELECT 返回 JSON

---

## Phase 1B — Lua Dataset 面板

[x] **Step 6: state.sql 命名空间**
- 改: `lua/poste/state.lua` — 添加 `M.sql = { context, last_dataset, pagination, cell }`

[x] **Step 7: SQL 文件类型检测**
- 改: `ftdetect/poste.vim`, `after/ftdetect/poste.vim` — *.sql/*.sqlite

[x] **Step 8: SQL 语法高亮**
- 前置: Step 7
- 新建: `syntax/poste_sql.vim`, `syntax/poste_dataset.vim`
- 新建: `ftplugin/poste_sql.vim`

[x] **Step 9: sql/format.lua — 表格渲染**
- 前置: Step 6
- 新建: `lua/poste/sql/format.lua`
- 功能: Unicode 表格、列宽自适应、CJK 字符宽度、NULL 显示

[x] **Step 10: sql/highlights.lua — extmark 高亮**
- 前置: Step 9
- 新建: `lua/poste/sql/highlights.lua`
- 组: Header/Null/CellSelected/Meta/Modified/Deleted/Added

[x] **Step 11: sql/buffer.lua — 底部水平 split + 单元格导航**
- 前置: Step 9, 10
- 新建: `lua/poste/sql/buffer.lua`
- 键位: h/l 左右, j/k 上下, 0/$ 首末列, H 表头, K 预览, yy 复制, q 关闭

[x] **Step 12: sql/context.lua + sql/init.lua — 执行入口**
- 前置: Step 5, 6, 7, 11
- 新建: `lua/poste/sql/context.lua`, `lua/poste/sql/init.lua`
- 改: `lua/poste/init.lua` — filetype 分流

**★ Phase 1 里程碑:** ✅ SELECT/INSERT/UPDATE/DELETE/错误/USE 均正确渲染；HTTP 不受影响

---

## Phase 1C — 补充执行器

[x] **Step 13: MySQL 执行器**
- 前置: Step 5
- 改: `sql_executor.rs` — execute_mysql() + mysql_value_to_json()

[x] **Step 14: SQLite 执行器**
- 前置: Step 5
- 改: `sql_executor.rs` — execute_sqlite() + normalize_sqlite_connection()

---

## Phase 2 — 连接与上下文管理

[x] **Step 15: sql_connection.rs — connections.json 管理**
- 前置: Step 5
- 新建: `crates/poste-exec/src/sql_connection.rs`
- 功能: ConnectionConfig, ConnectionStore::load/resolve, test_connection()

[x] **Step 16: CLI connection 子命令**
- 前置: Step 15
- 改: `main.rs` — `poste connection list/test`

[x] **Step 17: @connection 名称解析**
- 前置: Step 15
- 改: `main.rs` — 名称→connections.json→URL，协议自动检测

[x] **Step 18: sql/connections.lua — 连接管理 UI**
- 前置: Step 16, 17
- 新建: `lua/poste/sql/connections.lua`
- 命令: `:PosteConnection` — 选择/测试连接

[x] **Step 19: 上下文切换命令**
- 前置: Step 18
- 改: `lua/poste/init.lua` — `:PosteSQLContext` 命令 + 状态栏集成

**★ Phase 2 里程碑:** ✅ connections.json 管理、@connection 名称解析、USE 上下文更新、状态栏显示

---

## Phase 3 — 数据库结构浏览

[x] **Step 20: sql_introspect.rs — 内省查询**
- 前置: Step 3, 5
- 新建: `crates/poste-exec/src/sql_introspect.rs`
- 功能: list_databases/schemas/tables/columns/indexes

[x] **Step 21: CLI introspect 子命令**
- 前置: Step 20
- 改: `main.rs` — `poste introspect <conn> --type tables --json`

[x] **Step 22: sql/db_browser.lua — 树形浏览器**
- 前置: Step 21
- 新建: `lua/poste/sql/db_browser.lua`
- 命令: `:PosteDBBrowser` — 侧边栏 40 列，懒加载，缓存，r 刷新
- 键位: CR 展开/折叠, / 搜索, s 生成 SELECT, d 生成 DESCRIBE, q 关闭

[x] **Step 23: 快速查询生成**
- 前置: Step 22
- 功能: 浏览器中 `s` → 在当前 SQL 文件插入查询

**★ Phase 3 里程碑:** ✅ DB Browser 树形浏览 → 生成查询 → 执行 → Dataset 显示

---

## Phase 4 — 表操作 + DDL + 补全

[x] **Step 24: sql_ddl.rs — DDL 生成器**
- 前置: Step 3
- 新建: `crates/poste-exec/src/sql_ddl.rs`
- 功能: DdlGenerator trait + 三个 dialect 实现

[x] **Step 25: sql/table_ops.lua — 表修改 UI**
- 前置: Step 22, 24
- 新建: `lua/poste/sql/table_ops.lua`
- 键位: ma(添加列)/mr(重命名)/md(删除)/mt(改类型) → 生成 DDL

[x] **Step 26: sql/completion.lua — SQL 补全**
- 前置: Step 7, 20
- 新建: `lua/poste/sql/completion.lua`
- 补全: SQL 关键字、连接名称、表名、列名、数据类型

[x] **Step 27: Phase 4 集成测试**
- 前置: Step 24, 25, 26

---

## Phase 5 — 导入/导出 + 分页

[ ] **Step 28: sql/export.lua — 导出功能**
- 前置: Step 12
- 新建: `lua/poste/sql/export.lua`
- 键位: ec(CSV)/ej(JSON)/es(SQL INSERT)

[ ] **Step 29: sql/import.lua — 导入功能**
- 前置: Step 12, 19
- 新建: `lua/poste/sql/import.lua`
- 命令: `:PosteImport <file>`

[ ] **Step 30: sql/pagination.lua — 结果分页**
- 前置: Step 11
- 新建: `lua/poste/sql/pagination.lua`
- 键位: n/p/f/l/g — LIMIT/OFFSET 翻页

[ ] **Step 31: Phase 5 集成测试**

---

## Phase 6 — 高级特性

[ ] **Step 32: sql/editor.lua — Dataset 数据编辑**
- 前置: Step 11
- 新建: `lua/poste/sql/editor.lua`
- 键位: i/a/cc 编辑, dd 删除行, o/O 新增行, u 撤销

[ ] **Step 33: 编辑提交 — 差异对比 + DML 生成**
- 前置: Step 32
- 命令: `:W` 提交 → 生成 UPDATE/INSERT/DELETE → 执行

[ ] **Step 34: 表头排序与过滤**
- 前置: Step 11, 30
- 表头行: s 排序(ASC/DESC/Clear), f 过滤

[ ] **Step 35: 列复制 + 外键跳转**
- 前置: Step 11, 20
- 键位: yy 复制单元格, leader+yc 复制整列, gd 外键跳转

[ ] **Step 36: 多结果集标签页**
- 前置: Step 11
- Winbar 显示 [1] [2] 标签，数字键切换

[ ] **Step 37: 事务支持**
- 前置: Step 5
- 改: `sql_executor.rs` — BEGIN...COMMIT 包裹事务，失败自动 ROLLBACK

[ ] **Step 38: 查询历史**
- 前置: Step 12
- 新建: `lua/poste/sql/history.lua`
- 命令: `:PosteHistory`

---

## 依赖图

```
Phase 1A:  1→3→5→13    2→4→5→14
Phase 1B:  6→9→10→11→12    7→8
Phase 1C:  5→13,14
Phase 2:   5→15→16→17→18→19
Phase 3:   3,5→20→21→22→23
Phase 4:   3→24    22,24→25    7,20→26
Phase 5:   12→28,29    11→30
Phase 6:   11→32→33,34,35,36    5→37    12→38
```

---

## AI Agent 快速上手

1. **确认位置**: 找上方第一个 `[ ]` Step
2. **读设计**: `docs/sql-design.md` → 文件隔离策略 + 架构决策
3. **读步骤**: 该 Step 的前置依赖 + 操作文件 + 功能要求
4. **实现 + 验证**: 完成后 `[ ]` → `[x]`，跑 `cargo test`
5. **提交**

**关键文件索引**:

| 想了解什么 | 看哪个文件 |
|-----------|-----------|
| HTTP 执行模式（参考） | `lua/poste/init.lua` → `run_request()` |
| Rust executor 模式 | `crates/poste-exec/src/executor.rs` → `execute_redis()` |
| 响应数据结构 | `crates/poste-exec/src/response.rs` |
| 解析器模式 | `crates/poste-core/src/parser.rs` |
| 结果格式化模式 | `lua/poste/format.lua` → `format_redis_body()` |
| 响应面板模式 | `lua/poste/buffer.lua` |
| SQL 文件示例 | `examples/queries.sql` |
| Dataset UI 设计 | `docs/dataset-ui-design.md` |

---

## 已完成的文件清单

### 新建 — Rust (6)
| 文件 | Step |
|------|------|
| `crates/poste-core/src/sql_parser.rs` | 4 |
| `crates/poste-exec/src/sql_dialect.rs` | 3 |
| `crates/poste-exec/src/sql_executor.rs` | 5,13,14 |
| `crates/poste-exec/src/sql_connection.rs` | 15 |
| `crates/poste-exec/src/sql_introspect.rs` | 20 |
| `crates/poste-exec/src/sql_ddl.rs` | 24 |

### 新建 — Lua (9)
| 文件 | Step |
|------|------|
| `lua/poste/sql/init.lua` | 12 |
| `lua/poste/sql/buffer.lua` | 11 |
| `lua/poste/sql/format.lua` | 9 |
| `lua/poste/sql/highlights.lua` | 10 |
| `lua/poste/sql/connections.lua` | 18 |
| `lua/poste/sql/context.lua` | 19 |
| `lua/poste/sql/db_browser.lua` | 22,23 |
| `lua/poste/sql/table_ops.lua` | 25 |
| `lua/poste/sql/completion.lua` | 26 |

### 新建 — VimScript (3)
| 文件 | Step |
|------|------|
| `syntax/poste_sql.vim` | 8 |
| `syntax/poste_dataset.vim` | 8 |
| `ftplugin/poste_sql.vim` | 8 |

### 修改 (15)
| 文件 | Step | 改动 |
|------|------|------|
| `Cargo.toml` | 1 | 添加 sqlx |
| `crates/poste-exec/Cargo.toml` | 1,15 | sqlx + regex |
| `crates/poste-cli/Cargo.toml` | 16 | regex |
| `crates/poste-core/src/request.rs` | 2 | Sqlite 变体 |
| `crates/poste-core/src/parser.rs` | 2 | sqlite 检测 |
| `crates/poste-core/src/lib.rs` | 4 | pub mod sql_parser |
| `crates/poste-exec/src/executor.rs` | 5 | SQL 委托 |
| `crates/poste-exec/src/sql_executor.rs` | 20 | normalize_sqlite_connection pub(crate) |
| `crates/poste-exec/src/lib.rs` | 3,5,15,20 | 模块导出 |
| `crates/poste-cli/src/main.rs` | 16,17,21 | connection 子命令 + introspect 子命令 |
| `lua/poste/state.lua` | 6,22 | M.sql 命名空间 + db_browser |
| `lua/poste/init.lua` | 12,18,19,22 | filetype 分流 + 命令注册 + DB Browser |
| `lua/poste/highlights.lua` | 10 | SQL 高亮组 |
| `ftdetect/poste.vim` | 7 | *.sql/*.sqlite |
| `after/ftdetect/poste.vim` | 7 | 覆盖内置检测 |
