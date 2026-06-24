# Poste SQL 文件语法与上下文契约

## 1. 文件结构

Poste SQL 文件（`.sql`、`.mysql`、`.sqlite`）由指令和 SQL 语句组成，语句之间以 `;` 分隔。指令可在文件顶部或语句间任意位置出现：

```
-- @connection my-pg                   ← 文件级指令（可选）
-- @database blog                      ← 文件级指令（可选）

SELECT * FROM users WHERE id = 1;

-- @connection my-analytics            ← 内联指令（切换连接，后续语句生效）
SELECT COUNT(*) FROM events;
SELECT * FROM page_views;             ← 仍使用 my-analytics
```

### 1.1 指令位置与作用域

- **文件级**：文件顶部（第一条 SQL 语句之前），对文件中所有语句生效。
- **内联**：两条 SQL 语句之间，从该位置开始切换连接/数据库，覆盖文件级设置，对后续语句持续生效直到下一个同类型指令或文件末尾。

### 1.2 扩展名语义

| 扩展名 | 方言 | 行为 |
|--------|------|------|
| `.sql` | Postgres（默认） | 相同块规则。从连接 URL 自动检测。 |
| `.mysql` | MySQL | 相同块规则。 |
| `.sqlite` | SQLite | 相同块规则。 |

方言仅影响：
- SQL 上下文检测（关键字/函数集、`|` 操作符等）
- 元数据内省（表/列查询）
- 不影响 Poste 文件结构。

---

## 2. 指令规则

### 2.1 支持的指令

| 指令 | 值 | 用途 |
|------|-----|------|
| `-- @connection <name-or-url>` | 连接名或 URL | 选择数据库连接 |
| `-- @database <name>` | 数据库/模式名 | 覆盖默认数据库 |

### 2.2 放置位置

指令可出现在两个位置：
- **文件顶部**（第一条 SQL 语句之前）—— 文件级默认值。
- **SQL 语句之间**（内联）—— 从该行后切换连接/数据库，覆盖文件级设置，对后续语句持续生效。
- 后续同类型指令再次覆盖（后出现者优先）。

### 2.3 指令行的补全

| 光标位置 | 补全项 |
|----------|--------|
| `-- @connection ` 之后 | 连接名（来自 `connections.json`） |
| `-- @database ` 之后 | 数据库/模式名（来自 `introspect databases`） |
| `-- @` 部分输入 | `@connection`、`@database` 指令名 |

### 2.4 指令行与 SQL 的隔离

- 指令行**排除**在 SQL 语句解析之外。
- 光标在指令行上**不得**触发 SQL 关键字/表/列补全。
- **补全管道**：Lua 在调用 Rust 前剥离所有指令行，将文件完整 SQL 正文传给 Rust。Rust 层的 `try_directive()` 安全网保留，但遇到 `@connection`/`@database` 标记时返回 `None`（不处理）。
- **执行管道**：Lua 解析文件时维护当前有效连接/数据库状态。按 `;` 边界提取待执行语句时，取光标所在位置的前向最近有效指令。

### 2.5 没有 `-- @database` 的 `-- @connection`

当 `-- @connection` 后没有 `-- @database` 时，`@database` 的补全会回退到显示连接名，带有一个特殊插入行为（同时插入 `@connection` 和 `@database` 行）。这是 UI 便利功能，不是语法规则。

---

## 3. 语句边界

### 3.1 硬边界（始终分割）

| 边界 | 标记 | 说明 |
|------|------|------|
| 分号 | `;` | 分词器感知：跳过 `'字符串'`、`-- 注释`、`/* 块 */`、`$$ 美元字符串 $$` 内的 `;` |
| EOF | — | 结束当前语句 |

### 3.2 软边界（仅补全，P3 后移除）

| 边界 | 标记 | 行为 |
|------|------|------|
| 连续空行 | `\n\n`（2+ 换行符） | P3 前：Rust `context.rs` 使用 `is_blank_line_separator()` 分割标记范围，防止空行之后的表泄漏到光标之前。P3 ScopeResolver 完成后移除。 |

### 3.3 理由

- 2+ 连续空行作为边界是临时防护，用于 ScopeResolver 完成前防止跨语句表泄漏。
- 单个空行**不是**边界（用户可能在语句内使用空行提高可读性）。
- **执行语句提取**始终只使用 `;`，不受此影响。

### 3.4 当前实现（P3 前临时）

| 层 | 边界检测 | 说明 |
|----|----------|------|
| Rust `context.rs` | 分号 + 2+ 空行 | `find_statement_token_range()`，P3 后移除空行逻辑 |
| Rust `statements.rs` | 仅分号 | `find_statement_span()`（用于执行） |
| Lua `completion.lua` | 剥离所有指令行 | 将文件完整 SQL 正文传给 Rust |
| Lua `statement.lua` | 仅分号 | `extract_stmt_at_cursor()`（执行层） |

### 3.5 结论

- 2+ 空行边界是 **P3 前的临时防护**，P3 ScopeResolver 完成后移除。
- P3 后补全层**只依赖** `;` + EOF，由 ScopeResolver 处理语句内作用域（CTE/子查询/别名），不再使用启发式空行分割。

### 3.6 视觉边界指示器（建议 UI 特性）

`;` 边界对用户不可见，可能产生"我以为会执行这两行"的认知偏差。建议在 Neovim 插件层添加实时语句高亮：

- `CursorMoved` 时调用 `find_statement_span()` 获取光标处语句的 `(start_line, end_line)`。
- 用 `vim.api.nvim_buf_set_extmark()` 在该范围内绘制背景色或行号标记。
- 效果：光标移动到某条 SQL 语句时，该语句区域视觉高亮，用户清晰感知执行边界。
- 这取代了 `###` 曾提供的视觉分组功能，且更精确（基于真实 `;` 边界而非手动分隔）。
- **与语义边界检测的关系**（见 `future/semantic-statement-boundary.zh.md`）：指示器只调用 `find_statement_span()` 消费结果，不关心边界如何计算。未来实现 `;`-free 语义边界后，指示器自动受益，无需改动。

---

## 4. 光标上下文 JSON 契约

### 4.1 当前字段（稳定，不会删除）

```json
{
  "ctx_type": "column",
  "ctx_data": null,
  "ctx_schema": null,
  "prefix": "us",
  "tables": [{ "name": "users", "alias": null, "schema": null }],
  "functions": ["COUNT", "SUM", "MAX", "MIN", ...],
  "in_string": false,
  "in_comment": false
}
```

| 字段 | 类型 | 始终存在 | 描述 |
|------|------|----------|------|
| `ctx_type` | string | 是 | 取值：`keyword`、`table`、`column`、`dot_column`、`schema_table`、`insert_column`、`connection`、`database`、`datatype`、`string`、`comment` |
| `ctx_data` | string\|null | 是 | 上下文相关数据（如 `dot_column` 的表名、`schema_table` 的模式名） |
| `ctx_schema` | string\|null | 是 | `dot_column` 的模式 |
| `prefix` | string | 是 | 已输入的部分标识符 |
| `tables` | array | 是 | 光标位置可见的表 |
| `functions` | array | 是 | 当前方言的已知函数 |
| `in_string` | bool | 是 | 光标在字符串字面量内 |
| `in_comment` | bool | 是 | 光标在行/块注释内 |

### 4.2 新增字段（P0 契约，添加到 Rust 输出）

```json
{
  "version": 1
}
```

| 字段 | 类型 | 默认值 | 描述 |
|------|------|--------|------|
| `version` | int | 1 | 协议版本。破坏性变更时递增。 |

> **`statement`/`block` 字段不在 Rust 输出中**。这两个字段是执行层信息：
> - `statement`：由 Lua 层从 `poste context stmt` 计算（需要时）
> - `block`：`###` 已被移除，不在 Rust 输出中

### 4.3 Null/NIL 处理

- JSON `null` → `vim.NIL` → 在 Lua 中规范化为 `nil`（已在 `completion.lua:deep_clean()` 中处理）。
- 空 prefix：`""`。
- 空 tables：`[]`。

### 4.4 版本策略

- `version` 字段始终存在。
- 向后兼容的添加（新字段）：递增次要版本？当前建议：保持在 `1`，直到出现破坏性变更。
- 破坏性变更（删除字段、类型变更）：递增到 `2`，在 Lua 中添加迁移路径。
- **Rust 不会删除现有字段。** 可能会新增字段（如 `SchemaTable` 的 `ctx_schema`）。

---

## 5. 上下文类型语义

### 5.1 类型定义

| `ctx_type` | `ctx_data` | `ctx_schema` | 触发时机 | 补全项 |
|------------|-----------|--------------|----------|--------|
| `keyword` | `null` | 忽略 | 默认 / 无特定上下文匹配 | SQL 关键字、函数、数据类型 |
| `table` | `null` | 忽略 | `FROM`、`JOIN`、`INTO`、`UPDATE`、`TABLE`、`DELETE FROM`、`SHOW TABLES`、`COPY`、`ANALYZE`、`VACUUM`、`CALL`、`GRANT ... ON`、`REVOKE ... ON`、`FOR UPDATE OF`、`FOR SHARE OF` 之后 | 表、视图、数据库/模式 |
| `column` | `null` | 忽略 | `WHERE`、`SET`、`ON`、`HAVING`、`SELECT`、`ORDER BY`、`GROUP BY`、`RETURNING`、`DISTINCT`、`NOT`、SELECT 列表中逗号后、WHERE 中 `AND`/`OR`、函数 `(` 后、WHERE 中 `(` 后、`ON CONFLICT DO UPDATE SET`、窗口 `PARTITION BY`/`ORDER BY`、`INSERT INTO ... SELECT`、`MODIFY COLUMN` | 可见表的列、函数 |
| `dot_column` | `table_name`（string） | `schema_name` 或 `null` | `alias.` 或 `table.` 之后（`users.`、`u.`） | 指定表或别名的列 |
| `schema_table` | `schema_name`（string） | `null` | `FROM schema.` 或 `JOIN schema.` 之后 | 该模式内的表 |
| `insert_column` | `table_name`（string） | 忽略 | `INSERT INTO table (` 内 | 目标表的列（含快速插入全部列/不带 ID 的快捷操作） |
| `connection` | `null` | 忽略 | `-- @connection` 之后 | 连接名 |
| `database` | `null` 或 `"directive"` | 忽略 | `-- @database` 或 `USE` 之后 | 数据库/模式名 |
| `datatype` | `null` | 忽略 | `ALTER TABLE ... ADD/MODIFY COLUMN col_name` 之后 | 数据类型（INT、VARCHAR、TEXT 等） |
| `string` | `null` | 忽略 | 光标在字符串字面量内（`'hello'`） | 不提供补全。Lua 层抑制所有项。 |
| `comment` | `null` | 忽略 | 光标在注释内（`-- line` 或 `/* block */`） | 不提供补全。Lua 层抑制所有项。 |

### 5.2 边界情况

| 输入 | 期望上下文 | 理由 |
|------|-----------|------|
| `SELECT *`（光标在 `*` 后的空格上） | `keyword` | 需要 FROM 才能得到表；建议关键字 |
| `SELECT col`（光标在 `col` 后的空格上） | `keyword` | 列表达式完成；建议 FROM/WHERE |
| `WHERE col =`（光标在 `=` 后） | `keyword` | 值表达式；不建议列名 |
| `WHERE col >`（光标在 `>` 后） | `keyword` | 同 `=` |
| `WHERE col BETWEEN` | `keyword` | 期望 Between 值，不是列 |
| `WHERE col LIKE` | `keyword` | 期望模式，不是列 |
| `WHERE col IS` | `keyword` | 期望 NULL/TRUE/FALSE，不是列 |
| `WHERE col NOT` | `keyword` | 期望 IN/LIKE/BETWEEN，不是列 |
| `WHERE col IN` | `keyword` | 期望 `(` 或值列表 |
| `WHERE col IN (` | `keyword` | 子查询或值列表 |
| `WHERE id BETWEEN 1 AND` | `column` | AND 在 BETWEEN 后恢复列上下文 |
| `WHERE status IS NOT` | `column` | IS NOT 后应跟列 |
| `SELECT FROM (` | `keyword` | 子查询开始，不是表 |
| `WHERE id IN (` | `keyword` | IN 子查询开始 |
| `WHERE EXISTS (` | `keyword` | EXISTS 子查询开始 |
| `INSERT INTO tbl VALUES (` | `keyword` | 值列表，不是列名 |
| `INSERT INTO tbl (` | `insert_column` | INSERT 的列列表 |
| `INSERT INTO tbl`（光标在 `(`） | `insert_column` | 左括号触发插入列模式 |
| `SELECT RANK() OVER` | `keyword` | 窗口函数期望 BY、PARTITION BY 等 |
| `SET statement_timeout =` | `keyword` | SET 语句（非 UPDATE）不应建议列 |
| `UPDATE SET col =` | `column` | 可接受 keyword |
| 光标在字符串 `'hello'` 内 | `ctx_type: "string"`, `in_string=true`, 不提供补全 | 显式返回字符串类型，Lua 抑制所有项 |
| 光标在 `-- comment` 内 | `ctx_type: "comment"`, `in_comment=true`, 不提供补全 | 显式返回注释类型，Lua 抑制所有项 |
| 空缓冲区 | `keyword`，空 `tables`，空 `prefix` | 默认回退 |

### 5.3 需要更新的旧测试标记

`tests/sql_completion_edge_spec.lua` 中以下测试编码了与当前契约矛盾的 CURRENT 行为。将在 P1/P2 中更新：

| 测试 | 标记 | 问题 |
|------|------|------|
| "BUG: schema.table extracts only the schema name" | `BUG` | Lua 回退限制；Rust 正确处理 |
| "BUG: tables from subquery-FROM leak to outer scope" | `BUG` | Lua 回退限制；Rust 的括号追踪处理了此情况 |
| "BUG: CTE inner tables leak" | `BUG` | Lua 回退限制；Rust 应处理（P3） |
| "BUG: -- FROM → table context" | `BUG` | Lua 缺少注释感知；Rust 返回 `None` |
| "BUG: string 'WHERE ' at end triggers column context" | `BUG` | Lua 缺少字符串感知；Rust 返回 `None` |
| "CURRENT: WHERE col = → keyword" | `CURRENT` | 根据此契约为正确行为 |

---

## 6. 实现边界：Poste vs SQL

以下规则定义了 Poste 文件格式与 SQL 语法之间的边界：

### 6.1 Poste 文件格式（由 Lua 处理）

| 结构 | 处理器 | 层 | 说明 |
|------|--------|----|------|
| `-- @connection` 指令 | `completion.lua:get_items()` | 补全层 | 从连接名补全 |
| `-- @database` 指令 | `completion.lua:get_items()` | 补全层 | 从数据库名补全 |
| 指令上下文追踪 | `context.lua:resolve_context()` | 执行层 | 按语句前向最近指令解析有效连接/数据库 |
| `USE database` 语句 | `context.lua:resolve_context()` | 执行层 | 数据库上下文切换 |

> **补全管道**：Lua 只剥离指令行，将文件完整 SQL 正文传给 Rust。

### 6.2 SQL 语法（由 Rust 处理）

| 结构 | 处理器 | 说明 |
|------|--------|------|
| 分词 | `tokenizer.rs` | 关键字、标识符、字符串、注释、操作符 |
| 上下文检测 | `context.rs` / `detectors.rs` / `scanner.rs` | 返回 `ContextType` + tables + prefix |
| 表提取 | `tables.rs` | FROM/JOIN/INTO/UPDATE，模式限定，别名 |
| 语句跨度 | `statements.rs` | 带字符串/注释感知的 `;` 边界 |
| 已知函数 | `functions.rs` | 方言特定的函数列表 |

### 6.3 永不相交的边界

- Rust **不得**解析 `-- @connection` 名称（无权访问 `connections.json`）。
- 补全管道中，Lua 负责剥离指令行，将完整 SQL 正文传给 Rust。
- 除非 Rust 二进制不可用，否则 Lua **不得**在 `completion_ctx.lua` 中尝试超出 Rust 提供的启发式 SQL 语法分析。
- `-- @` 是 Poste 文件语法，不是 SQL 语法。

---

## 7. 测试覆盖要求

本文档中的每条规则必须被至少一个测试覆盖：

| 章节 | 测试位置 | 类型 |
|------|----------|------|
| 1.1 文件结构 | `tests/sql_completion_spec.lua` | Lua 集成 |
| 1.2 请求块 | `tests/sql_completion_spec.lua` | Lua 集成 |
| 2. 指令补全 | `tests/sql_completion_spec.lua` | Lua + Rust |
| 2.4 指令排除 | `tests/sql_completion_edge_spec.lua` → Rust golden | Rust 单元 |
| 3. 语句边界 | `crates/poste-core/src/sql_context/tests.rs` | Rust 单元 |
| 4. JSON 契约 | Rust golden fixtures（P2） | Rust 集成 |
| 5. 上下文类型 | `crates/poste-core/src/sql_context/tests.rs` | Rust 单元 |
| 5.2 边界情况 | `crates/poste-core/src/sql_context/tests.rs` | Rust 单元 |

---

## 8. 已关闭的开放问题

以下问题已在 P0 设计评审会议（`meeting-minutes.zh.md`）中决定，不再待讨论：

1. **空行边界**：`is_blank_line_separator()` 是 **P3 前的临时防护**，P3 ScopeResolver 完成后移除。ScopeResolver 通过理解语句结构（CTE/子查询/别名作用域）替代空行启发式。✅ **已决定**

2. **JSON 中的 statement 字段**：不在 Rust 输出中。由 Lua 层在需要时调用 `poste context stmt` 计算。✅ **已决定**

3. **JSON 中的 block 字段**：`###` 已被移除，不是 Poste 文件语法的一部分。不在 Rust 输出中。✅ **已决定**

4. **`in_string` + `in_comment` → 显式 ctx_type**：P1 中实现 **选项 3**——Rust 添加 `ContextType::String` 和 `ContextType::Comment`，显式返回给 Lua，不再使用 `None` + 歧义回退。✅ **已决定**

5. **`SchemaTable` 的 `ctx_schema`**：P1 中与 `version` 字段一起添加。✅ **已决定**
