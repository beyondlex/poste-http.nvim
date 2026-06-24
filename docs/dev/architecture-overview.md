# Poste 架构概览

> 多协议请求执行器的整体架构设计

---

## 核心设计原则

1. **协议隔离** — HTTP 和 SQL 在实现层完全隔离，只在基础设施层共享
2. **文件驱动** — 所有请求都来自 `.http` / `.sql` / `.redis` 文件
3. **键盘优先** — Neovim 插件以键盘操作为核心交互方式
4. **Rust + Lua** — Rust 负责核心逻辑（解析、执行），Lua 负责 UI（补全、渲染）

---

## 分层架构

```
┌─────────────────────────────────────────────────────────────┐
│                      Neovim 插件层 (Lua)                    │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
│  │  lua/poste/ │  │ lua/poste/  │  │   lua/poste/sql/    │  │
│  │  (HTTP)     │  │  (通用 UI)  │  │    (SQL 专属)       │  │
│  │             │  │             │  │                     │  │
│  │ init.lua    │  │ select.lua  │  │ init.lua            │  │
│  │ buffer.lua  │  │ indicators  │  │ buffer.lua          │  │
│  │ completion  │  │ symbols     │  │ format.lua          │  │
│  │ format.lua  │  │             │  │ highlights.lua      │  │
│  │ highlights  │  │             │  │ context.lua         │  │
│  │ assertions  │  │             │  │ connections.lua     │  │
│  │ scripts     │  │             │  │ db_browser.lua      │  │
│  │ curl.lua    │  │             │  │ completion.lua      │  │
│  │ copy.lua    │  │             │  │ editor.lua          │  │
│  │             │  │             │  │ export/import       │  │
│  │             │  │             │  │ pagination.lua      │  │
│  └─────────────┘  └─────────────┘  └─────────────────────┘  │
│                          ↓                                  │
│              init.lua: filetype 分流                        │
│              poste_sql → sql.init.run_sql_request()         │
│              poste_http → 原有 HTTP 流程                    │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│                    Rust CLI (poste)                         │
│  ┌───────────────────────────────────────────────────────┐  │
│  │ crates/poste-cli/                                     │  │
│  │   main.rs: run / conn/ introspect / fmt / context     │  │
│  └───────────────────────────────────────────────────────┘  │
│                          ↓                                  │
│  ┌─────────────────┐  ┌─────────────────────────────────┐   │
│  │ crates/poste-   │  │ crates/poste-exec/              │   │
│  │ exec/           │  │                                 │   │
│  │                 │  │ executor.rs (HTTP/Redis)        │   │
│  │ executor.rs     │  │ sql_executor.rs(PG/MySQL/SQLite)│   │
│  │ sql_executor.rs │  │ sql_connection.rs               │   │
│  │ sql_connection  │  │ sql_dialect.rs                  │   │
│  │ sql_dialect.rs  │  │ sql_introspect.rs               │   │
│  │ response.rs     │  │ sql_ddl.rs                      │   │
│  │ cookie_jar.rs   │  │ response.rs                     │   │
│  │                 │  │ cookie_jar.rs                   │   │
│  └─────────────────┘  └─────────────────────────────────┘   │
│                          ↓                                  │
│  ┌───────────────────────────────────────────────────────┐  │
│  │ crates/poste-core/                                    │  │
│  │   parser.rs (HTTP/Redis 解析)                         │  │
│  │   sql_parser.rs (SQL 解析)                            │  │
│  │   sql_context/ (SQL 补全上下文)                       │  │
│  │   request.rs (共享 Request 类型)                      │  │
│  │   lib.rs                                              │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│                    基础设施层                               │
│  env.json          — 环境变量（{{var}} 替换）               │
│  connections.json  — 数据库连接配置                         │
│  ~/.cache/poste/   — 缓存（查询历史、元数据等）             │
└─────────────────────────────────────────────────────────────┘
```

---

## 协议实现对比

| 维度 | HTTP | SQL |
|------|------|-----|
| 文件扩展名 | `.http`, `.rest` | `.sql`, `.mysql`, `.sqlite` |
| 解析器 | `parser.rs` | `sql_parser.rs` |
| 执行器 | `executor.rs` (curl) | `sql_executor.rs` (sqlx) |
| 结果面板 | 右侧垂直 split | 底部水平 split |
| 导航模式 | 普通文本光标 | 单元格 (Cell) 导航 |
| 补全 | `completion.lua` | `sql/completion.lua` |
| 语法高亮 | `syntax/poste_http.vim` | `syntax/poste_sql.vim` |
| 格式化 | `poste fmt` (计划中) | 暂不需要 |

---

## 共享与隔离

### 共享文件（基础设施层）

| 文件 | 用途 |
|------|------|
| `crates/poste-core/src/request.rs` | 共享 Request 类型、Protocol 枚举 |
| `crates/poste-core/src/parser.rs` | 共享 `substitute_vars()` 变量替换 |
| `crates/poste-core/src/lib.rs` | 模块导出 |
| `lua/poste/state.lua` | 共享状态（env、当前连接等） |
| `lua/poste/select.lua` | 通用 Picker UI |
| `lua/poste/indicators.lua` | 通用 spinner/✓/✘ |
| `ftdetect/poste.vim` | filetype 检测 |

### 隔离文件（协议专属）

| HTTP 专属 | SQL 专属 |
|-----------|----------|
| `lua/poste/init.lua` | `lua/poste/sql/init.lua` |
| `lua/poste/buffer.lua` | `lua/poste/sql/buffer.lua` |
| `lua/poste/format.lua` | `lua/poste/sql/format.lua` |
| `lua/poste/completion.lua` | `lua/poste/sql/completion.lua` |
| `lua/poste/highlights.lua` | `lua/poste/sql/highlights.lua` |
| `lua/poste/assertions.lua` | `lua/poste/sql/context.lua` |
| `lua/poste/scripts.lua` | `lua/poste/sql/connections.lua` |
| `lua/poste/curl.lua` | `lua/poste/sql/db_browser.lua` |
| `syntax/poste_http.vim` | `syntax/poste_sql.vim` |
| | `syntax/poste_dataset.vim` |

---

## 关键分流点

### Lua 端分流

`lua/poste/init.lua` 的 `run_request()` 函数：

```lua
function M.run_request()
  local ft = vim.bo.filetype
  if ft == "poste_sql" or ft == "poste_sqlite" then
    require("poste.sql.init").run_sql_request()
    return
  end
  -- 原有 HTTP/Redis 流程完全不变
end
```

### Rust 端分流

`crates/poste-exec/src/executor.rs` 的 dispatch：

```rust
match request.protocol {
    Protocol::Http | Protocol::Redis => executor::execute_http(request).await,
    Protocol::Postgres => sql_executor::execute_postgres(request).await,
    Protocol::Mysql => sql_executor::execute_mysql(request).await,
    Protocol::Sqlite => sql_executor::execute_sqlite(request).await,
}
```

---

## 数据流

### HTTP 请求流程

```
.http 文件
  → parser.rs 解析 → Request 结构体
  → executor.rs 执行 → curl 调用
  → Response JSON
  → buffer.lua 渲染 → 右侧垂直 split
```

### SQL 请求流程

```
.sql 文件
  → sql_parser.rs 解析 → Request + 上下文
  → sql_executor.rs 执行 → sqlx 查询
  → Response JSON (结构化结果集)
  → sql/buffer.lua 渲染 → 底部水平 split (Dataset)
```

---

## 依赖关系

```
poste-cli ──→ poste-exec ──→ poste-core
                │
                ├── sqlx (PG/MySQL/SQLite)
                ├── curl-rust (HTTP)
                └── redis-rs (Redis)

lua/poste ──→ Rust CLI (通过 system/jobstart)
```

---

## 测试策略

| 层级 | 工具 | 位置 |
|------|------|------|
| Rust 单元测试 | `#[cfg(test)]` | `crates/*/src/*_tests.rs` |
| Rust 集成测试 | `cargo test` | `crates/*/tests/` |
| Lua 单元测试 | busted (`tests/run.sh`) | `tests/*.lua` |
| SQL 集成测试 | Docker Compose | `tests/sql/` |

---

## 相关文档

- [HTTP 协议文档](./http/README.md)
- [SQL 协议文档](./sql/README.md)
- [HTTP 实施指南](./http/impl-guide.md)
- [SQL 功能完整规划](./sql/design.md)
- [插件安装](./plugin-install.md)
- [测试指南](./testing.md)

---

*架构概览 — 最后更新：2026-06-24*
