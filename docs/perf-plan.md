
# Dataset 性能优化计划与观测脚本

---

## User

阅读dataset相关的代码，制定一个性能优化计划，目标是优化 dataset buffer 在大数据量时执行页面横向纵向、分页等操作时的性能消耗，计划中要包含一个前置步骤：写一段可以模拟大数据量场景下对 dataset 各种操作时的性能指标观测脚本。方便对比性能优化成果。


---

## Dataset 性能优化计划

### 第一步：前置性能观测脚本

**文件**: `tests/bench_dataset.lua`

设计一个可通过 `nvim --headless` 独立运行的 benchmark 脚本，核心方案：

**数据生成**: 用 Lua 构造多组 mock 数据 (`data.results[1].rows`):
- 规模: 100, 1K, 10K, 50K, 100K 行
- 列宽: 5, 10, 20 列（含文本、数字、NULL、JSON 等类型）
- 每列宽度从 `"a"` 到 `"value_xxxxx"` 不等（模拟真实长文本场景）

**采集指标**: 对每一组数据采集以下操作的耗时（`vim.loop.hrtime()`）:
| 操作 | 触发函数 | 高频场景 |
|------|----------|----------|
| 渲染耗时 | `format.format_resultset()` | 初始查询 |
| 高亮耗时 | `highlights.apply_dataset_highlights()` | 每页渲染 |
| 全量 buffer 写入 | `nvim_buf_set_lines()` | 页面渲染 |
| 纵向移动 1 行 | `move_cell(1,0)` | `j` 键 |
| 横向移动 1 列 | `move_cell(0,1)` | `l` 键 |
| 跳转首/末列 | `goto_first_col/goto_last_col` | `0`/`$` 键 |
| 跳转首/末行 | `goto_first_row/goto_last_row` | `gg`/`G` 键 |
| 翻页 (prev/next) | `prev_page/next_page` | `H`/`L` 键 |
| 跳转首末页 | `goto_first_page/goto_last_page` | `<leader>hh`/`<leader>ll` |
| 排序 | `sort_by_current_col()` | `s` 键 |
| 搜索全表 | `show_search()` callback | `/<leader>/` |
| 搜索匹配高亮 | `apply_search_highlights()` | `n`/`N` 键 |
| 按值过滤 | `filter_by_current_cell()` | `<leader>ce` |
| 预览单元格 | `preview_cell()` | `K` 键 |
| Header float 更新 | `update_header_float()` | 每次横移 |

**输出格式**: 生成 JSON 文件，含每项操作的 min/max/avg 耗时及标准偏差，支持 `--compare` 参数对比 baseline 和优化后的结果。

**注意**: 由于 `format_resultset()` 和 `apply_dataset_highlights()` 是全量扫描所有行，脚本应采集 **关闭分页时的全量数据** 和 **开启分页时的数据** 两组基线。

---

### 第二步：优化项（按优先级排列）

#### P0 - 页级格式化（最大收益）

**问题**: `format_resultset()` 始终格式化所有行，即使只显示一页。分页切片在 `render_dataset()` 中才发生 (buffer.lua:252-268)。

**方案**: 让 `format_resultset()` 支持 `page/page_size` 参数，只格式化当前页所需行。核心涉及：
1. `format.lua:calc_column_widths()` — 只需扫描当前页行 → column widths 足够
2. `format.lua:format_resultset()` — 接受 `page/page_size` 参数，只渲染目标页的行
3. `buffer.lua:render_dataset()` — 调用时传递分页参数，消除后续 `padded_full` 的 `vim.deepcopy` 和切片逻辑
4. `buffer_search.lua:show_search()` — 搜索仍需全表扫描，不在此限

**预期**: 100K 行 × 10 列场景，渲染时间从 **O(100K)** 降至 **O(page_size)**（通常 50）。

#### P1 - 高亮延迟化

**问题**: `apply_dataset_highlights()` 全量扫描所有数据行，每行做 `find_cell_range()` + NULL 扫描 + 写入 extmark。

**方案**: 
1. **语法代替 extmark**: NULL 已由 `syntax/poste_dataset.vim` 中的 `PosteDatasetNull` 覆盖，行号列同理。移除 `apply_dataset_highlights()` 中的数据行高亮逻辑，仅保留 border/header 的 extmark 高亮
2. 如果必须保留 extmark：只对可见行（window 内的行）应用，而不是 `tab.padded` 所有行
3. 新增 `vim.schedule()` 延迟：render 时先写 buffer，再 schedule 高亮

**预期**: 100K 行场景，高亮阶段从 **10-50ms** 降至 **<2ms**（仅几行 border）。

#### P2 - find_cell_range 缓存优化

**问题**: `position_cursor()` 和 `highlight_cell()` 在每次 `j/k/h/l` 时都调用 `find_cell_range()`。该函数有 one-entry cache，但：
- `position_cursor()` 调用 2 次 `find_cell_range()`（目标列 + 最后列检测）
- `nvim_buf_get_lines()` 返回的字符串每次是新分配 → `==` 比较失败 → cache miss

**方案**:
1. `position_cursor()` 中传入已提取的 `line` 给 `highlight_cell()`，避免二次取行
2. 合并两次 `find_cell_range` 调用：一次扫描算出当前列和末列范围
3. 增强 cache 用 `line_idx` 做 key（或直接缓存 `(buf, row, col)` 结果）

**预期**: 每 keystroke 减少 1-2 次完整的行扫描。

#### P3 - Header Float 复用

**问题**: `update_header_float()` 在每次 `h/l` 移动时销毁并重建 float window（`close_header_float()` + `nvim_open_win()`），同时全量运行 `slice_header_to_win()`。

**方案**: 
1. 复用 float win/buf：只做 `nvim_buf_set_lines()` 更新内容，不销毁/重建
2. `slice_header_to_win()` 缓存 `padded_header` 和 `index`，避免在 `h/l` 时重建 header_index
3. 在 `render_dataset()` 中一次性构建 `header_index`，存入 tab

**预期**: 水平移动延迟从 **0.5-2ms** 降至 **<0.1ms**。

#### P4 - vim.deepcopy 消除

**问题**: 
- `render_dataset()` 中 `vim.deepcopy(padded)` → 全量复制所有行
- `sort_by_current_col()` 中 `vim.deepcopy(data)` → 全量复制数据
- `filter_by_current_cell()` 中 `vim.deepcopy(original_data)` → 全量复制数据

**方案**: 
1. 将 `padded_full` 改为引用 `padded`（只在分页时复制切片）
2. Sort 和 Filter 的 deepcopy：只在必要时复制（首次 sort 时备份 `original_rows` 已做到部分；filter 的 `original_data` 同理）
3. 引入**写时复制**模式：用 metatable 代理读取，只在写时复制

**预期**: 100K 行场景节省 **2-5MB** 内存分配 + 对应 GC 时间。

#### P5 - 搜索性能优化

**问题**: `show_search()` 回调中搜索全量数据（O(n_rows * n_cols)），即使当前只显示一页。

**方案**: 
1. 默认搜索当前页，提供选项扩展至全表
2. 搜索循环中的 `tostring(val)` 调用是 Lua 中较慢的操作——对于数字和布尔值可以跳过 `:lower():find()` 检查
3. 缓存匹配结果的行号到分页映射，避免 `jump_to_search_match` 中的页计算

#### P6 - WinScrolled / WinResized autocmd 节流

**问题**: `WinScrolled` 和 `WinResized` 在拖动分屏时频繁触发 `update_header_float()`，导致 float window 频繁重建。

**方案**: 使用 `vim.defer_fn` 或 throttle 机制（100ms 的去抖），避免高频触发。

---

### 实施顺序建议

```
Step 1: 基准测试脚本 [当前任务]
  └── 建立可重复的性能基线
Step 2: P0 - 页级格式化 [最大 ROI]
  └── 改 format_resultset + render_dataset
  └── 用脚本验证加速比
Step 3: P2 - find_cell_range 优化 [每按键延迟]
Step 4: P1 - 高亮延迟化 [次大 ROI]
Step 5: P3 - Header Float 复用 [水平移动体验]
Step 6: P4/P5/P6 按需实施 [增量改进]
```

在开始 Step 2 之前，建议先确认是否同意上述优化思路和优先级。有什么需要调整的？

---

