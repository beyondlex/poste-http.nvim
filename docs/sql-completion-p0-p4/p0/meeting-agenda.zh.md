# P0 设计评审 — 会议议程

**目标**：在进入 P1-P4 执行前，对齐 Poste SQL 文件语法契约、JSON 上下文契约和实现优先级。

**会前准备**：阅读 `poste-sql-file-syntax.en.md` + `design-decisions.en.md`。

---

## 1. 回顾：为什么需要 P0（5 分钟）

- 当前状态：双重真实源（Lua 启发式 + Rust 上下文）、边界 bug、测试分散
- P0 目标：在添加更多代码之前定义正确性
- 本次会议决定 P1-P4 将实现的规则

## 2. 文件语法契约（15 分钟）

逐节讨论 `poste-sql-file-syntax.en.md`：

| 章节 | 关键问题 |
|------|----------|
| 1. 文件结构 | 文件头 vs 块边界。`.sql`/`.mysql`/`.sqlite` 是否统一？ |
| 2. 指令规则 | `@connection` / `@database` 放置位置和覆盖语义。**决定**：块级 `@connection` 是否重置 `@database`？ |
| 3. 语句边界 | 硬边界（`;`、`###`、EOF）vs 软边界（空行）。**决定**：单个空行是否为边界？ |
| 8. 开放问题 | 5 个需讨论的问题 |

### 必须决定：
- [ ] **Q3.1**：在 P1 移除 `is_blank_line_separator()` 还是保留到 P3？
- [ ] **Q3.5**：单个空行是否为补全的软边界？（当前：否，需要 2+）

## 3. JSON 上下文契约（10 分钟）

| 章节 | 关键问题 |
|------|----------|
| 4.2 新增字段 | `version`、`statement`、`block`——现在添加哪些，哪些稍后添加？ |
| 8. 开放 Q2 | `statement` 在 Rust 还是 Lua 中计算？ |
| 8. 开放 Q3 | `block` 在 Rust 还是 Lua 中计算？ |

### 必须决定：
- [ ] **Q4.1**：`version` 字段——单个 int 还是 `{protocol, data}`？
- [ ] **Q4.2**：`version` 在 P1 还是 P2 添加？
- [ ] **Q4.3**：`statement`/`block` 字段——现在添加 JSON 字段（在 Lua 中计算）还是推迟？

## 4. 需要关闭的设计决策（20 分钟）

逐条讨论 `design-decisions.en.md`：

| # | 决策 | 选项 | **决定** |
|---|------|------|:-------:|
| D1 | 空行边界 | 保留到 P3 / P1 移除 | |
| D2 | `in_string`/`in_comment` 歧义 | 保持现状 / 选项 2 / 选项 3 | |
| D3 | `SchemaTable` 的 `ctx_schema` | P2 添加 / 保持现状 | |
| D4 | `version` 粒度 | 单个 int / `{protocol, data}` | |
| D5 | Lua `completion_ctx.lua` 未来 | 无限期保留 / P4 后弃用 | |
| D6 | Rust 了解 `###`？ | 否 / 是（未来 LSP） | |
| D7 | `BUG` 测试更新时间 | P1 立即 / 等到 P2 | |
| D8 | 指令归属 | Lua 拥有 / 两者都保留 | |
| D9 | `prefix` 语义 | 不变 / 包含点 | |
| D10 | 函数在 Rust 还是 Lua | 保留在 Rust / 移到 Lua | |

## 5. P1 优先级确认（10 分钟）

| 行动 | 负责人 | 工作量 |
|------|--------|--------|
| 调用 Rust 前剥离 `-- @` 行 | Rust | 小 |
| 从 Rust detectors 移除 `try_directive()` | Rust | 小 |
| 修复 CLI 回退的 `in_string`/`in_comment` | Rust | 小 |
| 添加 `version` 字段 | Rust | 极小 |
| Lua 中计算 `statement`/`block` | Lua | 中 |
| 更新标记 `BUG` 的边缘测试 | Lua | 中 |
| 路由包装器 `detect_context_for_completion()` | Lua | 中 |
| 旧版开关语义 | Lua | 小 |

## 6. 后续行动与下一步（5 分钟）

- [ ] 确认 P0 文档定稿（本次会议的任何修订）
- [ ] 分配 P1 实现负责人
- [ ] 设定 P1 目标日期
- [ ] 安排 P1 评审
- [ ] 决定：在 P2 开始前进行 golden fixture 格式评审？

---

## 时间预算

| 项目 | 时间 |
|------|------|
| 1. 回顾 | 5 分钟 |
| 2. 语法契约 | 15 分钟 |
| 3. JSON 契约 | 10 分钟 |
| 4. 设计决策 | 20 分钟 |
| 5. P1 优先级 | 10 分钟 |
| 6. 后续行动 | 5 分钟 |
| **总计** | **65 分钟** |
