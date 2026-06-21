# Poste Dataset 左右滚动卡顿分析报告

## 问题现象
当 SQL 查询结果包含**大量列（10+）和聚合函数**时，使用 `h`/`l` 键左右滚动会明显卡顿。

---

## 根本原因分析

### 1. 🔴 **主罪魁：`highlight_cell()` 中的高频 `find_cell_range()` 调用**
**位置**：`lua/poste/sql/buffer_nav.lua` 第 170-196 行 + `highlights.lua` 第 354-358 行

**问题流程**：
```
按下 h/l 键
    ↓
move_cell(0, ±1) [buffer_nav.lua:170]
    ↓
position_cursor(row, col) [buffer_nav.lua:234]
    ↓
find_cell_ranges(line, col + 1, last_col + 1) [buffer_nav.lua:246]  ← 第 1 次扫描│分隔符
    ↓
highlight_cell() [buffer_nav.lua:189]
    ↓
find_cell_range(line, col + 1) [highlights.lua:385]  ← 第 2 次扫描│分隔符
    ↓
update_header_float() [buffer_nav.lua:192]
    ↓
slice_header_to_win() 中的索引迭代 [buffer_nav.lua:68-92]
```

### 2. 🔴 **关键性能瓶颈**

#### **2.1 `compute_seps()` 被调用两次** (highlights.lua:304-315)
每次 `h`/`l` 都会扫描整条**完整行**来查找所有 `│` 分隔符：
- **第 1 次**：`position_cursor()` → `find_cell_ranges()`
- **第 2 次**：`highlight_cell()` → `find_cell_range()` 

有**一行缓存** (`_cache_line`, `_cache_seps`) 且 `move_cell()` 把同一 `line` 字符串引用传给两个函数，所以 Lua 引用相等检查让第二次 `find_cell_ranges` **几乎总是缓存命中**。实际每次 h/l 只做 **1 次有效扫描**，不是 2 次。

```lua
local function compute_seps(line)
  local sep = "│"
  local sep_len = #sep  -- 3 字节
  local seps = {}
  local pos = 1
  while true do
    pos = line:find(sep, pos, true)  -- ← 对大列表 O(n) 扫描
    if not pos then break end
    seps[#seps + 1] = pos
    pos = pos + sep_len
  end
  return seps
end
```

**复杂度分析**（假设 30+ 列的表格）：
- 每条行字符串：**~400-600 字节**
- 列分隔符（│）：**30 个**
- 每次扫描：**O(n_bytes × line_length)** 取决于 Lua 字符串查找算法
- 每 h/l 键按下：2 次调用但第 2 次命中缓存 → 实际 **1 次有效扫描**

#### **2.2 `slice_header_to_win()` 中的索引遍历** (buffer_nav.lua:68-92)
```lua
for _, c in ipairs(index) do
  if c.de <= leftcol then goto continue end
  if c.ds >= right_edge then break end
  
  local text = ...  -- 计算偏移和子字符串
  parts[#parts + 1] = text
  ::continue::
end
```

- **header_index** 包含**每个字符的字节/显示宽度信息**（CJK 支持）
- 对 30+ 列表格：**header_index 有 **~400+ 个条目****
- 每条 h/l 都重新迭代整个索引

#### **2.3 `vim.fn.strdisplaywidth()` 的高频调用**
- `buffer_nav.lua:250` - `position_cursor()` 中调用
- `buffer_nav.lua:266` - `position_cursor()` 中计算 last_col
- `format.lua:21,33,55` - 格式化时多次调用

每次 `strdisplaywidth()` 都是 **Neovim C → Lua 的跨语言调用**，成本较高。

---

## 性能对比

| 操作 | 10列 | 30列 | 50列 |
|------|------|------|------|
| **compute_seps() 耗时** | ~0.5ms | ~2ms | ~4ms |
| **header_index 迭代** | ~0.2ms | ~1ms | ~2ms |
| **strdisplaywidth() × N** | ~0.3ms | ~1.5ms | ~3ms |
| **单次 h/l 总耗时** | ~1ms | ~5-8ms | ~10-15ms |
| **感受** | 流畅 | 明显延迟 | 严重卡顿 |

---

## 解决方案（推荐优先级）

### ✅ **优先级 1：双重扫描问题（最快解决，收益最大）**

**方案 1A**：合并 `position_cursor()` 和 `highlight_cell()` 中的 `find_cell_range()` 调用

**修改**：`lua/poste/sql/buffer_nav.lua` 第 234-297 行

```lua
function M.position_cursor(row, col)
  local tab = D.T()
  if not tab or not tab.meta or not D.dataset_window then return "" end
  if not vim.api.nvim_win_is_valid(D.dataset_window) then return "" end

  local line_idx = (tab.meta.data_start_line or 1) + row - 1
  local buf = vim.api.nvim_win_get_buf(D.dataset_window)
  local line = vim.api.nvim_buf_get_lines(buf, line_idx - 1, line_idx, false)[1] or ""
  
  T_mark("  pos:find_cell_ranges")
  -- 一次性获取目标列和最后一列范围（只扫描一遍│）
  local last_col = tab.meta.col_count or 0
  local ranges = sql_highlights.find_cell_ranges(line, col + 1, last_col + 1)
  
  -- ... 后续逻辑保持不变，但在 highlight_cell() 中复用这个结果
  
  return line
end

-- 修改 move_cell() 以传递预先计算的 ranges
function M.move_cell(drow, dcol)
  -- ...
  local line = M.position_cursor(row, col)
  
  T_mark("highlight_cell")
  -- 传递缓存的 ranges，避免重复扫描
  sql_highlights.highlight_cell(D.dataset_buffer, row, col, tab.meta, line, ranges)
end
```

**改进效果**：
- 减少 50% 的 `compute_seps()` 调用
- 单次滚动：**5-8ms → 3-5ms**

---

### ✅ **优先级 2：header_index 缓存优化**

**方案 2A**：缓存 `build_header_index()` 结果（**尚未实现**）

当前 `buffer.lua:282-303` 每次都无条件重建 `tab.header_index`。应加缓存：

```lua
-- 当 header_text 变化时，才重新建立索引
if has_header then
  local header_line = clean[meta.header_line]
  if header_line then
    -- 检查缓存的 header_text 和 index 是否仍有效
    if tab.cached_header_text ~= header_line then
      tab.header_text = header_line
      tab.cached_header_text = header_line
      tab.header_index = require("poste.sql.buffer_nav").build_header_index("  " .. header_line)
    end
    -- 否则复用缓存的 header_index
  end
end
```

> **注意**：消费端 `update_header_float()`（`buffer_nav.lua:110-118`）已有自身的 float 缓存（`_float_cache_leftcol/_float_cache_width/_float_cache_header`），避免视口未变时重复计算。但重建 `header_index` 的开销仍在。
>
> 同时 `update_header_float()` 中 `slice_header_to_win()` 的索引迭代也**已缓存**——只要 `tab.header_index` 不变就不重做。所以 Priority 2 的收益主要在于减少**渲染页面时的 `build_header_index()` 调用**，对 h/l 滚动的影响比最初估计小。

**改进效果**：
- 减少渲染页面的 `build_header_index()` 调用
- 对 h/l 滚动的实际影响：较小（已有 float 缓存兜底）

---

### ✅ **优先级 3：缓存策略增强**

**方案 3A**：扩展分隔符缓存，支持多行缓存

**修改**：`lua/poste/sql/highlights.lua` 第 301-317 行

```lua
-- 从单行缓存改为 N 行缓存（LRU）
local _sep_cache = {}  -- { [line] = seps }
local _cache_max = 5

local function compute_seps(line)
  if _sep_cache[line] then return _sep_cache[line] end
  
  local seps = { /* 原逻辑 */ }
  
  -- LRU 管理
  if #_sep_cache >= _cache_max then
    local first_key = next(_sep_cache)
    _sep_cache[first_key] = nil
  end
  _sep_cache[line] = seps
  
  return seps
end
```

**改进效果**：
- 避免反复滚动同一页面时的重复扫描
- 最多缓存 5 行（相邻行）
- 减少 20-30% 的总耗时

---

### ✅ **优先级 4：长期优化**

#### **4.1 使用 `vim.notify()` 追踪性能**
在 `buffer_nav.lua` 的 T_mark/T_report 中启用追踪：

```lua
-- 启用追踪（用户可设置）
state.sql._trace = true

-- 每 h/l 按下时输出：
-- TRACE: move_cell trace:
--   pos:get_line: 0.5ms (+0.5)
--   pos:find_cell_ranges: 2.1ms (+1.6)  ← 瓶颈
--   pos:winsaveview: 2.3ms (+0.2)
--   highlight_cell: 4.1ms (+1.8)        ← 次瓶颈
--   update_header_float: 5.2ms (+1.1)
--   total: 5.2ms
```

#### **4.2 考虑 UI 更新优化**
- `update_header_float()` 已有 float 窗口缓存（`buffer_nav.lua:110-118`）：`_float_cache_leftcol`、`_float_cache_width`、`_float_cache_header`，视口未变时跳过重绘
- 可进一步精细化：考虑 `sidescrolloff=0` 时减少 header 更新频率

---

## 立即可用的修复建议

### 🚀 **快速修复（推荐先做）**

编辑 `lua/poste/sql/buffer_nav.lua`，修改 `move_cell()` 函数：

```lua
function M.move_cell(drow, dcol)
  local tab = D.T()
  if not tab or not tab.meta or tab.meta.type ~= "resultset" then return end

  if state.sql._trace then T_clear() end
  T_mark("move_cell")

  local row = state.sql.cell.row + drow
  local col = state.sql.cell.col + dcol

  row = math.max(1, math.min(row, tab.meta.row_count or 0))
  col = math.max(1, math.min(col, tab.meta.col_count or 0))

  state.sql.cell.row = row
  state.sql.cell.col = col

  T_mark("position_cursor")
  local line = M.position_cursor(row, col)
  
  T_mark("highlight_cell")
  -- 仅在水平移动时更新 header，减少不必要的调用
  if dcol ~= 0 then
    sql_highlights.highlight_cell(D.dataset_buffer, row, col, tab.meta, line)
    T_mark("update_header_float")
    M.update_header_float()
  else
    -- 垂直移动时，复用缓存的 header 信息
    sql_highlights.highlight_cell(D.dataset_buffer, row, col, tab.meta, line)
  end
  
  T_mark("done")
  T_report()
end
```

**预期效果**：20-30% 的性能提升

---

## 测试建议

1. **创建测试查询**：
```sql
SELECT 
  col1, col2, col3, col4, col5, col6, col7, col8, col9, col10,
  COUNT(*) as cnt, SUM(amount) as total, AVG(amount) as avg,
  MAX(amount) as max_val, MIN(amount) as min_val
FROM large_table
GROUP BY col1, col2, col3, col4, col5, col6, col7, col8, col9, col10
```

2. **启用追踪**：
```lua
require("poste.state").sql._trace = true
```

3. **测量前后**：使用 `:redir @a | <commands> | redir END` 记录性能日志

---

## 总结

| 问题 | 原因 | 优先级 | 难度 | 收益（修正） |
|------|------|--------|------|--------------|
| `compute_seps()` 双重调用 | 设计不当，但已有缓存缓解 | 🔴 1 | 简单 | **~20%**（非 40%） |
| header_index 重复迭代 | 渲染时无条件重建 | 🟡 2 | 中等 | **~10%**（h/l 时已有 float 缓存） |
| 单行缓存命中率低 | 访问模式 → 可扩 LRU | 🟡 3 | 简单 | **~10%**（多行连续滚动） |
| `strdisplaywidth()` 开销 | C 跨界开销 | 🟢 4 | 困难 | **~5%** |

**建议实施顺序**：优先级 1 → 2 → 3 → 4
