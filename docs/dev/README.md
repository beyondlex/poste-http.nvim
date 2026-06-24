# 开发者文档

> 架构、实施指南、设计文档

---

## 通用

| 文档 | 说明 |
|------|------|
| [架构概览](./architecture-overview.md) | 整体架构设计 |
| [文件索引](./file-index.md) | 关键文件速查 |
| [测试指南](./testing.md) | Rust + Lua + Docker SQL 测试 |
| [Debug 报告](./debug/README.md) | Bug 根因分析索引 |
| [Archived 文档](./archived/README.md) | 过时设计文档存档 |

## HTTP 开发者

| 文档 | 说明 |
|------|------|
| [TDD 指南](./http/tdd-guide.md) | HTTP TDD 工作流和测试模式 |
| [Formatter 设计](./http/format-design.md) | `poste fmt` 架构 |
| [JSON 响应 UX](./http/json-response-ux.md) | JSON 折叠与 jq 探索 |

## SQL 开发者

| 文档 | 说明 |
|------|------|
| [SQL 功能设计](./sql/design.md) | **入口** — 6 阶段规划 |
| [SQL Completion](./sql/completion/INDEX.md) | 补全系统实施（P0-P4 ✅） |
| [上下文架构](./sql/context-architecture.md) | Context 检测设计 |
| [Dataset UI 设计](./sql/dataset-ui-design.md) | 结果面板交互 |
| [数据集编辑实现](./sql/dataset-ui-edit-impl.md) | 数据编辑方案 |
| [DB Browser 右键菜单](./sql/db-browser-context-menu.md) | 浏览器交互 |
| [数据导入设计](./sql/data-import-design.md) | CSV/JSON 导入方案 |

## 文档引用关系

### HTTP 文档链

```
http/tdd-guide.md (TDD 工作流)
    ├── 引用 → ../user/http/syntax.md (语法规范)
    └── 引用 → http/format-design.md (Formatter 设计)
```

### SQL 文档链

```
sql/design.md (入口)
    ├── 引用 → sql/dataset-ui-design.md (结果面板)
    ├── 引用 → sql/dataset-ui-edit-impl.md (数据编辑)
    ├── 引用 → sql/db-browser-context-menu.md (右键菜单)
    ├── 引用 → sql/completion/INDEX.md (补全系统)
    └── 引用 → sql/data-import-design.md (数据导入)
```

## 构建

```bash
cargo build          # 编译 CLI
cargo test           # 运行 Rust 测试
tests/run.sh         # 运行 Lua 测试
```

### SQL 集成测试

```bash
cd tests/sql && docker compose up -d   # PG 16 + MySQL 8.0
cargo run -- run tests/sql/queries/postgres.sql --line 4 --env dev
```

---

## 文档维护约定

- 新增功能时，在 `dev/` 对应协议目录下创建设计文档
- 用户语法参考放在 `user/` 对应协议目录下
- 保持文档间的交叉引用更新
- 中文文档优先，英文文档作为补充

---

*开发者文档组*