# Poste 文档中心

> **Poste** — 文件驱动、键盘优先的多协议请求执行器（Rust CLI + Neovim 插件）
>
> `.http` / `.sql` / `.redis` → 执行 → 结果在可编辑的 Vim 缓冲区中展示

---

选择入口：

- [👤 用户文档](./user/) — 安装、语法参考、快速开始
- [🔧 开发者文档](./dev/) — 架构、实施指南、设计文档

---

### 协议支持状态

| 协议 | 扩展名 | 状态 |
|------|--------|------|
| HTTP | `.http` / `.rest` | ✅ 完整 |
| PostgreSQL / MySQL / SQLite | `.sql` / `.mysql` / `.sqlite` | ✅ 核心完成 |
| Redis | `.redis` | ✅ 完整 |
| MongoDB | `.mongo` | ❌ Stub |
| AMQP | `.amqp` | ❌ Stub |