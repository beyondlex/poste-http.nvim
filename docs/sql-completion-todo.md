# SQL Completion — 未覆盖场景 Todo 清单

本文档整理所有已知的 SQL completion 空白场景，按所属模块和修复难度分类。

---

## 一、Rust `detect_scan_backward` — 上下文分类错误

> 文件：`crates/poste-core/src/sql_context.rs`，`detect_scan_backward()` 函数

### 1.1 `WHERE col NOT ` → 应提示谓词，现提示列名

```sql
WHERE id NOT ▊
-- 期望: NOT IN / NOT LIKE / NOT BETWEEN / IS NOT
-- 目前: Column (NOT 在 COLUMN_CTX 中)
```

- 已修复：`detect_scan_backward` 中 NOT 前为 Ident 时返回 Keyword，前为 IS/WHERE 时返回 Column

### 1.2 `WHERE col = ` → 应提示关键字，现提示列名

```sql
WHERE id = ▊
-- 期望: AND / OR / ORDER BY
-- 目前: Column (跳过 Op，往前扫到 WHERE)
```

- 已修复：Op token 的 backward scan 在 prev 不是 Keyword 时自动返回 Keyword

### 1.3 `RETURNING ` → 应提示列名，现提示关键字

```sql
DELETE FROM users WHERE id = 1 RETURNING ▊
-- 期望: 表字段名
-- 目前: Keyword
```

- 已修复：加入 `is_column_keyword` + 已知关键字列表

### 1.4 `SELECT DISTINCT ` / `SELECT ALL ` → 应提示列名，现提示关键字

```sql
SELECT DISTINCT ▊
SELECT ALL ▊
-- 期望: 表字段名
-- 目前: Keyword (DISTINCT/ALL 不在 COLUMN_CTX 中)
```

- 已修复：DISTINCT/ALL 加入 `is_column_keyword`；ALL 仅在 SELECT 后返回 Column（UNION ALL 保持 Keyword）

### 1.5 `COPY table FROM ` → 应提示表名，现提示关键字

```sql
COPY posts FROM ▊
-- 期望: Table (提示表名)
-- 目前: Keyword (COPY 不在 TABLE_CTX 中)
```

- 已标注：`CURRENT: COPY not in TABLE_CTX → Keyword`

### 1.6 `DROP INDEX ` / `CREATE INDEX ` → 应提示表名，现提示关键字

```sql
DROP INDEX ▊
CREATE INDEX ▊
```

- 已标注：`CURRENT: INDEX is not in TABLE_CTX → Keyword`
- 同样问题：`VIEW`

### 1.7 `ALTER TABLE name ADD COLUMN ` → 应提示数据类型，现提示关键字

```sql
ALTER TABLE users ADD COLUMN age ▊
-- 期望: DataType (INTEGER/VARCHAR 等)
-- 目前: Keyword
```

- 已修复：Rust 侧检测 `ADD COLUMN col_name` 模式后返回 DataType；Lua 侧新增 `"datatype"` handler 只过滤数据类型

### 1.8 `COALESCE(` / `NULLIF(` 等函数 → 括号后应提示列名，现提示关键字

```sql
COALESCE(▊
-- 期望: Column
-- 目前: Keyword (函数括号被解析为 LParen → LParen handler → Keyword)
```

- 已标注：`CURRENT: cursor at COALESCE( → paren context → Keyword`

### 1.9 `ON CONFLICT DO UPDATE SET ` → 应提示列名，现提示关键字

```sql
INSERT INTO users VALUES (1) ON CONFLICT DO UPDATE SET ▊
-- 期望: Column
-- 目前: Keyword
```

### 1.10 `VALUES ( ` → 括号内应提示列名（或保持关键字）

```sql
INSERT INTO users ▊ VALUES (▊
```

### 1.11 `TABLE ` 关键字后的上下文不完整

```sql
TRUNCATE TABLE ▊  → Table ✅
CREATE TABLE ▊    → Table ✅
ALTER TABLE ▊     → Table ✅
DROP TABLE ▊      → Table ✅
DROP INDEX ▊      → Keyword (应 Table) ⬆️
CREATE VIEW ▊     → Keyword (应 Table) ⬆️
DROP VIEW ▊       → Keyword (应 Table) ⬆️
```

### 1.12 `CASE WHEN / THEN / ELSE / END `

```sql
CASE WHEN ▊  → 目前 Keyword
-- 期望: Column (条件表达式)
```

- 已标注：`CURRENT: WHEN is not in COLUMN_CTX → Keyword. Ideal: Column`

### 1.13 子查询内 `LParen` 过度保守

```sql
SELECT * FROM users WHERE id IN (SELECT id FROM posts WHERE ▊
-- 目前: Keyword（LParen 处理 → 跳过子查询上下文）
-- 期望: Column（子查询内 WHERE 应返回 Column）
```

- 已标注：`CURRENT: inside IN subquery → paren triggers LParen handler → Keyword`
- 这需要更复杂的 paren-depth 分析：跟踪已打开的 paren 数量，判断最内层 paren 之前的语法上下文

---

## 二、Rust `extract_tables` — 表提取缺陷

> 文件：`crates/poste-core/src/sql_context.rs`，`extract_tables()` 函数

### 2.1 子查询别名不捕获

```sql
SELECT * FROM (SELECT * FROM items) AS sub WHERE ▊
-- sub 是别名，但 extract_tables 只解析 FROM/JOIN 后的标识符，
-- 不解析子查询 AS 别名
```

- 已标注：`CURRENT: extract_tables doesn't capture subquery aliases`
- 影响：`WHERE` 字段补全无法使用别名

### 2.2 CTE 别名不捕获

```sql
WITH cte AS (SELECT * FROM items) SELECT * FROM cte WHERE ▊
-- cte 被当作普通表引用，但 extract_tables 中的 CTE 解析缺失
```

### 2.3 Schema 限定别名 whitespace 缺陷

```sql
SELECT * FROM public.users u WHERE u.▊
-- schema 限定名的别名检测有 whitespace skip 问题
```

- 已标注：`BUG: schema-qualified alias detection doesn't skip whitespace`

### 2.4 函数调用的 `(` 干扰 paren depth

```sql
SELECT COUNT(*) FROM posts WHERE ▊
-- COUNT(*) 的 () 增加 paren_depth → 后面的 FROM 被当子查询跳过
```

- 当前代码里 `extract_tables` 中 `LParen → paren_depth += 1` 是全局的，函数括号和子查询括号无法区分
- 实际可能不影响（`FROM` 已解析完成后才遇到 `COUNT(*)`？需验证）

---

## 三、Lua `detect_context` — 回退路径缺陷

> 文件：`lua/poste/sql/completion.lua`，`detect_context()` 函数

仅在 `vim.g.poste_sql_legacy_completion = true`（纯 Lua 模式）或 Rust 返回 Keyword、Lua fallback 触发时生效。

### 3.1 注释/字符串不感知

```sql
-- FROM ▊          → Table（应 Keyword，注释内容被扫描）
/* WHERE user */ ▊ → Column（应 Keyword）
'WHERE ▊'          → Column（字符串内）
```

- 已标注：`BUG: -- FROM<space> → table context`
- 已标注：`BUG: -- WHERE<space> → column context`

### 3.2 Lua `extract_from_tables` — 无 paren depth

```sql
SELECT * FROM (SELECT * FROM items) AS sub WHERE ▊
-- items 泄漏到外层表列表（即使它在子查询内）
```

- 已标注 `BUG: tables from subquery-FROM leak to outer scope`

### 3.3 无 CTE 理解

```sql
WITH cte AS (SELECT * FROM users) SELECT * FROM cte WHERE ▊
-- users 泄漏到外层（CTE 定义中的表不应泄漏）
```

- 已标注 `BUG: CTE inner tables leak`

### 3.4 Schema 限定名只取首词

```sql
SELECT * FROM public.users WHERE ▊
-- Lua 正则取 `FROM r"\w+"` → "public" 而非 "public.users"
```

### 3.5 连标识符语法不再需要 Lua 回退（已由 Rust 覆盖）

---

## 四、Lua `toggle_legacy` 三个模式的行为一致性

> 文件：`lua/poste/sql/completion.lua`

| 模式 | 别名解析 | WHERE 列 | 表名称提示 |
|------|---------|---------|-----------|
| `nil`（默认, Rust + Lua fallback） | ✅ | ✅(Rust) | ✅ |
| `"rust"`（Rust strict） | ✅（修复后） | ✅（修复后） | ✅ |
| `true`（纯 Lua） | ⚠️ 3.2~3.4缺陷 | ⚠️ 3.1缺陷 | ⚠️ 3.1~3.4缺陷 |

- 建议：Lua 模式保持向后兼容性即可，专注改善 Rust 模式

---

## 五、交互/UI 层

### 5.1 `blink.cmp` / `nvim-cmp` 行号兼容性

- `blink.cmp` 传 `ctx.cursor[1]` 为 0-indexed，`nvim-cmp` 用 `vim.fn.line(".")` 为 1-indexed
- `extract_from_tables` 已通过 `+1` 修复，但其他调用点（如 `try_rust_context` 的 block detection）可能仍有问题

### 5.2 多语句同块时的 scope 隔离

- SQL 脚本中的多条 SQL 语句共享同一个表/列缓存
- 如果一条语句引用 `authors`，另一条看不到它——这是正确的行为（因不是同一个 schema），但用户可能期望更智能的跨语句 scope

---

## 六、Tokenization 局限

### 6.1 Dollar-quoted string (`$$`)

```sql
SELECT $$hello$$ FROM posts WHERE ▊
-- $$ 字符串未 tokenize → 内部内容泄漏
```

- 已标注在之前测试中

### 6.2 函数调用和子查询的 `()` 无法区分

- Tokenizer 中 `(` 和 `)` 仅标记为 LParen/RParen
- 解析器不能区分 `COUNT(*)` 的函数调用括号和 `(SELECT ...)` 的子查询括号
- 这影响 paren depth 追踪的准确性

---

## 优先级建议

### P0 — 高频使用、影响明显（✅ 全部完成）

| 优先级 | 项目 | 状态 |
|--------|------|------|
| P0 | `WHERE col NOT ` → Keyword | ✅ |
| P0 | `WHERE col = ▊` → Keyword | ✅ |
| P0 | `ALTER TABLE name ADD COLUMN ` → DataType | ✅ |
| P0 | `SELECT DISTINCT/ALL ` → Column | ✅ |
| P0 | `RETURNING ` → Column | ✅ |
| P0 | `COMMENT`, `AFTER` 关键字缺失 | ✅ |
| P0 | `AFTER ` → Column（仅列名） | ✅ |

### P1 — 重要但使用频率较低

| 优先级 | 项目 | 工作量 |
|--------|------|--------|
| P1 | 子查询内 `WHERE ` 正确返回 Column | 大（需 paren-depth 追踪 LParen 类型） |
| P1 | 子查询别名捕获（`AS sub`） | 中 |
| P1 | 函数调用 LParen 不干扰上下文（`COALESCE(▊`） | 中 |
| P1 | `DROP INDEX / VIEW` → Table | 小 |
| P1 | `COPY ... FROM ` → Table | 小 |
| P1 | `ON CONFLICT DO UPDATE SET ` → Column | 小 |

### P2 — 低优先级 / 边缘场景

| 优先级 | 项目 | 工作量 |
|--------|------|--------|
| P2 | CTE 别名不捕获 | 中 |
| P2 | Schema 限定别名 whitespace bug | 小 |
| P2 | Dollar-quoted string tokenization | 小 |
| P2 | Lua fallback 路径注释/字符串不感知 | 与 Rust 模式基本无关 |

---

## 实现策略

**三原则**：

1. **优先修 Rust 侧** — 凡是 Rust 能覆盖的场景，不要在 Lua 侧做双重工作
2. **先加测试再加代码** — 每个修复前先在 `sql_context.rs` 写一个 `test_detect_*` 测试断言当前行为
3. **P0 修完后，考虑去掉 Lua fallback** — 如果 Rust 覆盖了所有高频场景，Lua fallback 可以简化为仅在 `legacy == true` 时启用
