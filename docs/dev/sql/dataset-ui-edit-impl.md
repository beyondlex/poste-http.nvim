# Dataset 数据编辑功能 — 实施与验收文档

> 基于 `dataset-ui-design.md` §3 核心突破：极简的"数据编辑"流。
> 当前状态：PROGRESS.md Step 32 (sql/editor.lua) + Step 33 (Edit commit) — 均未开始。

---

## 一、整体设计原则

1. **非破坏性暂存**：所有修改先在 Lua 侧缓存，生成 diff，最终用户确认后批量提交
2. **Vim 直觉**：`i` 编辑、`dd` 删除、`o` 插入、`:w` 保存
3. **零 GUI 弹窗**：编辑用浮窗单行输入（不遮挡结果集），删除/新增用视觉标记
4. **编辑状态可感知**：修改行用颜色标记（黄/红/绿），winbar 显示 pending 计数
5. **TDD 驱动**：所有编辑逻辑先写 Lua 单元测试，再实现
6. **防护优先**：raw mode/二进制列/无主键表不支持编辑，类型不匹配做单元格级别拦截

---

## 二、新增文件

### 1. `lua/poste/sql/editor.lua` — 数据集编辑核心

#### 数据结构

在 `dataset.lua` 的 tab 结构中新增编辑状态字段：

```lua
edit_state = {
  dirty = false,
  modified_cells = {},        -- { [row_key] = { col, old_val, new_val } }
  deleted_rows = {},          -- { [source_row_idx] = true }
  added_rows = {},            -- { added_row_data = {col1, col2, ...}, ... }
  original_rows_snapshot = {},-- 修改前的原始行数据快照
  cell_errors = {},           -- { [row_key] = { col, msg } } 单元格级别错误
}
```

#### 核心函数

| 函数 | 触发 | 行为 |
|------|------|------|
| `is_editable_field(col_meta)` | 内部 | 检查字段类型是否支持编辑。binary/bytea/geometry/等跳过 |
| `edit_cell()` | `i`/`cc` | 读当前单元格值 → 类型检测 → 浮动输入框 → 验证 → 写入 + 高亮 |
| `delete_row()` | `dd` | 标记行到 edit_state.deleted_rows → 覆盖 Buffer 行文本 → 高亮 PosteSqlDeleted |
| `insert_row(after)` | `o`/`O` | 在 Buffer 中插入空行 → `"[Auto]"`(自增主键) / `nil` → 标记 added_rows → 高亮 |
| `reset_edits()` | 内部 | 清空 edit_state → 从原始数据重新渲染 Buffer |
| `has_pending_changes()` | 查询 | 返回 dirty 状态，供 winbar 显示 `[+1 ~2 -1]` |
| `validate_value(value, col_meta)` | 内部 | 根据列类型验证值合法性，返回 `(ok, error_msg)` |
| `set_cell_error(row, col, msg)` | 内部 | 在单元格上显示 `PosteSqlError` 红色高亮 |
| `clear_cell_error(row, col)` | 内部 | 清除单元格错误标记 |

#### 浮动编辑框

```lua
-- 伪代码流程
function M.edit_cell()
  local tab = D.T()
  if not tab or not tab.layout then return end

  local layout = tab.layout
  local row_idx = state.sql.cell.row
  local col_idx = state.sql.cell.col
  local col_meta = layout.columns[col_idx]

  -- 1. 不可编辑检查
  if not is_editable_field(col_meta) then
    vim.notify("Cannot edit " .. (col_meta.ctype or "unknown") .. " field", vim.log.levels.WARN)
    return
  end

  -- 2. 读取当前值
  local old_val = layout.rows[row_idx][col_idx]

  -- 3. JSON 列特殊处理: 格式化后编辑
  local initial_text = tostring(old_val)
  if is_json_column(col_meta) and type(old_val) == "table" then
    initial_text = vim.json.encode(old_val, { indent = 2 })
  end

  -- 4. 弹出输入框
  --    boolean/enum 类型: 用 vim.ui.select 而不是 vim.ui.input
  if is_boolean_column(col_meta) then
    -- 弹出选择器 true/false/NULL
    show_boolean_selector(row_idx, col_idx, old_val)
  elseif is_enum_column(col_meta) then
    -- 弹出选择器: 从 col_meta.enum_values 获取候选项
    show_enum_selector(row_idx, col_idx, old_val, col_meta.enum_values)
  else
    vim.ui.input({ prompt = format_prompt(col_meta), default = initial_text }, function(input)
      if input == nil then return end  -- <C-c> 取消

      local new_val = parse_and_validate(input, col_meta)
      if new_val == nil then return end  -- 值不变

      -- 类型不匹配验证
      local ok, err = validate_value(new_val, col_meta)
      if not ok then
        set_cell_error(row_idx, col_idx, err)
        return  -- 保留编辑状态不变，显示错误
      end
      clear_cell_error(row_idx, col_idx)

      apply_cell_edit(row_idx, col_idx, new_val)
    end)
  end
end
```

#### 单元格值转换规则

```
用户输入 → 转换逻辑 → 写入 layout.rows[row][col]

"" (空输入, 原值非空)          → vim.NIL  (设置为 NULL)
"" (空输入, 原值为 NIL)        → 不变, 取消
"''"                           → ""  (空字符串)
"(NULL)" 或 "NULL"             → vim.NIL
纯数字 "42"                    → 42  (number)
"true"/"false"                 → true/false  (boolean)
JSON 对象 "{"a":1}"            → vim.json.decode(input)
其他字符串                      → 原样保留 (string)
```

#### 类型不匹配拦截

对已知列类型做严格校验，不匹配时设置**单元格级别错误标记**（红色波浪线/背景），不阻止继续编辑其他单元格：

| 列类型 | 校验规则 | 错误示例 |
|--------|---------|---------|
| `integer`/`int`/`bigint`/`smallint` | 输入 `tonumber()` 成功，且为整数 | `"abc"` → ERROR |
| `numeric`/`decimal`/`real`/`float` | 输入 `tonumber()` 成功 | `"abc"` → ERROR |
| `boolean`/`bool` | 输入为 `true`/`false`/`1`/`0`/`yes`/`no` | `"maybe"` → ERROR |
| `date`/`timestamp`/`timestamptz` | 输入能被 `os.date` 解析, 或完整 ISO 格式 | `"not a date"` → ERROR |
| `json`/`jsonb` | `vim.json.decode()` 成功 | `"{bad json}"` → ERROR |
| `uuid` | 匹配 `{8}-{4}-{4}-{4}-{12}` 格式 | `"abc"` → ERROR |
| `text`/`varchar`/`char` | 任何字符串都合法 | — |
| `binary`/`bytea`/`bit`/`varbit`/`geometry`/`point`/`polygon`/`inet`/`cidr`/`macaddr` | **不支持编辑** | 提示 "Cannot edit field type: X" |

#### 不可编辑字段清单

以下字段类型跳过编辑（`is_editable_field()` 返回 false）：

- `binary`, `bytea`, `blob`, `varbinary`
- `geometry`, `geography`, `point`, `polygon`, `linestring`
- `inet`, `cidr`, `macaddr`
- `bit`, `varbit`
- `interval`
- `tsvector`, `tsquery`
- 用户自定义类型（`col_meta.user_defined == true`）

#### Boolean/Enum 自动补全

- **boolean**: 用 `vim.ui.select` 显示候选项 `{ "(NULL)", "true", "false" }`，替换 `vim.ui.input`
- **enum** (PG): 从 `col_meta.enum_values` 读取候选项，用 `vim.ui.select` 显示。候选项末尾加 `"(NULL)"` 选项
- 如果没有 enum_values 信息，退化为 `vim.ui.input`

#### JSON 格式化编辑

- 编辑前检测列类型是否为 `json`/`jsonb`
- 当前值为 table 时，用 `vim.json.encode(val, { indent = 2 })` 格式化为带缩进的字符串作为输入预填
- 确认后 `vim.json.decode(input)` 转回 table

---

### 2. `lua/poste/sql/edit_commit.lua` — 提交/回滚

#### 核心函数

| 函数 | 触发 | 行为 |
|------|------|------|
| `commit_edits()` | `:w` (dataset buf) | 读取 edit_state → 生成 DML SQL → 通过 poste CLI 执行 → 刷新结果集 |
| `rollback_edits()` | `R` | 确认 → 重新执行原查询 → 清空 edit_state |
| `generate_dml()` | 内部 | 根据 diff 生成 UPDATE/INSERT/DELETE 语句 |

#### DML 生成逻辑

对 PostgreSQL/MySQL/SQLite 三端统一，利用 `dialect` 信息做标识符引用：

**UPDATE**（modified_cells）:
```sql
UPDATE "public"."users" SET "email" = 'new@example.com' WHERE "id" = 1;
```
- WHERE 子句：有主键信息时只用主键，否则用**所有原始列值**

**INSERT**（added_rows）:
```sql
INSERT INTO "public"."users" ("name", "email") VALUES ('new', 'new@example.com');
```
- 跳过 `[Auto]` 标记的列

**DELETE**（deleted_rows）:
```sql
DELETE FROM "public"."users" WHERE "id" = 1;
```

#### 主键检测

- 优先从 `meta.columns[i].primary_key` 字段获取
- 如果后端不返回主键信息，退化到用**所有列值**构造 WHERE 条件
- 无主键表 → 提交时警告并阻止（UPDATE/DELETE 操作不安全）

#### 执行流程

1. 调用 `generate_dml()` 生成 SQL 字符串
2. 使用 `vim.fn.jobstart` 通过 `poste run --stdin` 执行
3. 成功后：刷新数据集（重新执行原查询），清除编辑状态
4. 失败时：在 dataset buffer 底部显示错误行，不清除编辑状态

---

## 三、需要修改的文件

### 1. `lua/poste/sql/buffer.lua`

新增 keymaps：

| Action | Key | Description |
|--------|-----|-------------|
| `edit_cell` | `i` | 进入单元格编辑 |
| `edit_cell_replace` | `cc` | 替换单元格（同 i） |
| `delete_row` | `dd` | 删除当前行 |
| `insert_row_after` | `o` | 在当前行后插入空行 |
| `insert_row_before` | `O` | 在当前行前插入空行 |
| `commit_edits` | `<leader>w` | 提交所有暂存修改 |
| `quick_commit` | `:w` | BufWriteCmd autocmd |
| `refresh_data` | (已有 `R`) | 已映射到 rerun，需要改为 rollback 逻辑 |

注意：`a` 保留不绑定，避免与 Vim 原生 `a`（append）冲突。在 dataset buffer 中 `a` 等同于 `i`，不区分插入/追加。

注册 `BufWriteCmd` autocmd：

```lua
vim.api.nvim_create_autocmd("BufWriteCmd", {
  buffer = D.dataset_buffer,
  callback = function()
    if D.T() and D.T().edit_state and D.T().edit_state.dirty then
      require("poste.sql.edit_commit").commit_edits()
    end
  end,
})
```

在 `apply_rendered_page` 中，渲染后重新应用编辑高亮。

### 2. `lua/poste/state.lua` — `sql_dataset` keymaps 区

新增条目：

```lua
sql_dataset = {
  -- ... existing ...
  edit_cell = "i",           -- 编辑单元格
  edit_cell_replace = "cc",  -- 替换单元格
  delete_row = "dd",         -- 删除行
  insert_row_after = "o",    -- 下方插入行
  insert_row_before = "O",   -- 上方插入行
  commit_edits = "<leader>w", -- 提交修改
}
```

### 3. `lua/poste/sql/highlights.lua`

`PosteSqlModified` / `PosteSqlDeleted` / `PosteSqlAdded` 已定义。新增：

```lua
-- 编辑高亮
function M.apply_edit_highlights(buf, tab)
  -- modified_cells: 单元格区域叠加 PosteSqlModified (DiffChange)
  -- deleted_rows:   整行 PosteSqlDeleted (DiffDelete, strikethrough)
  -- added_rows:     整行 PosteSqlAdded (DiffAdd)
  -- cell_errors:    对应单元格 PosteSqlError (红色波浪线/背景)
end
```

新增 highlight group `PosteSqlError`：

```lua
{ "PosteSqlError", "ErrorMsg" }  -- 或 link 到 ErrorMsg / SpellBad
```

### 4. `lua/poste/sql/dataset.lua`

- `M.alloc_tab()` 新增 `edit_state = nil`
- tab 切换时保存/恢复 edit_state

---

## 四、与现有系统的交互

### Raw Mode 限制

- **raw mode 下不支持任何编辑操作**
- 在 `edit_cell()` / `delete_row()` / `insert_row()` 入口检查 `state.sql._raw_mode`
- raw mode 下按 `i`/`dd`/`o`/`O` 不生效并提示 "Editing is not supported in raw mode"

### 分页/排序/过滤兼容

- edit_state.dirty 时，翻页/排序/过滤**阻止**并提示 "有未提交的修改，请先提交(W)或放弃(R)"
- `i`/`dd`/`o`/`O` 不会被阻止（允许多个修改累积）

### 原始数据访问

- `layout.rows` 和 `layout.columns` 通过 `D.T()` 访问
- 编辑直接修改 `layout.rows`，提交时读原始值（old_val）构造 WHERE

### 多 tab 场景

- 每个 tab 独立维护 edit_state
- 有 dirty 时切换 tab 前给出警告

### 大结果集

- 结果集 > 5000 行时不支持编辑（在编辑入口检查 tab 行数并提示）

### SQL 执行日志

编辑提交和手动 SQL 执行的 SQL 全部记录到日志，用于追溯排查。

**日志存储**：追加写入 `vim.fn.stdpath("data") .. "/poste/sql_log.jsonl"`（JSONL 格式，每行一条独立 JSON 记录）。

**日志条目结构**：
```json
{
  "ts": "2026-06-13T10:30:00.123+0800",
  "source": "dataset_commit",
  "table": "users",
  "connection": "pg-ecommerce",
  "dialect": "postgres",
  "database": "public",
  "sql": "UPDATE \"public\".\"users\" SET \"email\" = 'new@example.com' WHERE \"id\" = 1",
  "status": "success",
  "elapsed_ms": 12,
  "edit_summary": {
    "updates": 1,
    "inserts": 0,
    "deletes": 0
  }
}
```

`source` 字段区分来源：
- `"dataset_commit"` — 数据集编辑提交生成的 DML
- `"manual_exec"` — 用户在 SQL source buffer 按 `<CR>` 执行的 SQL（通过 `sql/init.lua` `run_sql_request()` 入口）

**捕获点**：

| 来源 | 文件 | 捕获时机 |
|------|------|---------|
| 数据集编辑提交 | `edit_commit.lua` → `commit_edits()` | DML 执行后，写日志（成功/失败均记录） |
| 手动 SQL 执行 | `sql/init.lua` → `on_stdout`/`on_exit` | 收到执行结果后，写日志 |

**不记录**：
- `USE database;` 等上下文切换语句
- 翻页/排序触发的后端查询
- DB Browser 的 introspection 查询

**未来 UI 入口**（本次不实现）：
- `:PosteSQLHistory` 命令 — 打开浮动窗口展示历史 SQL 日志
- 支持按 connection/database/时间范围过滤
- 支持选中某条 SQL 重新执行或插入到 source buffer

---

## 五、验收清单

验收场景覆盖 P0-P2 优先级（P0 = 阻塞，P1 = 必需，P2 = 锦上添花）：

### P0 — 核心编辑流程

| # | 验收项 | 步骤 | 预期结果 | 验证 |
|---|--------|------|----------|------|
| 1 | 编辑-确认 | 单元格按 `i` → 输入新值 → `<CR>` | 内容更新，黄色标记 | 手动 |
| 2 | 编辑-取消 | 按 `i` → `<Esc>` 或 `<C-c>` | 不变，无 dirty | 手动 |
| 3 | 编辑-值不变 | 按 `i` → `<CR>`（不改文本） | 不变，无 dirty | 手动 |
| 4 | 删除行 | 数据行按 `dd` | 红色标记，winbar pending | 手动 |
| 5 | 新增行-下方 | 按 `o` | 下方插入空行(绿)，自增列 `[Auto]` | 手动 |
| 6 | 新增行-上方 | 按 `O` | 上方插入空行(绿)，自增列 `[Auto]` | 手动 |
| 7 | 提交修改 | 编辑后 `<leader>w` | 生成 DML 执行，刷新，清除标记 | 手动 |
| 8 | 放弃修改 | `R` (rerun) | 重新查询，清除标记 | 手动 |

### P1 — 值转换

| # | 验收项 | 步骤 | 预期结果 | 验证 |
|---|--------|------|----------|------|
| 9 | 置空-NULL | 输入 DELETE 清空所有字符 → `<CR>` | 值变为 NULL | 手动 |
| 10 | 置空-DEFAULT | 输入 `(NULL)` → `<CR>` | 值变为 NULL | 手动 |
| 11 | 空字符串 | 输入 `''` → `<CR>` | 值变为 `""`（空字符串） | 手动 |
| 12 | 数字 | 输入 `42` → `<CR>` | 保存为 number 42 | 手动 |
| 13 | 布尔 | 输入 `false` → `<CR>` | 保存为 boolean false | 手动 |
| 14 | JSON | JSON 列输入 `{"a":1}` | 保存为 table | 手动 |
| 15 | 文本 | 输入任意字符串 | 保存为 string | 手动 |

### P1 — 类型拦截

| # | 验收项 | 步骤 | 预期结果 | 验证 |
|---|--------|------|----------|------|
| 16 | int 列-非法值 | int 列输入 `"abc"` → `<CR>` | 单元格显示红色错误，保留编辑状态 | 手动 |
| 17 | boolean 列-非法 | bool 列输入 `"maybe"` → `<CR>` | 单元格显示红色错误 | 手动 |
| 18 | date 列-非法 | date 列输入 `"notadate"` | 红色错误提示 | 手动 |
| 19 | uuid 列-非法 | uuid 列输入 `"bad"` | 红色错误提示 | 手动 |
| 20 | int 列-合法 | int 列输入 `42` | 正常修改 | 手动 |
| 21 | date 列-合法 | date 列输入 `"2026-06-13"` | 正常修改 | 手动 |
| 22 | uuid 列-合法 | uuid 列输入 `550e8400-e29b-41d4-a716-446655440000` | 正常修改 | 手动 |

### P1 — 不可编辑字段

| # | 验收项 | 步骤 | 预期结果 | 验证 |
|---|--------|------|----------|------|
| 23 | binary 列 | binary 列按 `i` | 提示 "Cannot edit binary field" | 手动 |
| 24 | geometry 列 | geometry 列按 `i` | 提示 "Cannot edit geometry field" | 手动 |
| 25 | raw mode | raw mode 中按 `i`/`dd`/`o` | 提示不接受编辑 | 手动 |
| 26 | 大结果集 | >5000 行的结果按 `i` | 提示不支持 | 手动 |
| 27 | 无主键表-UPDATE | 无 PK 表修改后提交 | 警告并阻止提交 | 手动 |
| 28 | 无主键表-DELETE | 无 PK 表 dd 后提交 | 警告并阻止提交 | 手动 |

### P1 — boolean/enum 选择器

| # | 验收项 | 步骤 | 预期结果 | 验证 |
|---|--------|------|----------|------|
| 29 | boolean 选择器 | bool 列按 `i` | 弹出选择窗口 `true/false/(NULL)` | 手动 |
| 30 | enum 选择器 | enum 列按 `i` | 弹出选择窗口显示 enum 候选值 +(NULL) | 手动 |

### P1 — 提交安全性

| # | 验收项 | 步骤 | 预期结果 | 验证 |
|---|--------|------|----------|------|
| 31 | 空提交 | 无修改按 `<leader>w` | 提示 "No changes to commit" | 手动 |
| 32 | 提交失败 | 唯一约束冲突等 | 显示错误，编辑状态保留 | 手动 |

### P1 — SQL 日志

| # | 验收项 | 步骤 | 预期结果 | 验证 |
|---|--------|------|----------|------|
| 33 | 编辑提交写日志 | 提交编辑后检查 sql_log.jsonl | 新行记录 DML SQL，source=dataset_commit | 手动 |
| 34 | 手动 SQL 写日志 | 在 SQL buffer 按 `<CR>` 执行 SELECT | sql_log.jsonl 追加 source=manual_exec | 手动 |
| 35 | 失败记日志 | 提交或手动执行一个错误 SQL | 日志中 status=error，含错误信息 | 手动 |
| 36 | 日志累计 | 执行 3 次 SQL | sql_log.jsonl 有 3 行 | 手动 |

### P1 — 边界阻止

| # | 验收项 | 步骤 | 预期结果 | 验证 |
|---|--------|------|----------|------|
| 37 | 翻页阻止 | dirty 后按 `L` | 提示有未提交修改 | 手动 |
| 38 | 排序阻止 | dirty 后按 `s` | 提示 | 手动 |
| 39 | 过滤阻止 | dirty 后按 `<leader>ce` | 提示 | 手动 |
| 40 | tab 切换阻止 | dirty 后按 `<Tab>` | 提示 | 手动 |
| 41 | 表头/边框 dd | 表头或边框按 `dd` | 无效果 | 手动 |
| 42 | 表头/边框 o/O | 表头或边框按 `o`/`O` | 无效果 | 手动 |

### P2 — JSON 编辑

| # | 验收项 | 步骤 | 预期结果 | 验证 |
|---|--------|------|----------|------|
| 43 | JSON 编辑预填格式化 | jsonb 列按 `i` | 输入框显示格式化的多行 JSON | 手动 |
| 44 | JSON 编辑确认 | 修改后 `<CR>` | 保存为 table | 手动 |
| 45 | JSON 编辑-非法 | 输入 `{bad}` → `<CR>` | 红色错误提示 | 手动 |

### P2 — 视觉

| # | 验收项 | 步骤 | 预期结果 | 验证 |
|---|--------|------|----------|------|
| 46 | 混合修改显示 | 修改 2 列，删除 1 行，新增 1 行 | 黄色/红色/绿色 | 手动 |
| 47 | Winbar pending | 编辑后查看 winbar | `[+1 ~2 -1]` 格式 | 手动 |
| 48 | 编辑高亮保持 | 翻页回翻（无 dirty 阻止） | 编辑高亮存在 | 手动 |
| 49 | 连续编辑同单元格 | 编辑两次 | 只一条 diff 记录 | 手动 |
| 50 | 删除已修改行 | 修改某列后 dd | modified_cells 移除，保留 deleted | 手动 |

### P2 — 撤消

| # | 验收项 | 步骤 | 预期结果 | 验证 |
|---|--------|------|----------|------|
| 51 | 撤销单元格编辑 | 修改后按 `u` | 恢复原值，edit_state 移除 | 手动 |
| 52 | 撤销删除行 | dd 后按 `u` | 行恢复 | 手动 |
| 53 | 撤销新增行 | o 后按 `u` | 行移除 | 手动 |

### 单元测试验收

| # | 测试 | 文件 | 验证 |
|---|------|------|------|
| UT1 | `test_parse_value` — 各种输入→值的转换 | 单元测试 | `busted` 通过 |
| UT2 | `test_validate_value` — 各类型拦截 | 同上 | 通过 |
| UT3 | `test_is_editable_field` — 二进制/几何等跳过 | 同上 | 通过 |
| UT4 | `test_edit_state_tracking` — modified/deleted/added | 同上 | 通过 |
| UT5 | `test_edit_state_merge` — 同一单元格多次编辑/修改后删除 | 同上 | 通过 |
| UT6 | `test_generate_update` — UPDATE 生成（有 PK/无 PK） | 同上 | 通过 |
| UT7 | `test_generate_insert` — INSERT 生成（含 Auto 跳过） | 同上 | 通过 |
| UT8 | `test_generate_delete` — DELETE 生成 | 同上 | 通过 |
| UT9 | `test_dialect_quoting` — 三端标识符引用 | 同上 | 通过 |
| UT10 | `test_json_format` — JSON 格式化/解析 | 同上 | 通过 |
| UT11 | `test_sql_log` — 日志写入/格式/累积 | 同上 | 通过 |

---

## 六、实施计划（TDD 模式）

所有子任务先写单元测试，再实现。

### Phase 1: 编辑数据类型 + 值转换 (Step 32a)

| 子任务 | 产出 | 测试先行 |
|--------|------|---------|
| `test_editor_value.lua` — 值转换/类型拦截/可编辑字段测试 | 测试文件 | — |
| `editor.lua` — `parse_value()` / `validate_value()` / `is_editable_field()` | `editor.lua` | ✅ |
| `dataset.lua` — tab edit_state 字段 | `dataset.lua` | — |
| `highlights.lua` — `PosteSqlError` + `apply_edit_highlights()` | `highlights.lua` | — |

### Phase 2: 编辑交互 (Step 32b)

| 子任务 | 产出 | 测试先行 |
|--------|------|---------|
| `test_editor_edit.lua` — edit_cell/delete_row/insert_row/edit_state | 测试文件 | — |
| `editor.lua` — `edit_cell()` / `delete_row()` / `insert_row()` | `editor.lua` | ✅ |
| `editor.lua` — boolean/enum 选择器 | `editor.lua` | — |
| `editor.lua` — JSON 格式化编辑 | `editor.lua` | ✅ |
| `buffer.lua` — keymap 绑定 + BufWriteCmd | `buffer.lua` | — |
| `state.lua` — keymap 定义 | `state.lua` | — |
| 翻页/排序/过滤 dirty 阻止 | 各 buffer_*.lua | — |

### Phase 3: 提交/回滚 + SQL 日志 (Step 33)

| 子任务 | 产出 | 测试先行 |
|--------|------|---------|
| `test_edit_commit.lua` — DML 生成 + SQL 日志测试 | 测试文件 | — |
| `edit_commit.lua` — `generate_dml()` / `commit_edits()` / `rollback_edits()` | `edit_commit.lua` | ✅ |
| `edit_commit.lua` — 提交后写 sql_log.jsonl | `edit_commit.lua` | — |
| `sql/init.lua` — 手动 SQL 执行后写 sql_log.jsonl | `init.lua` | — |
| `buffer.lua` — commit/rollback 集成 | `buffer.lua` | — |

### Phase 4: 撤消 (P2)

| 子任务 | 产出 | 测试先行 |
|--------|------|---------|
| `test_editor_undo.lua` — 撤消逻辑测试 | 测试文件 | — |
| `editor.lua` — `undo_last_edit()` | `editor.lua` | ✅ |
| `buffer.lua` — `u` keymap | `buffer.lua` | — |

---

## 七、测试策略

### Lua 单元测试 (TDD)

新建 `tests/` 下测试文件：

```
tests/sql_editor_spec.lua   -- 全覆盖本章所有 UT1-UT10
```

运行方式：
```bash
busted tests/sql_editor_spec.lua
```

测试内容覆盖：
- `parse_value()` 的 6 种输入类型转换
- `validate_value()` 对 int/bool/date/uuid/json 的合法/非法输入
- `is_editable_field()` 对所有已知列类型返回正确值
- `edit_state` 增/删/改/合并逻辑
- `generate_dml()` 的 UPDATE/INSERT/DELETE 输出（含多端 dialect 引用）
- JSON 格式化/解析

### 手动验收

按照 §5 验收清单逐项测试。使用 `tests/sql/` Docker 环境（PG 15432 / MySQL 13306）中的 `pg-ecommerce` 和 `my-blog` 连接。

---

## 八、风险与注意事项

1. **Raw mode 跳过**：所有编辑入口在最顶层检查 raw mode，不绕行
2. **分页 + 编辑**：dirty 时阻止翻页。编辑状态随 tab 持久化
3. **排序/过滤 + 编辑**：编辑修改的是 `layout.rows`（原始数据），排序/过滤改变 view_indices。dirty 时阻止
4. **并发执行**：提交 WHERE 可能匹配 0 行。失败时保留编辑状态供用户手动处理
5. **大结果集**：>5000 行跳过编辑。edit_state 内存占用可控
6. **事务安全**：最简实现先不做事务包装。多个 DML 逐条执行，失败则停止
7. **无主键表**：UPDATE/DELETE 提交时警告阻止。INSERT 不受影响
8. **二进制列**：不能编辑也不能在提交 SQL 中正确处理。直接跳过
9. **SQL 日志文件膨胀**：JSONL 追加写入不自动轮转。长期使用建议加 `max_lines`/`max_size` 限制（后续 UI 实现时一并处理），或提供 `:PosteClearSQLLog` 命令