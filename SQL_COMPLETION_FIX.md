# SQL Completion 修复总结

## 问题诊断

### 问题 1：需要在每个查询前重复 @connection 和 @database

**根本原因**：`resolve_context()` 的扫描逻辑有缺陷，它会扫描整个文件并不断覆盖 connection/database 值。

**解决方案**：重构 context 解析为两阶段：
1. **Phase 1 (Global)**：扫描文件头部（第一个 `###` 之前）获取全局默认值
2. **Phase 2 (Block-local)**：扫描当前查询块（从当前 `###` 到下一个 `###`）获取覆盖值

**现在的用法**：

```sql
-- @connection my-blog
-- @database blog

### Query: all authors
SELECT * FROM authors WHERE [这里会提示列名]

### Query: posts
SELECT * FROM posts WHERE [这里也会提示列名]

### Query: use different db (optional override)
-- @database analytics
SELECT * FROM events WHERE [提示 analytics.events 的列名]
```

### 问题 2：WHERE 后面提示关键词而不是列名

**根本原因**：`get_items()` 函数没有接收 `cursor_line` 参数，导致 `extract_from_tables()` 使用 `vim.fn.line(".")` 获取行号，在异步 completion context 中不准确。

**解决方案**：
1. 修改 `get_items()` 签名，添加 `cursor_line` 参数
2. 从 `ctx.cursor[1]` 获取正确的行号并传递
3. 更新 blink.cmp 和 nvim-cmp 两个 source

**修改的函数**：
- `get_items(bufnr, line_before, cursor_line, callback)` - 新增 cursor_line 参数
- `M:get_completions(ctx, callback)` - 提取 ctx.cursor[1] 并传递
- `M.source:complete(params, callback)` - 使用 vim.fn.line(".") 传递

## 修改的文件

### lua/poste/sql/context.lua
- 重构 `resolve_context()` 为两阶段扫描
- 全局默认 + 块级覆盖

### lua/poste/sql/completion.lua
- `get_items()` 新增 `cursor_line` 参数
- `extract_from_tables()` 使用传入的 cursor_line
- 更新 blink.cmp 和 nvim-cmp sources

## 测试方法

### 测试问题 1 的修复

使用 `test_completion.sql`：

```sql
-- @connection my-blog
-- @database blog

### Query: all authors
SELECT * FROM authors WHERE 
```

**验证**：
1. 光标在第 5 行 `WHERE` 后面
2. 运行 `:PosteSQLCmpStatus` 应该显示：
   - Connection: my-blog
   - Database: blog
3. 触发 completion 应该显示 authors 表的列名

### 测试问题 2 的修复

同样的文件，在 `WHERE` 后输入字母（如 `i`）：
- **之前**：显示 BIGINT, BIGSERIAL 等关键词
- **现在**：显示 id, name, email 等列名

## 行为变化

### 之前
```sql
-- 每个查询都需要重复
### Query 1
-- @connection my-blog
-- @database blog
SELECT * FROM authors

### Query 2
-- @connection my-blog  -- 必须重复
-- @database blog       -- 必须重复
SELECT * FROM posts
```

### 现在
```sql
-- 文件级别的默认值
-- @connection my-blog
-- @database blog

### Query 1
SELECT * FROM authors  -- 自动使用 my-blog/blog

### Query 2
SELECT * FROM posts    -- 自动使用 my-blog/blog

### Query 3 (optional override)
-- @database analytics  -- 仅覆盖 database
SELECT * FROM events   -- 使用 my-blog/analytics
```

## 未来改进（问题 1 的进一步增强）

可以添加更友好的 UI：

1. **Connection picker**：`:PosteSQLConnection` 选择并绑定 connection
2. **Database picker**：`:PosteSQLDatabase` 选择 database
3. **自动插入指令**：选择后自动在文件头部添加/更新 `@connection` 和 `@database`
4. **持久化**：将绑定关系存储在 `.poste/` 目录中

但当前的解决方案已经大大简化了使用体验：只需在文件顶部声明一次。
