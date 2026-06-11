# P0 设计决策与权衡

> **本文档已于 P0 评审会议后修订**（2026-06-11），随后再次修订以反映 `###` 完全移除的决定。修订原因：
> 1. `###` 已完全从 Poste 文件语法中移除，不再是架构假设
> 2. 当前无真实用户——破坏性变更无代价，可优先选择更干净的设计
>
> 修订详情见 `meeting-minutes.zh.md`。以下决策中 D1、D2、D5、D6 已修正。

在进入 P1-P4 执行之前讨论。

---

## 决策 1：空行边界 — P3 前临时保留，P3 后移除

**当前状态**：Rust `find_statement_token_range()` 将 2+ 连续换行视为语句边界，防止同一文件中视觉分隔的语句之间表的泄漏。

**保留的理由（P3 前）**：
- `###` 移除后、ScopeResolver 完成前，空行边界是防止跨语句表泄漏的**唯一补全层机制**。
- 它在实践中正确工作，没有已知缺陷。

**移除的理由（P3 后）**：
- P3 ScopeResolver 通过理解语句结构（CTE/子查询/别名作用域）替代空行启发式，更准确且无副作用。
- 用户可能无意中用 2+ 空行分隔同一个逻辑语句，空行边界会导致表泄漏。

**决策**：✅ **P3 前临时保留，P3 ScopeResolver 完成后移除。**

---

## 决策 2：`in_string` / `in_comment` 返回行为

**当前状态**：光标在字符串/注释中时，Rust 从 `detect_context()` 返回 `None`。CLI 回退发出 `keyword` + `in_string=true` + `in_comment=true`（两个都 true）。Lua 检查这些标志以抑制项。

**问题**：当 `in_string=true` AND `in_comment=true` 时，Lua 无法区分"在字符串中"、"在注释中"、"Rust 因其他原因返回了 None"。

**选项**：
1. 保持当前行为。接受歧义性。（最简单。）
2. 返回独立的 bool：`in_string` 和 `in_comment` 可以独立地 false。出错时不将两者都设为 true。（调试更好。）
3. 即使光标在字符串/注释中也返回显式上下文，如 `ctx_type: "string"` 或 `ctx_type: "comment"`。

**原先建议**：**选项 2**。修复 CLI 回退：当 Rust 返回 `None` 时，设置 `in_string=false, in_comment=false`，让 Lua 决定。Lua 层的字符串/注释检测足以用于抑制。

**修正**：**选项 3**。P0 评审会议决定升级为选项 3，因为（a）无真实用户，破坏性变更无代价；（b）显式 ctx_type 消除了契约层面的歧义，是更干净的设计。Rust 添加 `ContextType::String` 和 `ContextType::Comment`，Lua 直接检查 ctx_type。

---

## 决策 3：`SchemaTable` 上下文的 `ctx_schema`

**当前状态**：`SchemaTable` 返回 `ctx_schema: null`。模式名在 `ctx_data` 中。

**问题**：`SchemaTable` 的 `ctx_schema` 是否应包含模式名？

| 类型 | ctx_data | ctx_schema（当前） | ctx_schema（提议） |
|------|----------|-------------------|-------------------|
| `dot_column` | `"users"` | `"public"` | `"public"` |
| `schema_table` | `"inventory"` | `null` | `"inventory"` |

**支持**：一致性。Lua 代码可以使用统一的 `ctx_schema` 而不需要检查 `ctx_type`。

**反对**：如果任何 Lua 代码依赖于 `SchemaTable` 的 `ctx_schema` 为 `null`，这是破坏性变更。但抽查显示 Lua `completion.lua` 并没有为 `schema_table` 检查 `ctx_schema`——它直接使用 `ctx_data`。

**建议**：**在 P2 中为 `SchemaTable` 添加 `ctx_schema`**（与 golden fixtures 一起）。Lua `completion.lua` 暂时可以继续使用 `ctx_data`；无需紧急变更。

---

## 决策 4：`version` 字段粒度

**问题**：`version` 应该是单个 int 还是 `{protocol, data}` 结构？

| 方法 | 优点 | 缺点 |
|------|------|------|
| 单个 int `version: 1` | 简单。破坏性变更时递增。 | 粒度粗。 |
| `version: { protocol: 1, data: 1 }` | 粒度细。数据字段演变时无需递增 protocol。 | 增加了复杂性。 |

**建议**：**单个 int**。从 `1` 开始。如果将来需要删除字段，递增到 `2` 并在 Lua 中添加检测旧版本并转换结果的迁移垫片。

---

## 决策 5：Lua `completion_ctx.lua` — 保留还是弃用？

**当前状态**：`completion_ctx.lua` 提供 `detect_context()`（正则启发式回退）、`extract_from_tables()`、`get_tables_and_alias()`。它是许多边界 bug 的来源。

**P1 计划**：降级为仅回退。P1 后 Lua 回退不添加新功能。

**问题**：P4（持久化上下文服务）后是否应该完全弃用？

**移除的优点**：
- 消除所有有缺陷的启发式路径。
- 强制 Rust 处理所有 SQL 上下文。

**移除的缺点**：
- 无二进制环境（如用户使用 `:Lazy` 安装尚未构建 Rust 二进制）。
- 没有 `poste` CLI 就运行 Neovim 的用户。
- "仅 Lua" 调试模式。

**建议**：**标记 `@deprecated` 并存留到 P2 golden 验证通过后，P3 移除。** 由于当前没有真实用户，我们不需要无限期保留降级路径。P1 标记废弃，P2 用 golden fixtures 确认 Rust 处理所有场景，P3 移除。

---

## 决策 6：Rust 是否应了解 `###`？

**当前状态**：`###` 已从 Poste 文件语法中完全移除。SQL 文件不再包含 `###` 行。

**影响**：该决策不再需要讨论。Rust 不需要感知 `###`，因为文件中已不存在 `###`。

---

## 决策 7：测试迁移策略

| 当前测试文件 | P0-P2 计划 |
|-------------|------------|
| `tests/sql_completion_spec.lua` | 保留。作为 UI/缓存/集成测试维护。 |
| `tests/sql_completion_edge_spec.lua` | 拆分为：（a）`legacy_completion=true` 下的 Lua 回退行为测试，（b）删除/更新 Rust 现已正确处理的 `BUG`/`BEFORE FIX` 测试。 |
| `crates/poste-core/src/sql_context/tests.rs` | 保留并扩展。添加 golden fixtures（P2）。 |
| `crates/poste-core/tests/sql_context_golden.rs` | 新建（P2）。Golden fixture 运行器。 |

**问题**：标记 `BUG` 的 Lua 测试应该在 Rust 处理该情况后立即更新，还是等到 P2 golden fixtures？

**建议**：**P1 路由到 Rust 后立即更新。** 如果 Rust 正确处理了该情况，`BUG` 测试将通过 Rust 产生正确输出。如果测试硬编码为 Lua 启发式，它会失败——这是旧行为错误所需的信号。

---

## 决策 8：`@connection` / `@database` — 在 Rust 还是 Lua 中解析？

**当前状态**：两者都处理：
- Lua：`completion.lua` 第 146-196 行（调用 Rust 前的快速路径）
- Rust：`detectors.rs` `try_directive()`（处理 SQL 正文内的标记）

**问题**：双重处理可能产生不一致。

**建议**：**Lua 完全拥有指令。** P1 应该：
1. 在发送给 Rust 前剥离 `-- @` 行（正文已经这样做了，但检查 Rust 分词器中的 `--` 前缀处理）。
2. 从 `detectors.rs` 中移除 `try_directive()`——或作为安全网保留但返回 `None` 而不是 `Connection`。
3. Rust 对其收到的任何 `-- @` 内容应返回 `keyword`（如果 Lua 正确剥离，这应该不存在）。

**但是**：当前的 Lua 实现也处理 `--@connection`（`--` 后没有空格）。Rust 的 `try_directive()` 检查任何位置的 `@connection`/`@database` 标记。同时保留作为双重保险是可接受的。

---

## 决策 9：`prefix` 语义

**当前状态**：`prefix` 是光标位置已输入的部分标识符。

| 输入 | 偏移 | `prefix` |
|------|------|----------|
| `SELECT * FROM au` | 15 | `"au"` |
| `SELECT * FROM ` | 15 | `""` |
| `SEL` | 3 | `"SEL"` |
| `SELECT col`（光标在空格后） | 11 | `""` |

**问题**：`prefix` 是否应为 `dot_column` 包含点字符？

| 输入 | 偏移 | 当前 `prefix` | 提议 |
|------|------|-------------|------|
| `users.us` | 8 | `"us"` | `"us"`（相同——点在光标前） |
| `users.█` | 6 | `""` | `""` |
| `u.na` | 4 | `"na"` | `"na"` |

当前行为正确：`prefix` 是最后一个 `.` 之后的文本（或部分标识符）。`ctx_data` 保存点前的表/别名名。

**建议**：**无需更改。** `prefix` 始终是光标处不间断的 `[a-zA-Z0-9_]` 字符串。点处理是 `ctx_data` 的责任。

---

## 决策 10：函数列表 — 包含标准

**当前状态**：`functions.rs` 返回方言的所有已知函数。该列表用于：
1. 在上下文为 `column` 或 `keyword` 时将函数显示为补全项。
2. 不用于上下文检测（函数不是关键字；它们是 `Ident` 标记）。

**问题**：函数补全是否应完全移到 Lua？

**支持**：简化 Rust。JSON 中的 `functions` 字段只是元数据，不是逻辑。

**反对**：Rust 是方言特定函数的权威来源。保留在 Rust 中可确保正确性并避免漂移。

**建议**：**保留在 Rust 中。** `functions` 字段计算成本低，提供单一真实来源。Lua 的 `SQL_FUNCTIONS` 列表仅在 Rust 不可用时使用，漂移测试（`test_lua_fallback_functions_are_subset`）确保其保持同步。

---

## 总结：P1 优先级行动（修订版，P0 评审后变更）

以下计划在 P0 设计评审会议中修订（详见 `meeting-minutes.zh.md`）。关键变更用 **粗体** 标注：

| # | 行动 | 原方案 | 修订后 | 理由 |
|---|------|--------|--------|------|
| 1 | 在调用 Rust 前剥离 `-- @` 行 | 相同 | 相同 | 指令是 Poste 语法，不是 SQL |
| 2 | 从 Rust detectors 降级 `try_directive()` | 完全移除 | **降级为安全网（返回 None）** | 保留双重保险但是不处理 |
| 3 | 修复 CLI 回退：不要同时设置 `in_string` + `in_comment` | 选项 2 | **选项 3：`ContextType::String/Comment`** | 无用户约束，契约应更干净 |
| 4 | 添加 `version` 字段 | 相同 | 相同 | P0 契约要求 |
| 5 | `statement`/`block` 字段 | Lua 中计算 | 相同（不在 Rust 输出中）| `###` 是 Poste 语法 |
| 6 | 更新标记 `BUG` 的边缘测试 | 相同 | 相同 | P1 路由后立即更新 |
| 7 | 空行边界 `is_blank_line_separator()` | 保留到 P3 再移除 | **P3 后移除** | ScopeResolver 替代空行启发式 |
| 8 | 为 `SchemaTable` 添加 `ctx_schema` | P2 | **P1（与 version 同时）** | 无破坏性，无拖延必要 |
