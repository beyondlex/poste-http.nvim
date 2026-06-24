# SQL Completion 诊断报告

## 问题

SQL 文件中的 completion 没有显示表名和列名提示。例如：
- `select * from ` 后面应该提示表名
- `where ` 后面应该提示列名

## 根本原因

SQL completion 依赖于 **数据库连接上下文**。代码流程如下：

1. 用户输入 `select * from ` （空格触发 completion）
2. `detect_context()` 识别为 `"table"` 上下文
3. `ensure_tables()` 被调用，尝试异步获取表名
4. **关键步骤**：`ensure_tables()` 首先调用 `conn_key()` 获取连接标识
5. `conn_key()` 调用 `resolve_current_context()` 解析 buffer 中的 `-- @connection` 指令
6. **如果没有找到 connection**，`ensure_tables()` 直接返回空列表

## 必需条件

SQL completion 要求文件顶部必须有 `-- @connection` 指令：

```sql
-- @connection mysql://user:pass@host:port/database

### 查询示例
select * from [这里会提示表名]
```

或者 PostgreSQL：

```sql
-- @connection postgres://user:pass@host:port/database

### 查询
select * from [这里会提示表名]
```

## 代码路径

### Connection 解析

`lua/poste/sql/context.lua` 的 `resolve_context()` 函数：

```lua
-- 扫描 buffer 查找 @connection 指令
local conn_match = line:match("^%s*--%s*@connection%s+(.+)")
if conn_match then
  connection = vim.trim(conn_match)
end
```

### Completion 触发

`lua/poste/sql/completion.lua`:

1. **Context 检测** (`detect_context`):
   - 检测到 `from`/`join`/`update` 等关键字后 → `"table"` 上下文
   - 检测到 `where`/`set`/`having` 等关键字后 → `"column"` 上下文

2. **表名获取** (`ensure_tables`):
   ```lua
   if not key or not ctx or not ctx.connection then 
     callback()  -- 无 connection，返回空
     return 
   end
   ```

3. **列名获取** (`ensure_columns`):
   - 类似逻辑，依赖 connection context

## 修复措施

已实施以下改进：

### 1. Fallback 到 SQL 关键字

当没有表名/列名时（例如没有 connection），至少显示 SQL 关键字：

```lua
if ctx_type == "table" then
  ensure_tables(function()
    local key = conn_key()
    local tbls = cache[key] and cache[key].tables or {}
    local items = make_items(tbls, 7, "table: ")
    -- 如果没有表名，显示关键字
    if #items == 0 then
      items = kw_items(prefix)
    end
    callback(filter(items, prefix))
  end)
  return
end
```

### 2. 诊断命令

添加了 `:PosteSQLCmpStatus` 命令来检查：
- 当前 filetype
- blink.cmp 注册状态
- Connection context
- 光标位置的 completion context

使用方法：
1. 在 SQL 文件中打开
2. 光标移动到想要测试的位置（如 `select * from ` 后）
3. 运行 `:PosteSQLCmpStatus`

### 3. Debug 日志

在 `conn_key()` 中添加了 debug 日志：

```lua
if vim.g.poste_sql_debug then
  state.log("WARN", "SQL completion: no connection context found")
end
```

启用：`:let g:poste_sql_debug = 1`

## 使用步骤

### 正确使用 SQL completion

1. **创建 SQL 文件** (例如 `queries.sql`)

2. **添加 connection 指令**：
   ```sql
   -- @connection mysql://user:pass@localhost:3306/mydb
   ```

3. **编写查询**：
   ```sql
   ### 用户查询
   select * from [按空格或开始输入，会显示表名]
   ```

4. **列名 completion**：
   ```sql
   ### 用户查询
   select * from users where [按空格或开始输入，会显示列名]
   ```

### Connection 格式

- **MySQL**: `mysql://user:pass@host:port/database`
- **PostgreSQL**: `postgres://user:pass@host:port/database`
- **SQLite**: `sqlite://path/to/db.sqlite`

### 触发字符

SQL completion 在以下字符后自动触发：
- `.` (点号，用于 `table.column`)
- ` ` (空格)
- `@` (用于 `@connection`)

## 验证步骤

1. 打开 `./ignore/test.sql`
2. 检查第一行是否有 `-- @connection` 指令
3. 移动到 `select * from ` 后面
4. 按 `Ctrl+Space` 手动触发 completion（如果 blink.cmp 没有自动触发）
5. 运行 `:PosteSQLCmpStatus` 查看诊断信息

## 常见问题

### Q: 为什么没有任何 completion？

**A**: 检查以下几点：
1. filetype 是否为 `poste_sql` 或 `poste_sqlite`（`:set ft?`）
2. 文件中是否有 `-- @connection` 指令
3. blink.cmp 是否加载（`:PosteSQLCmpStatus`）
4. poste binary 是否可用（completion 需要调用 `poste introspect`）

### Q: 只显示关键字，没有表名/列名？

**A**: 这说明 connection context 缺失或无法连接数据库：
1. 检查 `-- @connection` 格式是否正确
2. 检查数据库是否可访问
3. 运行 `:PosteSQLCmpStatus` 查看 connection 状态

### Q: 如何手动触发 completion？

**A**: 在 insert mode 按 `Ctrl+Space`（blink.cmp 默认快捷键）

## 技术细节

### blink.cmp 注册

在 `lua/poste/init.lua` 中：

```lua
blink.add_source_provider("poste_sql", {
  module = "poste.sql.completion",
  name = "PosteSQL",
  score_offset = 100,
})
blink.add_filetype_source("poste_sql", "poste_sql")
blink.add_filetype_source("poste_sqlite", "poste_sql")
```

### 异步架构

表名和列名通过异步 job 获取：

```lua
vim.fn.jobstart({ binary, "introspect", connection,
  "--type", "tables", "--path", path, "--env", env }, {
  on_stdout = function(_, data)
    -- 解析 JSON，填充 cache
  end
})
```

缓存按 `connection/database` key 存储，避免重复查询。

### Context 优先级

1. **Buffer-local**: 文件中的 `-- @connection` 和 `-- @database` 指令
2. **USE statement**: `USE database_name;` 会更新当前 database context
3. **Global state**: `state.sql.context` 作为 fallback

## 下一步

可能的改进：

1. **更好的错误提示**：当没有 connection 时，在 completion menu 中显示提示项
2. **Connection picker**：自动检测可用连接，提供选择菜单
3. **预加载缓存**：文件打开时预加载表名和列名
4. **Semantic completion**：基于 SQL 解析的更智能的列名推荐
