# 语义级语句边界 — 设计笔记

> **状态**: 未计划。供未来参考的设计笔记。
> **归档**: P4（持久化上下文服务）之后 — 2026-06-11

## 问题

Poste 当前依赖 `;`（分号）进行语句边界判定——完成路径（Rust `find_statement_token_range` / `find_statement_span`）和执行路径（Lua `find_stmt_lines` / `extract_stmt_at_cursor`）都是如此。

这意味着：

1. 像 `SELECT 1\nSELECT 2`（无 `;`）的 SQL 文件会被视为一个语句。
2. 用户必须记得在每个语句末尾加 `;`。
3. DataGrip 等工具不依赖 `;`，通过 SQL 语法识别语句边界。

## 改动范围

### 路径 1：完成（Rust）

**文件**: `crates/poste-core/src/sql_context/statements.rs`, `context.rs`

当前流程：tokenize → 找 `Semi` 标记 → 返回光标前后的语句跨度。

建议流程：tokenize → 识别语句起始关键字（`SELECT`、`INSERT`、`UPDATE`、`DELETE`、`CREATE`、`ALTER`、`DROP`、`WITH`、`SHOW`、`COPY`、`EXPLAIN`、`CALL`、`BEGIN`、`COMMIT`、`ROLLBACK`、`GRANT`、`REVOKE`、`TRUNCATE`、`VACUUM`、`SET`、`USE` 等）→ 基于关键字边界 + 括号深度追踪（`scope.rs` 已有）返回语句跨度，避免子查询误判。

**子查询/CTE 安全**: `scope.rs` 的括号深度追踪已能处理 `SELECT * FROM (SELECT 1)`——内部 `SELECT` 不会被当作新顶层语句。同理 `SELECT id IN (SELECT id FROM t)` 不会在内部 `SELECT` 处断开。

**边缘情况**:
- `WITH` 子句：`WITH cte AS (SELECT ...) SELECT ...` — 一个语句。
- `UNION` / `INTERSECT` / `EXCEPT`：属于同一语句。
- `;` 仍然可作为可选的硬边界用于消歧。
- `BEGIN ... END` 块（PL/pgSQL、存储过程）：复杂，可能需要显式边界。

### 路径 2：执行（Lua）

**文件**: `lua/poste/sql/statement.lua`

当前：`find_stmt_lines()` 扫描 `;` 字符（已知 bug：字符串/注释中的 `;` 导致误切分）。

建议：要么（a）添加 Rust 函数 `find_statement_ranges`，接收原始 SQL 文本，返回 `Vec<(usize, usize)>` 所有语句行范围；要么（b）将关键字边界逻辑移植到 Lua。

**复杂度**：高于路径 1。Lua 当前处理的多语句执行涉及指令提取、语句计数、指示器放置。执行路径还需要处理 `BEGIN ATOMIC ... END`、`CREATE FUNCTION ... $$ ... $$` 等 `;`-free 检测可能难以处理的多行结构。

## 未决关键决策

| 问题 | 选项 |
|------|------|
| `;` 是否应保留为可选的硬边界？ | 是——保留可使消歧在存在 `;` 时变得简单 |
| Rust 完成路径和 Lua 执行路径是否应共享边界逻辑？ | 理想情况下应该——添加一个两者都可调用的 Rust 函数 |
| `CREATE FUNCTION ... AS $$ ... $$`（美元引号正文）怎么处理？ | 美元引号字符串在 tokenizer 中已是单个标记——不应影响边界 |
| `BEGIN` / `COMMIT` / `ROLLBACK` 在事务块中的处理？ | 它们是语句起始关键字，不是块定界符——每个都是独立语句 |

## 与 Scope Resolver（P3）的关系

P3 的 `scope.rs` 引入了 `resolve_scope()`，已了解：
- 括号深度（子查询隔离）
- CTE 注册
- 派生表别名

同样的括号深度追踪对语义边界检测至关重要——它防止内部 `SELECT` 被当作新顶层语句。

## 预估工作量

| 子任务 | 工作量 | 依赖 |
|--------|--------|------|
| 向 Rust tokenizer 添加语句起始关键字列表 | 小 | 无 |
| 用关键字检测替换 `find_statement_token_range` | 中 | 关键字列表、括号深度 |
| 替换 `find_statement_span`（CLI serve `stmt` 方法） | 中 | 同上 |
| 更新语句边界 golden fixtures | 小 | Rust 改动之后 |
| 更新 Lua 执行路径 | 大 | 需要 Rust API 或移植 |

## 测试

- 更新 `statement_boundaries.json` golden fixture（移除 `;` 要求）
- 添加测试用例：`SELECT 1\nSELECT 2`、`WITH cte AS (SELECT 1) SELECT * FROM cte`、子查询不误切分、`;` 可选情况
- 如有改动则添加 Lua 执行路径测试

## 参考

- `crates/poste-core/src/sql_context/statements.rs` — 当前 `find_statement_span`
- `crates/poste-core/src/sql_context/context.rs:170` — `find_statement_token_range`
- `crates/poste-core/src/sql_context/scope.rs` — 子查询隔离的括号深度追踪
- `lua/poste/sql/statement.lua` — `find_stmt_lines`, `extract_stmt_at_cursor`
- `docs/sql/completion/p0/poste-sql-file-syntax.en.md §3` — 当前边界规则
- `docs/sql/completion/p0/poste-sql-file-syntax.en.md §3.6` — 视觉边界指示器（独立于边界计算方式）

## 与视觉边界指示器（§3.6）的关系

视觉边界指示器（extmark 高亮）只调用 `find_statement_span()` 获取 `(start_line, end_line)`，不关心边界如何计算——它只消费结果。

这意味着指示器可以 **现在** 就用 `;` 边界实现，未来语义边界上线后自动受益，无需改动指示器代码。
