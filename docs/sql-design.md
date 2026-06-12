# SQL 功能完整规划 — JetBrains Database 风格

## Context

Poste 目前已完成 HTTP 和 Redis 的完整实现，SQL（PostgreSQL、MySQL）仅存骨架（stub）。用户希望将 SQL 文件功能做到接近 JetBrains Database 插件的体验，包括：连接管理、多数据库方言、数据库结构浏览、表操作、导入导出、SQL 文件执行、以及丰富的结果面板。

本规划按 6 个阶段递进，每个阶段独立可交付。

---

## 文件隔离策略

SQL 功能与 HTTP/Redis 功能尽量隔离，避免互相影响。只在真正需要共享的基础设施层共用文件。

### 共享文件（真正公共基础设施，最小改动）

| 文件 | 改动范围 | 说明 |
|------|----------|------|
| `crates/poste-core/src/request.rs` | 添加 `Sqlite` 枚举变体 | Protocol 枚举和 Request 结构体是所有协议共享的类型 |
| `crates/poste-core/src/lib.rs` | 添加 `pub mod sql_parser` 导出 | 模块注册 |
| `crates/poste-core/src/parser.rs` | **仅添加** SQL 协议分发入口 | `parse_block()` 中 SQL 协议委托给 `sql_parser`，不修改 HTTP/Redis 解析逻辑 |
| `crates/poste-exec/src/lib.rs` | 添加 `pub mod sql_executor` 导出 | 模块注册 |
| `crates/poste-exec/src/executor.rs` | **仅修改** dispatch 分支 | `Protocol::Postgres/Mysql/Sqlite` 委托给 `sql_executor`，删除 stub 函数，不改动 HTTP/Redis |
| `crates/poste-cli/src/main.rs` | 添加 `connection` / `introspect` 子命令 | CLI 入口是所有协议共享的调度器 |
| `lua/poste/init.lua` | `run_request()` 中按 filetype 分流 | 检测 `poste_sql` → 调用 `sql.run_sql_request()`，HTTP/Redis 流程完全不变 |
| `lua/poste/state.lua` | 添加 `M.sql = {}` 命名空间 | SQL 专属状态（当前连接、分页等）放在 `state.sql` 下，不污染 HTTP 状态 |
| `lua/poste/buffer.lua` | **不改** | HTTP 专用右侧垂直 split — SQL 有自己的 `sql/buffer.lua`（底部水平 split） |
| `lua/poste/select.lua` | **不改** | Picker UI 是通用组件 |
| `lua/poste/indicators.lua` | **不改** | 通用组件：spinner/✓/✘ 对 SQL 同样适用 |
| `ftdetect/poste.vim` | 添加 2 行 autocmd | `*.sql` → `poste_sql`，`*.sqlite` → `poste_sqlite` |
| `Cargo.toml` (workspace + exec) | 添加 `sqlx` 依赖 | 依赖声明层面 |

### SQL 独立文件（与 HTTP 完全隔离）

**Rust — 新建模块：**
| 文件 | 说明 |
|------|------|
| `crates/poste-core/src/sql_parser.rs` | SQL 专用解析：`@connection` 提取、语句分割、变量替换（复用 `parser.rs` 的 `substitute_vars` 方法） |
| `crates/poste-exec/src/sql_executor.rs` | SQL 执行入口：`execute_postgres()` / `execute_mysql()` / `execute_sqlite()` |
| `crates/poste-exec/src/sql_dialect.rs` | Dialect trait + PostgresDialect / MysqlDialect / SqliteDialect |
| `crates/poste-exec/src/sql_connection.rs` | 连接配置管理、`connections.json` 读写、连接测试 |
| `crates/poste-exec/src/sql_introspect.rs` | 数据库内省查询（schema/table/column/index 查询 SQL） |
| `crates/poste-exec/src/sql_ddl.rs` | DDL 语句生成器 |

**Lua — 新建模块（14 个）：**
| 文件 | 说明 |
|------|------|
| `lua/poste/sql/init.lua` | SQL 执行入口 `run_sql_request()`，对应 HTTP 的 `init.lua` 中的 `run_request()` |
| `lua/poste/sql/buffer.lua` | SQL 结果面板窗口管理（**底部水平 split**，单元格导航键位，编辑模式） |
| `lua/poste/sql/format.lua` | SQL 结果表格渲染（conceal 隐藏分隔符、Virtual Text） |
| `lua/poste/sql/verbose.lua` | SQL Verbose 视图格式化 |
| `lua/poste/sql/highlights.lua` | SQL 结果面板 extmark 高亮 + 变更追踪着色 |
| `lua/poste/sql/context.lua` | SQL 执行上下文管理（connection → database → schema 层级） |
| `lua/poste/sql/completion.lua` | SQL 补全源（关键字、表名、列名） |
| `lua/poste/sql/connections.lua` | 连接管理 UI（CRUD、测试、选择器） |
| `lua/poste/sql/db_browser.lua` | 数据库树形浏览器 |
| `lua/poste/sql/table_ops.lua` | 表操作 UI |
| `lua/poste/sql/export.lua` | 导出功能（CSV/JSON/SQL） |
| `lua/poste/sql/import.lua` | 导入功能 |
| `lua/poste/sql/pagination.lua` | 结果分页状态管理 |
| `lua/poste/sql/editor.lua` | Dataset 数据编辑（差异计算 + DML 生成 + 变更追踪） |

**VimScript — 新建：**
| 文件 | 说明 |
|------|------|
| `syntax/poste_sql.vim` | SQL 文件语法高亮（完全独立于 `syntax/poste_http.vim`） |
| `ftplugin/poste_sql.vim` | SQL filetype 插件（commentstring、补全源注册） |

### 隔离原则总结

```
HTTP 改动 → 只影响 lua/poste/{init,format,completion,buffer,...}.lua
SQL 改动  → 只影响 lua/poste/sql/*.lua + crates/*/src/sql_*.rs
共享层    → request.rs(类型) + parser.rs(分发) + executor.rs(分发) + init.lua(分流) + select/indicators/symbols(通用UI)
```

**关键分流点**：`lua/poste/init.lua` 的 `run_request()` 函数开头检测 filetype：
```lua
function M.run_request()
  local ft = vim.bo.filetype
  if ft == "poste_sql" or ft == "poste_sqlite" then
    require("poste.sql.init").run_sql_request()
    return
  end
  -- ... 原有 HTTP/Redis 流程完全不变 ...
end
```

Rust 端类似：`executor.rs` 中 SQL 协议分支直接调用 `sql_executor::execute()`，不混合逻辑。

---

## 架构决策

### 1. 数据库客户端库：使用 `sqlx`

**选择 `sqlx`** 而非独立 crate（tokio-postgres + mysql-async + rusqlite），原因：
- 统一 API 覆盖 PostgreSQL / MySQL / SQLite 三种数据库
- 内置连接池（`sqlx::Pool`），避免手动管理
- 运行时特性 `runtime-tokio` 与 Poste 的 Tokio 异步架构一致
- 减少代码重复：一套 `query()` / `fetch_all()` 接口适配三种数据库

```toml
# crates/poste-exec/Cargo.toml 新增
sqlx = { version = "0.8", features = ["runtime-tokio", "postgres", "mysql", "sqlite"] }
```

### 2. 连接配置存储：独立 `connections.json`

不扩展 `env.json`（它仅管环境变量），使用独立的 `connections.json`：

```json
{
  "dev-pg": {
    "dialect": "postgres",
    "host": "localhost",
    "port": 5432,
    "database": "myapp",
    "user": "admin",
    "password": "{{db_password}}"
  },
  "local-sqlite": {
    "dialect": "sqlite",
    "path": "./data/app.db"
  },
  "staging-mysql": {
    "dialect": "mysql",
    "host": "{{mysql_host}}",
    "port": 3306,
    "database": "staging_db",
    "user": "root",
    "password": "{{mysql_pass}}"
  }
}
```

文件发现路径：与 `env.json` 一致，从 SQL 文件所在目录向上查找。

### 3. Dialect 抽象层

在 `poste-core` 中定义 `Dialect` trait，每个数据库实现自己的方言差异：

```rust
pub trait Dialect: Send + Sync {
    fn name(&self) -> &str;                           // "postgres" | "mysql" | "sqlite"
    fn list_databases(&self) -> &str;                 // 列出数据库的 SQL
    fn list_schemas(&self) -> Option<&str>;           // PostgreSQL 有 schema，MySQL/SQLite 没有
    fn list_tables(&self) -> &str;                    // 列出表
    fn list_columns(&self) -> &str;                   // 列出列
    fn list_indexes(&self) -> &str;                   // 列出索引
    fn describe_table(&self) -> &str;                 // 表结构详情
    fn supports_schema(&self) -> bool;                // 是否支持 schema 层级
    fn quote_identifier(&self, name: &str) -> String; // 标识符引用 ("name" vs `name`)
    fn default_port(&self) -> u16;                    // 默认端口
    fn type_mapping(&self, col_type: &str) -> &str;   // 类型映射显示
}
```

### 4. SQL Response JSON 格式

扩展 Response 的 body 字段为结构化 JSON（类似 Redis 的做法）：

**SELECT 查询：**
```json
{
  "type": "resultset",
  "results": [
    {
      "columns": [
        { "name": "id", "type": "integer", "nullable": false },
        { "name": "name", "type": "varchar(255)", "nullable": true }
      ],
      "rows": [
        [1, "Alice"],
        [2, "Bob"]
      ],
      "row_count": 2,
      "affected_rows": null,
      "execution_time_ms": 12
    }
  ],
  "total_results": 1,
  "connection": "dev-pg",
  "database": "myapp_db",
  "dialect": "postgres",
  "is_use_statement": false
}
```

**非 SELECT 语句（INSERT/UPDATE/DELETE/DDL）：**
```json
{
  "type": "affected",
  "results": [
    {
      "columns": [],
      "rows": [],
      "row_count": 0,
      "affected_rows": 5,
      "execution_time_ms": 3
    }
  ],
  "connection": "dev-pg",
  "database": "myapp_db",
  "dialect": "postgres",
  "is_use_statement": false
}
```

**USE 语句：**
```json
{
  "type": "use",
  "database_name": "myapp_db",
  "is_use_statement": true,
  "connection": "dev-pg",
  "dialect": "postgres"
}
```

### 5. SQL 执行上下文（Connection → Database 两层模型）

类似 JetBrains Database 插件，SQL 执行有一个两层上下文模型：

```
Connection (dev-pg)  ──→  Database (myapp_db)
     ↑                        ↑
  @connection 指定         context database
```

**三种使用模式：**

**模式 A — 指定完整上下文（connection + database）：**
```sql
-- @connection dev-pg
-- @database myapp_db
SELECT * FROM users;  -- 直接执行在 myapp_db 中
```
- 通过 `-- @database` 指令或 `:PosteSQLContext` 命令设定
- 状态栏显示：`[env: dev] [db: dev-pg/myapp_db]`

**模式 B — 仅指定 connection，通过 `USE` 动态切换：**
```sql
-- @connection dev-pg
USE myapp_db;         -- 执行后，myapp_db 成为当前文件的 context database

SELECT * FROM users;  -- 在 myapp_db 上下文中执行
```
- `USE dbname;` 执行成功后，将 `dbname` 设为当前 SQL 文件的 context
- 后续的 SQL 语句都继承这个 database context
- 同一个文件中可以多次 `USE` 切换

**模式 C — 不指定 database，直接跨库查询：**
```sql
-- @connection dev-pg
SELECT * FROM myapp_db.users;          -- 直接指定 dbname.table
SELECT * FROM other_db.orders;         -- 可以跨多个数据库
```
- 不需要 `-- @database` 或 `USE`
- 直接在 SQL 中用 `dbname.table` 格式引用

**Rust 端实现**（`sql_executor.rs` 中）：
- 解析 `-- @database` 指令，或检测 `USE dbname;` 语句
- 对于 PostgreSQL：`USE dbname` → `\c dbname`（实际是重新连接到指定 database）
- 对于 MySQL：`USE dbname` → 执行 `USE dbname` 语句
- 对于 SQLite：不适用（单文件数据库）
- 连接池按 `connection + database` 组合键缓存复用

**Lua 端实现**（`sql/context.lua` 中）：
- 解析当前 SQL 文件中的 `@database` 指令和 `USE` 语句
- 维护 `state.sql.context = { connection = "dev-pg", database = "myapp_db" }`
- 状态栏集成：`_G.poste_status()` 返回 `[env: dev] [db: dev-pg/myapp_db]`

### 6. 结果面板设计（DataGrip 风格的 Dataset Buffer）

参考 `dataset-ui-design.md` 的设计理念，SQL 结果面板不是简单的文本输出，而是一个**可交互的 Dataset Buffer**。

#### 6.1 窗口布局：底部水平分屏

```
+-------------------------------------------------------------+
|  -- @connection dev-pg                                       |
|  -- @database myapp_db                                       |
|                                                              |
|  SELECT * FROM users WHERE status = 'active';                |
|                                                              |
|  [SQL Source Buffer] (Normal / Insert Mode)                  |
+-------------------------------------------------------------+
|  id  │ username │ email                │ created_at    │     |
|  1   │ alice    │ alice@example.com    │ 2026-06-01   │     |
|  2   │ bob      │ bob@example.com      │ 2026-06-02   │     |
|                                                              |
|  [SQL Dataset Buffer] (Dataset Mode)                         |
+-------------------------------------------------------------+
| [Status] 2 rows | Conn: dev-pg/myapp_db | 12ms | [Log] ✓    |
+-------------------------------------------------------------+
```

**关键区别**：
- HTTP 结果在**右侧垂直 split**（80 列）— 适合 JSON/文本响应
- SQL 结果在**底部水平 split**（占屏幕 40% 高度）— 适合宽表格（多列）
- 因此 SQL 需要自己的 `sql/buffer.lua`，不复用 HTTP 的 `buffer.lua`

#### 6.2 Dataset Buffer 属性
- **Filetype:** `poste_dataset`
- **Modifiable:** 默认 `nomodifiable`（只读），进入编辑模式后 `modifiable`
- **Conceal:** 使用 `conceallevel=2` 隐藏表格分隔符 `│`，只显示对齐的数据
- **Virtual Text:** NULL 值用灰色 Virtual Text 显示 `(NULL)`

#### 6.3 单元格导航（Cell-based Motion）

结果集中一个"单元格 (Cell)"是最小移动单位，而非字符：

| 键位 | 行为 | Vim 类比 |
|------|------|----------|
| `h` / `l` | 左/右切换单元格 | 方向移动 |
| `j` / `k` | 上/下切换行 | 行移动 |
| `0` / `$` | 跳到当前行第一列 / 最后一列 | 行首/行尾 |
| `gg` / `G` | 跳到第一行 / 最后一行 | 文件首/尾 |
| `H` | 跳到表头行（查看字段类型） | 窗口顶部 |
| `ctrl-f` / `ctrl-b` | 翻页 | 翻页 |
| `/` | 结果集内搜索（高亮匹配格子） | 原生搜索 |

**实现方式**：在 `sql/buffer.lua` 中设置自定义键位映射，通过 extmark 追踪单元格的列边界，`h`/`l` 跳转到相邻列的起始位置。

#### 6.4 查看长文本 / JSON（`K` 悬浮预览）

数据库中长 JSON 或 Text 在 Grid 中显示不全：
- **键位：** `K`（Vim 原生用于 Hover / Documentation）
- **行为：** 弹出 Floating Window，内含临时 Buffer
- **自动 filetype：** JSON 内容 → `filetype=json`，SQL → `filetype=sql`
- **浏览：** 可在浮动窗中用 `G`、`gg`、`/` 浏览
- **关闭：** `q` 或 `<Esc>`

#### 6.5 数据编辑（Phase 5+ 高级特性，Phase 1 仅只读）

**单元格编辑**（未来实现，Phase 1 先规划好数据结构）：
- `i` / `a` / `cc` — 弹出单行浮动输入框，自动继承原值
- `<Esc>` / `<CR>` — 完成编辑，单元格高亮标记为 Modified（黄色）
- `u` — 撤销上一次单元格修改

**行操作**：
- `dd` — 标记当前行为 Deleted（红色删除线高亮，行不消失）
- `o` / `O` — 在下方/上方插入空记录，主键显示 Virtual Text `[Auto]`

**提交 / 回滚**：
- `:W` 或 `<leader>w` — Write：对比差异，生成 `UPDATE/INSERT/DELETE` 语句并执行
- `R` 或 `:e!` — Refresh：放弃所有修改，重新拉取数据

**变更着色**：
- 黄色 = 已修改的单元格
- 红色 = 已删除的行
- 绿色 = 新增的行

#### 6.6 字段过滤与排序（表头操作）

| 键位 | 触发位置 | 行为 |
|------|----------|------|
| `s` | 表头单元格 | 弹出菜单：Ascending / Descending / Clear Sort |
| `f` | 表头单元格 | 底部命令行：`:PosteSQLFilter [列名] = `，输入过滤条件 |

#### 6.7 快捷复制（Yank Matrix）

| 键位 | 行为 |
|------|------|
| `yy` | 复制当前单元格值到 `"` 寄存器 |
| `<leader>yc` | Yank Column：复制整列所有值，逗号分隔 |

#### 6.8 关系型跳转（Go to Definition）

| 键位 | 行为 |
|------|------|
| `gd` | 在外键单元格上，自动解析 FK 关系，在下方开新 split 执行 `SELECT * FROM target_table WHERE id = [当前值]` |

---

## Phase 1 — 核心 SQL 执行引擎（关键路径）

> **目标**: 在 .sql 文件中按 `<leader>rr` 执行查询，结果以 Dataset 表格形式展示在底部水平 split panel 中

### Rust 端实现

#### 1.1 添加 sqlx 依赖
**修改**: `Cargo.toml` (workspace), `crates/poste-exec/Cargo.toml`
- 添加 `sqlx` 依赖，features: `runtime-tokio, postgres, mysql, sqlite`

#### 1.2 实现 Dialect trait
**新建**: `crates/poste-exec/src/sql_dialect.rs`
- `Dialect` trait 定义
- `PostgresDialect`, `MysqlDialect`, `SqliteDialect` 三个实现
- `fn dialect_for(protocol: &Protocol) -> Box<dyn Dialect>`

#### 1.3 SQL 语句分割
**新建**: `crates/poste-core/src/sql_parser.rs`
- SQL 专用解析器：正确提取 SQL body（跳过 `-- @connection` 和 `-- @` 变量行）
- 支持多条语句按 `;` 分割（但保留存储过程中的复杂分号场景）
- 复用 `parser.rs` 的 `substitute_vars()` 方法进行变量替换

**最小改动**: `crates/poste-core/src/parser.rs`
- `parse_block()` 中仅添加一行分发：SQL 协议委托给 `sql_parser::parse_sql_block()`

#### 1.4 实现 PostgreSQL / MySQL / SQLite 执行器
**新建**: `crates/poste-exec/src/sql_executor.rs`
- `execute_sql()` 入口函数，根据 Protocol 分发到具体实现
- `execute_postgres()` — 使用 `sqlx::PgPool`
- `execute_mysql()` — 使用 `sqlx::MySqlPool`
- `execute_sqlite()` — 使用 `sqlx::SqlitePool`（连接是文件路径）

```rust
pub async fn execute_sql(request: &Request) -> Result<Response> {
    match request.protocol {
        Protocol::Postgres => execute_postgres(request).await,
        Protocol::Mysql => execute_mysql(request).await,
        Protocol::Sqlite => execute_sqlite(request).await,
        _ => anyhow::bail!("Not a SQL protocol"),
    }
}
```

执行流程（以 PostgreSQL 为例）：
1. `PgPool::connect(&request.connection)` 建立连接
2. 按 `;` 分割 body 为多条语句
3. 逐条执行，区分 SELECT（返回结果集）和 DML/DDL（返回 affected_rows）
4. 将 `pg::Row` 的列信息提取为 `Column { name, type, nullable }`
5. 将行数据转换为 `Vec<Vec<Value>>`（JSON 安全的通用值类型）
6. 组装为 Response JSON 格式

**最小改动**: `crates/poste-exec/src/executor.rs`
- 仅修改 dispatch 分支：`Protocol::Postgres/Mysql/Sqlite` → 调用 `sql_executor::execute_sql()`
- 删除原有的 3 个 stub 函数

**最小改动**: `crates/poste-core/src/request.rs`
- `Protocol` 枚举添加 `Sqlite` 变体（一行）

**最小改动**: `crates/poste-core/src/parser.rs`
- `detect_protocol()`: 添加 `"sqlite" => Protocol::Sqlite`（一行）
- SQLite 的 `@connection` 支持文件路径格式

### Lua 端实现

#### 1.7 SQL Dataset 面板 — 底部水平分屏
**新建**: `lua/poste/sql/buffer.lua`

SQL 结果面板与 HTTP 完全不同（不复用 `lua/poste/buffer.lua`）：

```
+-------------------------------------------------------------+
|  [SQL Source Buffer] (Normal / Insert Mode)                  |
+-------------------------------------------------------------+
|  id  │ username │ email                │ created_at          |
|  1   │ alice    │ alice@example.com    │ 2026-06-01         |
|  2   │ bob      │ bob@example.com      │ 2026-06-02         |
|                                                              |
|  [SQL Dataset Buffer] (Dataset Mode)     ← 底部水平 split    |
+-------------------------------------------------------------+
| [Status] 2 rows | Conn: dev-pg/myapp_db | 12ms | [Log] ✓   |
+-------------------------------------------------------------+
```

**与 HTTP buffer.lua 的关键区别**：
| | HTTP `buffer.lua` | SQL `sql/buffer.lua` |
|---|---|---|
| 分屏方向 | 右侧垂直 split | **底部水平 split** |
| 默认尺寸 | 80 列宽 | 屏幕高度 40% |
| 导航模式 | 普通文本光标 | **单元格 (Cell) 导航** |
| 内容类型 | JSON/文本/markdown | **二维表格 Grid** |
| Buffer 名 | `poste://response` | `poste://dataset` |
| Winbar 标签 | Body / Verbose / Asserts | Dataset / Verbose / (多结果集标签) |
| 键位绑定 | `B`/`I`/`A`/`S` + `q` | `h`/`j`/`k`/`l` 单元格导航 + `K` 预览 + `q` |

**实现要点**：
- `open_dataset_split()` — 底部 `split`（水平），占屏幕 40% 高度
- 状态行（statusline）显示：行数、连接+数据库、耗时、执行状态
- Winbar 标签切换：多结果集时显示 `[1]` `[2]` 等
- 键位：`q` 关闭、`<Tab>`/`<S-Tab>` 切换标签

#### 1.8 SQL Dataset 渲染 — 表格格式化
**新建**: `lua/poste/sql/format.lua`

Dataset 渲染（参考 `dataset-ui-design.md`）：

```
 id  │ username │ email                │ created_at
─────┼──────────┼──────────────────────┼────────────
 1   │ alice    │ alice@example.com    │ 2026-06-01
 2   │ bob      │ bob@example.com      │ 2026-06-02
```

实现要点：
- 解析 JSON body，提取 columns 和 rows
- 计算每列最大宽度（考虑中文字符宽度、`displaywidth`）
- 使用 `│` 作为列分隔符（配合 `conceallevel=2` 隐藏，只显示对齐数据）
- NULL 值用 Virtual Text 灰色显示 `(NULL)`
- 单元格内容截断显示（超出列宽部分用 `…` 代替）
- 底部状态行：`2 rows returned · 12ms · dev-pg/myapp_db`

**Conceal 机制**：
- 列分隔符 `│` 使用 `conceal` 属性，渲染时不可见
- 用户看到的是整齐对齐的列数据，视觉上接近 DataGrip 的 Grid

#### 1.9 单元格导航系统
**在 `sql/buffer.lua` 中实现**：

用 extmark 追踪每个单元格的列边界位置：
```lua
-- 每行的单元格边界记录
-- { {start_col=0, end_col=5}, {start_col=6, end_col=15}, ... }
local cell_boundaries = {}
```

键位映射（Dataset Buffer 内）：
| 键位 | 行为 |
|------|------|
| `h` / `l` | 光标跳到左/右相邻单元格的 start_col |
| `j` / `k` | 上/下行（保持当前列） |
| `0` / `$` | 第一列 / 最后一列 |
| `gg` / `G` | 首行 / 末行 |
| `H` | 跳到表头行（行 1） |
| `/` | 结果集内搜索，匹配单元格高亮 |

#### 1.10 长文本悬浮预览（`K`）
**在 `sql/buffer.lua` 中实现**：

- `K` — 检测当前单元格内容，弹出 Floating Window 显示完整值
- 自动检测内容类型并设置 filetype（JSON → `json`，XML → `xml`）
- 浮动窗内可正常浏览（`G`、`gg`、`/`），`q` 或 `<Esc>` 关闭
- 浮动窗大小：最大 80×24，自适应内容

#### 1.11 SQL extmark 高亮
**新建**: `lua/poste/sql/highlights.lua`
- 表头行用 `PosteSqlHeader` 高亮（加粗 + 下划线）
- NULL 值用 `PosteSqlNull` 高亮（灰色斜体）
- 数字列右对齐显示
- 当前选中单元格用 `PosteSqlCellSelected` 高亮（反色背景）
- 统计行用 `PosteSqlMeta` 高亮
- SQL highlight 组定义（独立于 `lua/poste/highlights.lua`）

#### 1.12 SQL 执行上下文
**新建**: `lua/poste/sql/context.lua`

管理当前 SQL 文件的执行上下文：

```lua
-- state.sql.context 结构
M.context = {
  connection = nil,    -- "dev-pg" (从 @connection 解析)
  database = nil,      -- "myapp_db" (从 @database 或 USE 语句解析)
}

-- 解析当前文件的上下文
function M.resolve_context(buf)
  -- 1. 扫描文件头 @connection 和 @database 指令
  -- 2. 扫描光标之前的 USE dbname; 语句
  -- 3. 返回 { connection = "...", database = "..." }
end

-- USE 语句检测：执行 USE dbname; 后自动更新 context
function M.handle_use_statement(response)
  if response.is_use_statement then
    M.context.database = response.database_name
  end
end
```

#### 1.13 SQL 文件类型支持
**新建**: `syntax/poste_sql.vim`（完全独立于 `syntax/poste_http.vim`）
- SQL 关键字高亮（SELECT, FROM, WHERE, JOIN, INSERT, UPDATE, DELETE, CREATE, ALTER, DROP 等）
- `@connection` 指令高亮
- `@database` 指令高亮
- `@variable` 定义高亮
- `{{var}}` 变量引用高亮
- SQL 注释（`--`）高亮
- 字符串字面量高亮

**新建**: `syntax/poste_dataset.vim`
- Dataset Buffer 的 filetype 语法（表头行、分隔符 conceal、NULL 等）

**最小改动**: `ftdetect/poste.vim`（添加 2 行）
- `autocmd BufRead,BufNewFile *.sql setfiletype poste_sql`
- `autocmd BufRead,BufNewFile *.sqlite setfiletype poste_sqlite`

**新建**: `ftplugin/poste_sql.vim`
- `commentstring` 设置为 `-- %s`
- completion source 配置

#### 1.14 完善 Verbose 视图
**新建**: `lua/poste/sql/verbose.lua`
- SQL 协议的 verbose 输出格式化（独立于 `lua/poste/format.lua`）：
  - 执行的原始 SQL
  - 连接信息（host、database、dialect）
  - 当前上下文（connection + database）
  - 每个结果集的执行时间
  - 查询计划（如果使用了 EXPLAIN）

#### 1.15 SQL 执行入口
**新建**: `lua/poste/sql/init.lua`
- `run_sql_request()` — SQL 专用的执行流程
- **上下文解析**：执行前调用 `sql/context.lua` 获取当前 connection + database
- 调用 Rust CLI 执行查询，传递上下文参数
- **USE 语句处理**：检测到 `USE dbname;` 执行成功后，更新 `state.sql.context.database`
- 调用 `sql/buffer.lua` 在底部水平 split 中渲染 Dataset
- 复用 `indicators.lua` 在源文件中显示 spinner/✓/✘
- 调用 `sql/format.lua` 渲染表格、调用 `sql/verbose.lua` 渲染 verbose

**最小改动**: `lua/poste/init.lua`（添加 ~5 行分流代码）
- `run_request()` 开头检测 filetype，`poste_sql`/`poste_sqlite` → 调用 `sql.init.run_sql_request()`
- 其余 HTTP/Redis 流程完全不变

### 交付物
- 在 `.sql` 文件中执行 SELECT 查询，结果在**底部水平 split** 中以 Dataset 表格展示
- 单元格导航（`h`/`j`/`k`/`l` 在单元格间跳转）
- `K` 悬浮预览长文本/JSON
- 支持 `-- @database` 和 `USE dbname;` 上下文切换
- 支持 `dbname.table` 跨库查询
- 多条语句依次执行，多结果集标签切换
- INSERT/UPDATE/DELETE 显示受影响行数
- 错误查询显示错误信息
- 状态栏显示当前上下文：`[env: dev] [db: dev-pg/myapp_db]`

---

## Phase 2 — 连接与上下文管理

> **目标**: 提供连接的 CRUD 管理，支持连接测试，实现 Connection → Database 两层上下文切换

### 2.1 连接配置管理（Rust 端）
**新建**: `crates/poste-exec/src/sql_connection.rs`
```rust
pub struct ConnectionConfig {
    pub name: String,
    pub dialect: DialectKind,  // Postgres | Mysql | Sqlite
    pub host: Option<String>,
    pub port: Option<u16>,
    pub database: String,
    pub user: Option<String>,
    pub password: Option<String>,  // 支持 {{var}} 引用
    pub path: Option<String>,      // SQLite 专用
    pub ssl_mode: Option<String>,
    pub extra_params: HashMap<String, String>,
}

pub enum DialectKind { Postgres, Mysql, Sqlite }
```

- `ConnectionStore`: 读取/写入 `connections.json`
- `test_connection()`: 尝试连接并返回成功/失败
- 支持 `{{var}}` 在密码等字段中的替换（复用现有 env.json 变量系统）

### 2.2 连接管理 CLI 命令
**修改**: `crates/poste-cli/src/main.rs`
- `poste connection list` — 列出所有连接
- `poste connection test <name>` — 测试连接
- `poste connection add` — 交互式添加（或从 JSON 导入）

### 2.3 连接管理 UI（Lua 端）
**新建**: `lua/poste/sql/connections.lua`
- `:PosteConnection` 命令 → 打开连接选择器（复用 `select.lua` picker）
- 连接列表显示：名称、方言图标、host:port/database
- 选择连接后自动填充当前 SQL 文件的 `@connection` 指令
- 支持操作：
  - `a` — 添加新连接
  - `e` — 编辑连接（打开 JSON 编辑）
  - `d` — 删除连接（确认提示）
  - `t` — 测试连接（显示 ✓/✗ 指示器）
  - `<CR>` — 选择连接并关闭面板

### 2.4 `@connection` 指令增强
**修改**: `crates/poste-core/src/sql_parser.rs`（不改动 `parser.rs`）
- 支持 `@connection` 使用连接名称引用：`-- @connection dev-pg`（从 connections.json 解析）
- 兼容现有 URL 格式：`-- @connection postgres://user:pass@host/db`
- 连接名称优先级：connections.json > URL 直连

### 2.5 上下文切换命令
**新建**: `lua/poste/sql/context.lua`（在 Phase 1 基础上扩展）
- `:PosteSQLContext` — 打开上下文选择器：
  - 第一步：选择 Connection（从 connections.json 列表）
  - 第二步：选择 Database（执行 `list_databases()` 内省查询，展示可用数据库）
  - 选择后更新 `state.sql.context = { connection = "...", database = "..." }`
- `:PosteSQLContext <connection>` — 仅切换连接（不指定 database）
- `:PosteSQLContext <connection> <database>` — 切换连接+数据库

### 2.6 `USE` 语句自动上下文更新
**在 `lua/poste/sql/init.lua` 中处理**：
- 当用户执行 `USE dbname;` 时，Rust 端返回 `is_use_statement: true, database_name: "dbname"`
- Lua 端自动更新 `state.sql.context.database = "dbname"`
- 后续查询自动使用新的 database context
- 在源文件中 `USE` 行添加 Virtual Text 提示：`→ context: myapp_db`

### 2.7 状态栏集成
**修改**: `lua/poste/state.lua`
- `state.sql.context = { connection = nil, database = nil }`
- 状态栏函数返回：`[env: dev] [db: dev-pg/myapp_db]`
- 当仅指定 connection 时：`[env: dev] [db: dev-pg/—]`
- 当完全未指定时：`[env: dev] [db: —]`

### 交付物
- `:PosteConnection` 命令打开连接管理器
- `:PosteSQLContext` 命令打开上下文切换器（connection + database 选择）
- 连接测试功能
- `USE dbname;` 自动更新上下文
- 支持连接名称引用（不必在 SQL 文件中硬编码 URL）
- 状态栏实时显示当前上下文

---

## Phase 3 — 数据库结构浏览（Schema Browser）

> **目标**: 在 Neovim 侧边栏中浏览数据库层级结构

### 3.1 数据库内省查询（Rust 端）
**新建**: `crates/poste-exec/src/sql_introspect.rs`

利用 Phase 1 的 Dialect trait，为每个数据库实现内省 SQL：

**PostgreSQL:**
```sql
-- 数据库列表
SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname;
-- Schema 列表
SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT IN ('pg_catalog', 'information_schema');
-- 表列表（指定 schema）
SELECT table_name, table_type FROM information_schema.tables WHERE table_schema = $1 ORDER BY table_name;
-- 列信息
SELECT column_name, data_type, is_nullable, column_default, character_maximum_length
FROM information_schema.columns WHERE table_schema = $1 AND table_name = $2 ORDER BY ordinal_position;
-- 索引
SELECT indexname, indexdef FROM pg_indexes WHERE schemaname = $1 AND tablename = $2;
-- 约束
SELECT conname, contype, pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid = 'schema.table'::regclass;
```

**MySQL:**
```sql
-- 数据库列表
SHOW DATABASES;
-- 表列表
SHOW TABLES FROM `database`;
-- 列信息
SHOW FULL COLUMNS FROM `database`.`table`;
-- 索引
SHOW INDEX FROM `database`.`table`;
```

**SQLite:**
```sql
-- 表列表
SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;
-- 列信息
PRAGMA table_info('table_name');
-- 索引
PRAGMA index_list('table_name');
```

### 3.2 内省 CLI 命令
**修改**: `crates/poste-cli/src/main.rs`
- `poste introspect <connection> --type databases|schemas|tables|columns|indexes --target <name>`
- 输出 JSON 格式的内省结果

### 3.3 数据库树形浏览器（Lua 端）
**新建**: `lua/poste/sql/db_browser.lua`

树形结构（类似 JetBrains 的 Database 面板）：
```
📦 dev-pg (postgres)
├── 📁 myapp_db
│   ├── 📁 public
│   │   ├── 📋 users (1.2M rows)
│   │   │   ├── 🔑 id (integer, PK)
│   │   │   ├── 📝 name (varchar(255))
│   │   │   ├── 📝 email (varchar(255), UNIQUE)
│   │   │   └── 📅 created_at (timestamp)
│   │   ├── 📋 orders (45K rows)
│   │   │   ├── 🔑 id (integer, PK)
│   │   │   ├── 🔗 user_id (integer, FK → users.id)
│   │   │   └── 📝 status (varchar(50))
│   │   └── 📋 products (890 rows)
│   └── 📁 auth
│       └── 📋 sessions
└── 📁 postgres
```

实现方式：
- 使用 Neovim 的 `nvim_open_win()` 创建侧边栏窗口
- 树形节点使用 fold 机制展开/折叠
- 懒加载：仅展开时查询下一层
- 缓存已加载的节点，支持 `r` 键刷新

### 3.4 浏览器交互键位
- `<CR>` — 展开/折叠节点；叶子节点（表）→ 在 split 中预览数据
- `r` — 刷新当前节点
- `/` — 搜索过滤
- `s` — 在当前 SQL 文件中生成 SELECT 查询
- `d` — 生成 DESCRIBE 查询
- `q` — 关闭浏览器

### 3.5 快速查询生成
从浏览器节点直接生成 SQL 插入到当前文件：
- 表节点 → `-- Query: table_name\nSELECT * FROM table_name LIMIT 100;`
- 列节点 → 带指定列的 SELECT
- 支持自定义模板

### 交付物
- `:PosteDBBrowser` 命令打开侧边栏树形浏览器
- 懒加载的数据库层级浏览
- 从浏览器节点快速生成查询

---

## Phase 4 — 表操作与 DDL

> **目标**: 提供表结构修改、DDL 操作支持

### 4.1 DDL 生成器（Rust 端）
**新建**: `crates/poste-exec/src/sql_ddl.rs`

通过 Dialect trait 生成方言特定的 DDL：
```rust
pub trait DdlGenerator {
    fn create_table(&self, schema: &TableSchema) -> String;
    fn add_column(&self, table: &str, column: &ColumnDef) -> String;
    fn drop_column(&self, table: &str, column: &str) -> String;
    fn rename_column(&self, table: &str, old: &str, new: &str) -> String;
    fn alter_column_type(&self, table: &str, column: &str, new_type: &str) -> String;
    fn add_index(&self, table: &str, columns: &[&str], unique: bool) -> String;
    fn drop_table(&self, table: &str, cascade: bool) -> String;
}
```

### 4.2 表修改 UI（Lua 端）
**新建**: `lua/poste/sql/table_ops.lua`

从 DB Browser 中触发表操作：
- `ma` — 添加列（弹出表单：名称、类型、nullable、default）
- `mr` — 重命名列
- `md` — 删除列（确认提示）
- `mt` — 修改列类型
- 操作生成 DDL SQL 并插入到当前文件，用户审查后手动执行

### 4.3 SQL 补全增强
**新建**: `lua/poste/sql/completion.lua`（独立于 HTTP 的 `lua/poste/completion.lua`）

为 SQL 文件添加上下文感知的补全：
- SQL 关键字（SELECT, FROM, WHERE, JOIN, GROUP BY, ORDER BY, HAVING, INSERT, UPDATE, DELETE, CREATE, ALTER, DROP）
- 当前连接的表名（通过内省查询缓存）
- 表的列名（输入 `table.` 后触发）
- 数据类型（INTEGER, VARCHAR, TEXT, TIMESTAMP, BOOLEAN 等）
- 函数（COUNT, SUM, AVG, MAX, MIN, COALESCE, CAST 等）
- `@connection` 后补全连接名称

### 交付物
- 从 DB Browser 中修改表结构
- SQL 关键字和数据库对象的智能补全
- DDL 操作生成 SQL 供审查执行

---

## Phase 5 — 导入/导出

> **目标**: 支持数据库 dump 和 restore

### 5.1 导出功能
**新建**: `lua/poste/sql/export.lua`（CLI 子命令扩展在 `main.rs` 中）

支持的导出格式：
- **SQL dump**: 调用 `pg_dump` / `mysqldump` / `.dump`（SQLite）
- **CSV**: 将查询结果导出为 CSV
- **JSON**: 将查询结果导出为 JSON

**结果面板中的导出快捷键**:
- `ec` — 导出当前结果为 CSV
- `ej` — 导出当前结果为 JSON
- `es` — 导出当前结果为 SQL INSERT 语句

### 5.2 导入功能
**新建**: `lua/poste/sql/import.lua`

- `:PosteImport <file>` — 导入 SQL 文件到指定连接
- 支持 `.sql`, `.csv`（生成 INSERT 语句）
- 导入前预览（显示前 N 条语句）
- 导入进度显示

### 5.3 结果面板增强 — 分页
**新建**: `lua/poste/sql/pagination.lua`（分页状态管理，不修改 `buffer.lua`）
**修改**: `lua/poste/sql/format.lua`（在表格底部添加分页信息和键位提示）

大数据集分页：
```
┌────┬──────────┬────────────────────────┐
│ id │ name     │ email                  │
├────┼──────────┼────────────────────────┤
│  1 │ Alice    │ alice@example.com      │
│ ...│ ...      │ ...                    │
│ 50 │ Zara     │ zara@example.com       │
└────┴──────────┴────────────────────────┘

Page 1/20 · 50/1000 rows · 12ms · dev-pg
[n] next  [p] prev  [f] first  [l] last  [g] goto page
```

- Rust 端：默认添加 `LIMIT 50 OFFSET 0`，返回总行数
- Lua 端：`n`/`p`/`f`/`l`/`g` 键翻页，重新执行查询并更新 OFFSET
- 在 `state.sql` 命名空间中存储分页状态：`{ page, page_size, total_rows, original_query }`

### 交付物
- 查询结果导出为 CSV/JSON/SQL
- SQL 文件导入功能
- 结果面板分页浏览

---

## Phase 6 — 高级特性

> **目标**: 完善体验，对齐 JetBrains 高级功能 + DataGrip 风格的数据编辑

### 6.1 Dataset 数据编辑（参考 dataset-ui-design.md §3）

**单元格编辑**：
- `i` / `a` / `cc` — 弹出单行浮动输入框（Floating Input），自动继承原值
- `<Esc>` / `<CR>` — 完成编辑，单元格标记为 Modified（黄色高亮）
- `u` — 撤销上一次单元格修改

**行操作**：
- `dd` — 标记当前行为 Deleted（红色删除线高亮，行不消失）
- `o` / `O` — 在下方/上方插入空记录，主键显示 Virtual Text `[Auto]`

**变更追踪与提交**：
- 黄色 = 已修改的单元格
- 红色 = 已删除的行
- 绿色 = 新增的行
- `:W` 或 `<leader>w` — Write：对比差异，自动生成 `UPDATE/INSERT/DELETE` 语句并执行
- `R` 或 `:e!` — Refresh：放弃所有修改，重新拉取数据
- 利用 Vim 原生 Undo Tree 追踪编辑历史

**实现位置**：`lua/poste/sql/buffer.lua`（编辑模式切换）+ 新增 `lua/poste/sql/editor.lua`（差异计算 + DML 生成）

### 6.2 字段过滤与排序（参考 dataset-ui-design.md §4.1）

在表头行上操作：
- `s` — 弹出菜单：Ascending / Descending / Clear Sort
- `f` — 底部命令行：`:PosteSQLFilter [列名] = `，输入过滤条件
- 过滤/排序后重新执行查询并刷新 Dataset

### 6.3 快捷复制 — Yank Matrix（参考 dataset-ui-design.md §4.2）

- `yy` — 复制当前单元格值到 `"` 寄存器
- `<leader>yc` — Yank Column：复制整列所有值，逗号分隔到剪贴板
  - 典型场景：复制一列 ID 拼成 `IN (...)`

### 6.4 关系型跳转 — Go to Definition（参考 dataset-ui-design.md §4.3）

- `gd` — 在外键单元格上，自动解析 FK 关系
- 在下方开新 split，执行 `SELECT * FROM target_table WHERE id = [当前值]`
- FK 信息来源于 Phase 3 的内省查询缓存

### 6.5 查询计划可视化
- 检测 EXPLAIN 前缀，以特殊格式渲染执行计划
- PostgreSQL: `EXPLAIN (ANALYZE, FORMAT JSON)` → 树形渲染
- MySQL: `EXPLAIN FORMAT=JSON` → 树形渲染

### 6.6 多结果集标签页
- 当一个查询块包含多条 SELECT 时，结果面板显示多个标签页
- Winbar 中添加 `Result 1 [1]`, `Result 2 [2]` 标签
- 数字键快速切换

### 6.7 事务支持
- SQL 文件中支持事务块：
```sql
BEGIN;
UPDATE accounts SET balance = balance - 100 WHERE id = 1;
UPDATE accounts SET balance = balance + 100 WHERE id = 2;
COMMIT;
```
- 执行时包裹在事务中，任何失败自动 ROLLBACK
- 结果面板显示事务状态

### 6.8 查询历史
- 保存执行过的查询到 `~/.cache/poste/query_history.json`
- `:PosteHistory` 命令浏览历史
- 支持重新执行、编辑后执行

### 6.9 结果对比
- 保存两次查询结果，支持 diff 对比
- 用于监控数据变化、调试

---

## 文件清单总览

### 新建文件 — Rust（6 个，全部 SQL 独立）
| 文件 | 阶段 | 说明 |
|------|------|------|
| `crates/poste-core/src/sql_parser.rs` | 1 | SQL 专用解析器 |
| `crates/poste-exec/src/sql_executor.rs` | 1 | SQL 执行引擎（PG/MySQL/SQLite） |
| `crates/poste-exec/src/sql_dialect.rs` | 1 | Dialect trait + 3 种实现 |
| `crates/poste-exec/src/sql_connection.rs` | 2 | 连接配置管理 |
| `crates/poste-exec/src/sql_introspect.rs` | 3 | 数据库内省查询 |
| `crates/poste-exec/src/sql_ddl.rs` | 4 | DDL 生成器 |

### 新建文件 — Lua（14 个，全部在 `lua/poste/sql/` 下）
| 文件 | 阶段 | 说明 |
|------|------|------|
| `lua/poste/sql/init.lua` | 1 | SQL 执行入口（对应 HTTP 的 `init.lua`） |
| `lua/poste/sql/buffer.lua` | 1 | Dataset 面板窗口管理（底部水平 split + 单元格导航 + `K` 预览） |
| `lua/poste/sql/format.lua` | 1 | Dataset 表格渲染（conceal 分隔符、Virtual Text NULL） |
| `lua/poste/sql/verbose.lua` | 1 | SQL Verbose 视图格式化 |
| `lua/poste/sql/highlights.lua` | 1 | Dataset extmark 高亮 + 变更追踪着色 |
| `lua/poste/sql/context.lua` | 1,2 | SQL 执行上下文管理（connection → database → USE 处理） |
| `lua/poste/sql/connections.lua` | 2 | 连接管理 UI（CRUD、测试、选择器） |
| `lua/poste/sql/db_browser.lua` | 3 | 数据库树形浏览器 |
| `lua/poste/sql/table_ops.lua` | 4 | 表操作 UI |
| `lua/poste/sql/completion.lua` | 4 | SQL 智能补全 |
| `lua/poste/sql/export.lua` | 5 | 导出功能 |
| `lua/poste/sql/import.lua` | 5 | 导入功能 |
| `lua/poste/sql/pagination.lua` | 5 | 结果分页状态管理 |
| `lua/poste/sql/editor.lua` | 6 | Dataset 数据编辑（差异计算 + DML 生成 + 变更追踪） |

### 新建文件 — VimScript（3 个）
| 文件 | 阶段 | 说明 |
|------|------|------|
| `syntax/poste_sql.vim` | 1 | SQL 文件语法高亮 |
| `syntax/poste_dataset.vim` | 1 | Dataset Buffer 语法（表头、conceal、NULL） |
| `ftplugin/poste_sql.vim` | 1 | SQL filetype 插件 |

### 修改文件（共享层，最小改动）
| 文件 | 阶段 | 改动量 | 说明 |
|------|------|--------|------|
| `Cargo.toml` (workspace + exec) | 1 | ~3 行 | 添加 sqlx 依赖 |
| `crates/poste-core/src/lib.rs` | 1 | 1 行 | 添加 `pub mod sql_parser` |
| `crates/poste-core/src/request.rs` | 1 | 1 行 | Protocol 添加 Sqlite 变体 |
| `crates/poste-core/src/parser.rs` | 1 | ~5 行 | `detect_protocol()` 加 sqlite；`parse_block()` SQL 分发 |
| `crates/poste-exec/src/lib.rs` | 1 | ~3 行 | 添加 `pub mod sql_executor` 等 |
| `crates/poste-exec/src/executor.rs` | 1 | ~5 行 | SQL 分支调用 sql_executor，删除 3 个 stub |
| `lua/poste/init.lua` | 1 | ~5 行 | `run_request()` 开头 filetype 分流 |
| `lua/poste/state.lua` | 1 | ~3 行 | 添加 `M.sql = {}` 命名空间 |
| `ftdetect/poste.vim` | 1 | 2 行 | 添加 `*.sql` / `*.sqlite` filetype 检测 |
| `crates/poste-cli/src/main.rs` | 2,3 | ~20 行 | 新增 connection/introspect 子命令 |

### 不改动的文件（HTTP 专属或通用，完全隔离）
| 文件 | 说明 |
|------|------|
| `lua/poste/format.lua` | HTTP/Redis 格式化 — SQL 有自己的 `sql/format.lua` |
| `lua/poste/highlights.lua` | HTTP/Redis 高亮 — SQL 有自己的 `sql/highlights.lua` |
| `lua/poste/completion.lua` | HTTP 补全 — SQL 有自己的 `sql/completion.lua` |
| `lua/poste/buffer.lua` | HTTP 右侧垂直 split — SQL 有自己的 `sql/buffer.lua`（底部水平 split） |
| `lua/poste/assertions.lua` | HTTP 断言 — SQL 不涉及 |
| `lua/poste/scripts.lua` | HTTP 脚本 — SQL 不涉及 |
| `lua/poste/curl.lua` | HTTP curl 导入 — SQL 不涉及 |
| `lua/poste/copy.lua` | HTTP curl 导出 — SQL 不涉及 |
| `lua/poste/select.lua` | 通用 Picker — SQL 直接复用 |
| `lua/poste/indicators.lua` | 通用 spinner/✓/✘ — SQL 直接复用 |
| `lua/poste/symbols.lua` | 通用符号导航 — SQL 直接复用 |
| `syntax/poste_http.vim` | HTTP 语法高亮 — 完全独立 |

---

## 实施顺序建议

```
Phase 1 (1-2 周)    ← 核心执行引擎，最高优先级
  ├─ Dialect trait
  ├─ PostgreSQL 执行器 (最高优先)
  ├─ MySQL 执行器
  ├─ SQLite 执行器
  ├─ 结果面板表格渲染
  └─ SQL 文件类型支持

Phase 2 (1 周)      ← 连接管理
  ├─ connections.json 存储
  ├─ 连接 CRUD UI
  └─ @connection 名称引用

Phase 3 (1-2 周)    ← 数据库浏览器
  ├─ 内省查询实现
  ├─ 树形浏览器 UI
  └─ 快速查询生成

Phase 4 (1 周)      ← 表操作
  ├─ DDL 生成器
  ├─ 表修改 UI
  └─ SQL 补全

Phase 5 (1 周)      ← 导入/导出
  ├─ CSV/JSON/SQL 导出
  ├─ SQL 导入
  └─ 结果分页

Phase 6 (持续)      ← 高级特性
  ├─ 查询计划
  ├─ 多结果集标签
  ├─ 事务支持
  └─ 查询历史
```

---

## 验证方案

### Phase 1 验证
1. 创建 `examples/test_pg.sql`，使用 `@connection postgres://...` 执行 SELECT → 验证表格结果
2. 执行 INSERT/UPDATE/DELETE → 验证 affected_rows 显示
3. 执行错误 SQL → 验证错误信息显示
4. 执行多条语句 → 验证多结果集
5. 对 MySQL 和 SQLite 重复上述测试

### Phase 2 验证
1. 创建 `connections.json` 并定义连接
2. `:PosteConnection` 选择连接 → 验证自动填充 @connection
3. 测试连接功能 → 验证 ✓/✗ 指示器

### Phase 3 验证
1. `:PosteDBBrowser` → 验证树形结构展示
2. 展开各层级 → 验证懒加载和缓存
3. 从浏览器生成查询 → 验证 SQL 插入

### Phase 4-6 验证
- 各阶段完成后运行对应的集成测试

---

## 开发步骤

> 开发步骤已拆分到 `PROGRESS.md`，包含进度清单、依赖图、AI Agent 快速上手指南和已完成文件清单。
> 本文件保留架构设计、文件隔离策略、JSON 格式规范等参考内容。

