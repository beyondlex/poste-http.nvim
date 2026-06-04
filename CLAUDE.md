# CLAUDE.md — Poste 开发指南

## 项目概述

Poste 是一个 **文件驱动、键盘优先、多协议请求执行工具**，由 Rust CLI + Neovim 插件组成。

在纯文本文件（`.http`、`.sql`、`.redis`）中定义请求，通过 Neovim 或 CLI 执行，结果返回到可编辑的 Vim buffer 中——所有 Vim 操作（yank、visual select、search）原生可用。

**核心思想**: Neovim 就是 UI，不需要重新发明编辑器。

## 协议状态

| 协议 | 扩展名 | 状态 | 实现位置 |
|------|--------|------|----------|
| HTTP | `.http` / `.rest` | ✅ 完成 | `executor.rs` (curl 子进程) |
| PostgreSQL | `.sql` | ✅ 完成 | `sql_executor.rs` (sqlx) |
| MySQL | `.mysql` | ✅ 完成 | `sql_executor.rs` (sqlx) |
| SQLite | `.sqlite` | ✅ 完成 | `sql_executor.rs` (sqlx) |
| Redis | `.redis` | ✅ 完成 | `executor.rs` (redis crate) |
| MongoDB | `.mongo` | ❌ Stub | `executor.rs` |
| AMQP | `.amqp` | ❌ Stub | `executor.rs` |

## 项目结构

```
poste/
├── crates/
│   ├── poste-core/              # 纯逻辑，无 I/O
│   │   └── src/
│   │       ├── parser.rs        #   请求文件解析 (### 分块、{{var}} 替换)
│   │       ├── sql_parser.rs    #   SQL 专用解析 (@connection、语句分割、USE 检测)
│   │       ├── request.rs       #   Request/Protocol 类型定义
│   │       └── env.rs           #   env.json 加载
│   │
│   ├── poste-exec/              # 异步 I/O
│   │   └── src/
│   │       ├── executor.rs      #   协议分发 (HTTP/Redis)
│   │       ├── sql_executor.rs  #   PostgreSQL/MySQL/SQLite 执行
│   │       ├── sql_connection.rs#   connections.json 管理、URL 构建
│   │       ├── sql_dialect.rs   #   Dialect trait (PG/MySQL/SQLite 差异封装)
│   │       ├── response.rs      #   Response 结构体
│   │       └── cookie_jar.rs    #   HTTP cookie 持久化
│   │
│   └── poste-cli/               # CLI 二进制
│       └── src/main.rs          #   poste run / poste connection / poste introspect
│
├── lua/poste/                   # Neovim 插件
│   ├── init.lua                 #   主入口: run_request()、keymaps、commands
│   ├── state.lua                #   共享状态 (config, env, sql.context, sql.cell)
│   ├── completion.lua           #   blink.cmp / nvim-cmp 补全源
│   ├── buffer.lua               #   HTTP 响应面板 (右侧垂直 split)
│   ├── format.lua               #   HTTP 响应格式化 (JSON/headers/Redis)
│   ├── highlights.lua           #   高亮组管理
│   ├── sql/                     #   SQL 专用模块 (与 HTTP 完全隔离)
│   │   ├── init.lua             #     SQL 执行入口
│   │   ├── buffer.lua           #     Dataset 面板 (底部水平 split, 单元格导航)
│   │   ├── connections.lua      #     连接管理 UI (:PosteConnection)
│   │   ├── context.lua          #     执行上下文 (@connection → database → USE)
│   │   ├── format.lua           #     Unicode 表格渲染 (┌─┬─┐)
│   │   └── highlights.lua       #     extmark 高亮
│   └── ...                      #   HTTP 相关模块 (assertions, scripts, symbols 等)
│
├── syntax/                      # Vim 语法文件
│   ├── poste_http.vim           #   HTTP 高亮 (19 组)
│   ├── poste_sql.vim            #   SQL 高亮
│   └── poste_dataset.vim        #   Dataset 面板高亮
│
├── docs/                        # 设计文档 (本目录)
│   ├── sql-design.md            #   SQL 架构设计、文件隔离策略、JSON 格式规范
│   ├── dataset-ui-design.md     #   Dataset UI 交互设计 (DataGrip 风格)
│   ├── http-syntax.md           #   HTTP 文件语法参考 + 高亮组列表
│   ├── plugin-install.md        #   插件安装说明
│   └── testing.md               #   插件手动测试指南
│
├── tests/
│   ├── *.lua                    # Lua 单元测试 (plenary.nvim)
│   ├── run.sh                   # 测试运行器
│   └── sql/                     # SQL 集成测试环境 (Docker)
│
├── examples/                    # 示例文件
├── PROGRESS.md                  # SQL 开发进度 (当前活跃)
└── CLAUDE.md                    # 本文件
```

## 构建与测试

```bash
# Rust
cargo build                          # 构建所有 crate
cargo test                           # 运行 Rust 单元测试 (54 tests)
cargo clippy -- -D warnings          # lint 检查
cargo run -- run examples/api.http --line 2 --env dev   # CLI 执行

# Lua
tests/run.sh                         # Neovim 插件测试 (plenary.nvim headless)

# SQL 集成测试 (Docker)
cd tests/sql
docker compose up -d                 # 启动 PostgreSQL + MySQL
docker compose ps                    # 检查状态 (需 healthy)
docker compose down -v               # 清理 (含 volume)
```

详见下方 [SQL 集成测试环境](#sql-集成测试环境)。

## 请求文件格式

### HTTP (.http)

```http
@base_url = https://api.example.com

### Login
POST {{base_url}}/auth/login
Content-Type: application/json

{"email": "user@test.com", "password": "***"}

### Get Profile
GET {{base_url}}/users/me
Authorization: Bearer {{Login.response.body.token}}
```

### SQL (.sql / .mysql / .sqlite)

```sql
-- @connection pg-ecommerce

### Active users
SELECT * FROM users WHERE status = 'active';

### Switch database
USE analytics;

### Recent events
SELECT * FROM events ORDER BY created_at DESC LIMIT 10;
```

### Redis (.redis)

```
# @connection redis://localhost:6379

### Get session
GET session:user:42
```

## 配置文件

### env.json — 环境变量

向上查找最近的 `env.json`（或 `.reqq/env.json`），支持 `{{var}}` 替换：

```json
{
  "dev": {
    "api_base": "http://localhost:8080",
    "db_host": "127.0.0.1",
    "db_port": "5432"
  },
  "prod": {
    "api_base": "https://api.example.com"
  }
}
```

### connections.json — SQL 连接

向上查找最近的 `connections.json`，支持命名连接和 `{{var}}` 替换：

```json
{
  "pg-dev": {
    "dialect": "postgres",
    "host": "localhost",
    "port": 5432,
    "database": "myapp",
    "user": "admin",
    "password": "{{db_pass}}"
  },
  "my-local": {
    "dialect": "mysql",
    "host": "localhost",
    "port": 3306,
    "database": "staging",
    "user": "root",
    "password": "***"
  }
}
```

SQL 文件中用 `-- @connection pg-dev` 引用命名连接，CLI 自动检测协议。

## 代码规范

### Rust

- Edition: 2021
- 错误处理: 应用代码用 `anyhow::Result`，库错误类型用 `thiserror`
- 禁止在非测试代码中 `unwrap()`
- 异步运行时: Tokio
- 依赖在 workspace `Cargo.toml` 统一管理
- 新功能加对应的 `#[cfg(test)]` 单元测试

### Lua

- 遵循 Neovim Lua 惯例 (`vim.api.*`, `vim.fn.*`)
- 模块导出用 `local M = {} ... return M` 模式
- HTTP 和 SQL 功能隔离: `lua/poste/sql/` 下的文件只处理 SQL，不碰 HTTP 逻辑
- 共享状态放 `state.lua`，避免循环依赖

### SQL 文件隔离策略

SQL 模块与 HTTP 模块只在必要的基础设施层共享代码：

- `state.lua` — SQL 状态在 `state.sql` 命名空间下
- `init.lua` — 按 filetype 分流 (`poste_sql` → `sql.run_sql_request()`)
- `executor.rs` — 按 Protocol 枚举分发
- `ftdetect/poste.vim` — 按扩展名设置 filetype

**原则**: HTTP 的修改不影响 SQL，反之亦然。

## SQL 集成测试环境

`tests/sql/` 下有完整的 Docker Compose 测试环境，用于对 PostgreSQL 和 MySQL 进行集成测试。

### 启动

```bash
cd tests/sql
docker compose up -d
docker compose ps        # 等待两个服务都 healthy
```

### 数据库

| 服务 | Host 端口 | 用户/密码 | 数据库 | 表 |
|------|-----------|-----------|--------|-----|
| PostgreSQL 16 | **15432** | `poste` / `poste_test` | `ecommerce` | users, products, orders, order_items |
| PostgreSQL 16 | **15432** | `poste` / `poste_test` | `analytics` | events (JSONB), sessions (UUID/INET), page_views |
| MySQL 8.0 | **13306** | `root` / `poste_test` | `blog` | authors, categories, posts, tags, post_tags, comments |
| MySQL 8.0 | **13306** | `root` / `poste_test` | `inventory` | warehouses, suppliers, items, stock, shipments, shipment_items |

端口使用非标准值（15432、13306）避免与本地数据库冲突。

### 预配置连接

`tests/sql/connections.json` 提供 4 个命名连接：

| 连接名 | 指向 |
|--------|------|
| `pg-ecommerce` | PostgreSQL ecommerce 库 |
| `pg-analytics` | PostgreSQL analytics 库 |
| `my-blog` | MySQL blog 库 |
| `my-inventory` | MySQL inventory 库 |

### 使用 poste 测试

```bash
# CLI 方式
cargo run -- run tests/sql/queries/postgres.sql --line 4 --env dev

# Neovim 方式
# 打开 tests/sql/queries/postgres.sql，光标放在请求上，按 <leader>rr
```

`tests/sql/queries/` 下有预写的测试查询文件，涵盖：
- 多表 JOIN、聚合、子查询
- `USE` 语句切库
- PostgreSQL JSONB 操作 (`payload->>'url'`)
- MySQL `GROUP_CONCAT`、`ENUM` 类型
- `EXPLAIN ANALYZE` 执行计划

### 清理

```bash
cd tests/sql
docker compose down -v   # -v 同时删除数据卷
```

### 自定义测试数据

初始化脚本在 `tests/sql/init/` 下：
- `postgres/01-create-databases.sh` — 创建数据库
- `postgres/02-ecommerce.sql` — ecommerce 库的表和数据
- `postgres/03-analytics.sql` — analytics 库的表和数据
- `mysql/01-blog.sql` — blog 库
- `mysql/02-inventory.sql` — inventory 库

Docker Compose 会在首次启动时自动执行这些脚本。修改后需 `docker compose down -v && docker compose up -d` 重新初始化。

## 当前开发重点

SQL 功能处于 **Phase 3 — 数据库结构浏览**（19/38 步已完成）。

接下来要做的 Step（详见 `PROGRESS.md`）：

| Step | 内容 | 关键文件 |
|------|------|----------|
| 20 | `sql_introspect.rs` — 内省查询 | 新建，参考 `sql_dialect.rs` |
| 21 | CLI `introspect` 子命令 | 改 `main.rs` |
| 22 | `db_browser.lua` — 树形浏览器 | 新建 |
| 23 | 快速查询生成 | db_browser 中 `s` 键插入查询 |

**开发流程**: 读 `PROGRESS.md` 找第一个 `[ ]` Step → 读 `docs/sql-design.md` 了解设计约束 → 实现 → `cargo test` → `[ ]` → `[x]`。

## 关键文件索引

| 想了解什么 | 看哪个文件 |
|-----------|-----------|
| 项目整体架构 | `CLAUDE.md`（本文件） |
| SQL 开发进度 | `PROGRESS.md` |
| SQL 架构设计 | `docs/sql-design.md` |
| Dataset UI 交互 | `docs/dataset-ui-design.md` |
| HTTP 文件语法 | `docs/http-syntax.md` |
| HTTP 执行入口 | `lua/poste/init.lua` → `run_request()` |
| SQL 执行入口 (Lua) | `lua/poste/sql/init.lua` |
| SQL 执行入口 (Rust) | `crates/poste-exec/src/sql_executor.rs` |
| 请求解析器 | `crates/poste-core/src/parser.rs` |
| SQL 解析器 | `crates/poste-core/src/sql_parser.rs` |
| 连接管理 | `crates/poste-exec/src/sql_connection.rs` |
| 数据库方言差异 | `crates/poste-exec/src/sql_dialect.rs` |
| 共享状态 | `lua/poste/state.lua` |
| 响应数据结构 | `crates/poste-exec/src/response.rs` |
| HTTP 响应面板 | `lua/poste/buffer.lua` |
| SQL 结果面板 | `lua/poste/sql/buffer.lua` |
| 补全引擎 | `lua/poste/completion.lua` |
