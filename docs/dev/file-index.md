# Poste 文件索引

> 快速查找关键文件的索引表

---

## Rust 核心

| 功能 | 文件 | 说明 |
|------|------|------|
| HTTP/Redis 解析 | `crates/poste-core/src/parser.rs` | Tokenize、parse_block、变量替换 |
| SQL 解析 | `crates/poste-core/src/sql_parser.rs` | @connection 提取、语句分割 |
| SQL 上下文 | `crates/poste-core/src/sql_context/` | tokenizer、scope resolver、context detect |
| 共享 Request 类型 | `crates/poste-core/src/request.rs` | Protocol 枚举、Request 结构体 |
| HTTP/Redis 执行 | `crates/poste-exec/src/executor.rs` | dispatch → curl 执行 |
| SQL 执行 | `crates/poste-exec/src/sql_executor.rs` | PG/MySQL/SQLite 执行器 |
| 连接管理 | `crates/poste-exec/src/sql_connection.rs` | connections.json 读写、连接测试 |
| Dialect 抽象 | `crates/poste-exec/src/sql_dialect.rs` | Dialect trait + 3 种实现 |
| 内省查询 | `crates/poste-exec/src/sql_introspect.rs` | schema/table/column/index 查询 |
| DDL 生成 | `crates/poste-exec/src/sql_ddl.rs` | DDL 语句生成器 |
| Response 结构 | `crates/poste-exec/src/response.rs` | 统一响应格式 |
| Cookie 管理 | `crates/poste-exec/src/cookie_jar.rs` | Cookie 持久化 |
| CLI 入口 | `crates/poste-cli/src/main.rs` | run/connection/introspect/fmt/context |

---

## Lua 插件

### HTTP 模块 (`lua/poste/`)

| 文件 | 说明 |
|------|------|
| `init.lua` | HTTP 执行入口、filetype 分流 |
| `buffer.lua` | 右侧垂直 split 结果面板 |
| `completion.lua` | HTTP 智能补全 |
| `format.lua` | JSON 格式化 |
| `highlights.lua` | HTTP 语法高亮 |
| `assertions.lua` | Post-request 断言执行 |
| `scripts.lua` | Pre-request 脚本执行 |
| `curl.lua` | curl 命令构建 |
| `copy.lua` | curl 命令导出 |
| `select.lua` | 通用 Picker UI |
| `indicators.lua` | spinner/✓/✘ 指示器 |
| `state.lua` | 共享状态管理 |
| `history.lua` | HTTP 请求历史 UI + 持久化 |

### SQL 模块 (`lua/poste/sql/`)

| 文件 | 说明 |
|------|------|
| `init.lua` | SQL 执行入口（对应 HTTP 的 init.lua） |
| `buffer.lua` | 底部水平 split Dataset 面板 |
| `format.lua` | 表格渲染（conceal、Virtual Text） |
| `highlights.lua` | Dataset extmark 高亮 |
| `verbose.lua` | SQL Verbose 视图格式化 |
| `context.lua` | 执行上下文管理（connection → database） |
| `connections.lua` | 连接管理 UI |
| `db_browser.lua` | 数据库树形浏览器 |
| `completion.lua` | SQL 智能补全 |
| `table_ops.lua` | 表操作 UI |
| `editor.lua` | Dataset 数据编辑 |
| `export.lua` | 导出功能（CSV/JSON/SQL） |
| `import.lua` | 导入功能 |
| `pagination.lua` | 结果分页状态管理 |

---

## VimScript

| 文件 | 说明 |
|------|------|
| `syntax/poste_http.vim` | HTTP 语法高亮 |
| `syntax/poste_sql.vim` | SQL 语法高亮 |
| `syntax/poste_dataset.vim` | Dataset Buffer 语法 |
| `ftdetect/poste.vim` | filetype 检测（.http/.sql/.sqlite） |
| `ftplugin/poste_sql.vim` | SQL filetype 插件 |

---

## 测试

| 类型 | 位置 | 说明 |
|------|------|------|
| Rust 单元测试 | `crates/*/src/*_tests.rs` | 内联测试 |
| Lua 单元测试 | `tests/*.lua` | busted 框架 |
| SQL 集成测试 | `tests/sql/` | Docker Compose (PG + MySQL) |
| HTTP 高亮测试 | `tests/http_highlight_spec.lua` | 语法高亮验证 |
| HTTP 补全测试 | `tests/http_completion_spec.lua` | 补全验证 |
| SQL 补全测试 | `tests/sql_completion_spec.lua` | SQL 补全验证 |

---

## 示例文件

| 类型 | 位置 | 说明 |
|------|------|------|
| HTTP 示例 | `examples/*.http` | HTTP 请求示例 |
| SQL 示例 | `examples/*.sql` | SQL 查询示例 |
| Redis 示例 | `examples/*.redis` | Redis 命令示例 |
| SQL 测试查询 | `tests/sql/queries/` | 集成测试查询 |
| SQL 初始化脚本 | `tests/sql/init/` | Docker 初始化脚本 |

---

## 文档

| 文档 | 说明 |
|------|------|
| [文档中心](README.md) | 完整文档索引 |
| [HTTP 用户文档](../user/http/README.md) | HTTP 用户文档组 |
| [HTTP 开发者文档](./http/README.md) | HTTP 开发者文档组 |
| [HTTP History 设计](./http/http-history.md) | 请求历史 UI 设计 |
| [SQL 用户文档](../user/sql/README.md) | SQL 用户文档组 |
| [SQL 开发者文档](./sql/README.md) | SQL 开发者文档组 |
| [架构概览](./architecture-overview.md) | 整体架构设计 |
| [HTTP 实施指南](./http/tdd-guide.md) | TDD 实施步骤 |
| [HTTP 语法规范](../user/http/syntax.md) | 完整语法定义 |
| [HTTP 快速参考](../user/http/quick-reference.md) | 语法速查表 |
| [HTTP Formatter 设计](./http/format-design.md) | 格式化器架构 |
| [JSON 响应 UX](./http/json-response-ux.md) | JSON 折叠与 jq 探索 |
| [SQL 功能规划](./sql/design.md) | 6 阶段 SQL 规划 |
| [SQL 快速参考](../user/sql/quick-reference.md) | 语法速查表 |
| [SQL Completion P0-P4](./sql/completion/INDEX.md) | 补全系统实施（入口） |
| [SQL Completion P0-P4 原始计划](./sql/completion/README.zh.md) | 补全系统原始计划 |
| [SQL 上下文架构](./sql/context-architecture.md) | Context 检测架构 |
| [Dataset UI 设计](./sql/dataset-ui-design.md) | 结果面板设计 |
| [数据集编辑实现](./sql/dataset-ui-edit-impl.md) | 数据编辑方案 |
| [DB Browser 右键菜单](./sql/db-browser-context-menu.md) | 浏览器交互 |
| [数据导入设计](./sql/data-import-design.md) | CSV/JSON 导入方案 |
| [插件安装](../user/plugin-install.md) | Neovim 插件安装 |
| [测试指南](./testing.md) | 测试方法 |
| [Archived 文档](./archived/README.md) | 过时设计文档存档 |

---

## 配置文件

| 文件 | 说明 |
|------|------|
| `env.json` | 环境变量（{{var}} 替换） |
| `connections.json` | 数据库连接配置 |

---

*文件索引 — 最后更新：2026-06-24*
