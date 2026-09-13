# Poste HTTP 架构审视报告 — UI 渲染层专题

> 审视日期：2026-08-30
> 基准 commit：`1bfb992`（2026-08-13 审查 F01–F29 已全部修复之后的干净基线）
> 视角：高级架构师复检。本轮不再重复上一轮的正确性问题清单，聚焦一个结构性问题：
> **UI 渲染代码是否需要沉淀一套通用组件？**
> 结论先行：**需要，且当前重复度已经到了会持续制造 bug 的程度。** 本轮已实施第一阶段重构（U1–U5）。

---

## 1. 现状：`ui/` 只有半块积木

`lua/poste-http/ui/columns.lua`（2026-08 引入）确立了正确方向：纯函数、无窗口、可单测、
display-width 感知（CJK 安全）。file-index.md 也把它定位为「standalone Neovim UI component
library 的种子」。

但种子之后没有继续生长。各 UI 消费方（history / outline / variable_inspector / select /
help / image / commands / buffer / view）在 `columns` 之下各自手搓了同样的底层动作。
本轮逐文件核实的重复分布如下。

## 2. 发现清单

### U1 【P1｜已重构】浮窗创建样板 ×9，含 3 处行为不一致

`pcall(nvim_open_win, …)` 调用点（grep 核实）：

| 调用点 | 边框 | 关闭兜底 | 失败清理 | 备注 |
|---|---|---|---|---|
| `http/history.lua:646,668`（list+detail 两窗） | single | buf_attach on_detach | 有 | 双窗坐标手工计算 |
| `http/variable_inspector.lua:316` | rounded | 仅 q/Esc keymap | 有 | 带「title 不支持则去掉重开」重试 |
| `http/outline.lua:416` | rounded | 仅 q keymap | 有 | |
| `select.lua:72`（pick_float） | rounded | WinClosed 兜底（F14 修复加入） | 有 | |
| `help.lua:97` | rounded | 仅 q/Esc keymap | **无**（失败直接 return，buf 泄漏） | |
| `commands.lua:89`（ImportResolve） | single | buf_attach on_detach | 有 | |
| `http/format/image.lua:631` | rounded | 仅 q/Esc keymap | **未 pcall**，open_win 抛错会直接炸到调用栈 | 无 WinClosed → 用户 `:q` 关窗后 `image_preview_state.float_win` 留 stale 引用 |

同一件事（居中浮窗 + scratch buffer + q 关闭）写了九遍，且兜底完备度三个档次——
help.lua 失败不清理、image.lua 干脆不 pcall、只有 select.lua 有 WinClosed 兜底。
这正是「样板代码不沉淀组件」的典型代价：**晚写的复制了早写的大部分，但漏掉了谁记得住的守卫**。

### U2 【P1｜已重构】「写行进 buffer」样板 ×10

`modifiable=true → nvim_buf_set_lines → modifiable=false` 三连出现在
`history.lua` ×5、`view.lua` ×1、`buffer.lua` ×1、`json.lua` ×2、`outline.lua` ×1。
上一轮 LEARNINGS 记录的 `http/history-empty-list` bug（空分支漏走同一渲染路径），
根源就是这个样板没有收敛成一个函数——每次手写都有机会漏半截。

### U3 【P1｜已重构】文本截断五套实现，三种语义互不一致

| 实现 | 度量 | 省略号 | CJK 安全 |
|---|---|---|---|
| `ui/columns.lua:54` truncate | display-width | `...` | ✅ |
| `http/outline.lua:15` ellipsis | **字节**（`#s <= max`） | `…` | ❌ 中文路径提前截断/切碎 |
| `http/symbols.lua:24,30` truncate_middle/truncate | 字符数（strchars） | `…` | ⚠️ 字符≠显示宽，中文对不齐 |
| `http/variable_inspector.lua:181` middle_ellipsis | **字节** | `...` | ❌ |

variable_inspector 的表格明明经过了 columns（CJK 对齐修好了），但它的 value/location
列在进 columns **之前**先被自己的字节版 middle_ellipsis 预截断——CJK 值在错误的位置
被切，随后列对齐又按错误的宽度算。修了下游忘了上游，是重复实现必然产生的「修复不共振」。

### U4 【P2｜已重构】method/status → 高亮组映射 4+2 套，且已漂移

`PosteMethodGET` 映射出现在 history（表）、outline（函数）、symbols（函数）、
verbose.lua（**同一文件里两份逐字相同的内联表** `:687` 与 `:728`）；状态码映射在
history 与 verbose 各一份。漂移证据：

- outline 的映射不认识 `OPTIONS` 和 `SCRIPT`（fallback 成灰色 Other）；
- symbols 认识 `SCRIPT` 但也不认识 `OPTIONS`；
- history 认识 `SCRIPT`；verbose 只到 `OPTIONS`。

高亮组本体在 `highlights.lua` 是单一定义，但「语义 → 组名」的判断逻辑四处各写一份，
新增一个方法（或修 OPTIONS 漏洞）要同步四处。这类表应该和高亮组定义同源。

### U5 【P2｜已重构】winbar tab 行构建两套

`buffer.lua:91-116`（响应窗口）与 `history.lua:254-266`（history 详情窗）各自实现
`get_active_tabs()` + `TabLineSel/TabLine` 拼接，逻辑同构（含 `cycle_tab` 也是两份：
`buffer.lua:216` 与 `history.lua:507`）。

### U6 【P2｜后续】`format/image.lua`（682 行）四种职责混居

内容类型表、snacks/image.nvim 双适配器、URL 下载+缓存（curl、hash、TTL）、浮窗 UI
全在一个文件里。`format/` 目录的定位是「响应体 → 行数据」的纯渲染层，浮窗创建和
网络下载都不是它该管的事。建议后续拆为：`http/image_cache.lua`（下载/TTL/hash）+
`ui/image_preview.lua`（浮窗/inline 适配器调度）。本轮仅将其浮窗创建迁移到 `ui/float.lua`。

### U7 【P3｜后续】`buffer.lua` 职责过宽；view/history 的 tab 模型双份

`buffer.lua` 619 行里约 160 行是 keymap 注册、其余是 winbar、多响应缓存、split 管理、
resize 衡平、图片预览分发。view.lua 与 history.lua 各自维护一套「view id ↔ tab 列表 ↔
切换」模型。方向：keymap 表格化（配置驱动），tab 模型抽 `ui/tabs.lua` 或统一到一处状态机。

### U8 【P3｜后续】`select.lua` 内嵌 80 行通用列表选择器

`pick_float`（模糊过滤 + 上下选择 + 插入模式搜索）是通用能力，candidates：
抽为 `ui/picker.lua` 供 env/import/history 复用。本轮不动（它刚加过 WinClosed 兜底，
行为敏感），仅记录。

### 非本层但顺手记录

- `state.lua` 仍是 god-object（config + 运行时状态 + keymap + log 全在一个模块），
  与 2026-07 重构计划 R7 一致，风险可控，维持「后续」。
- `util.open_doc_preview`（nav/lua_docs 用）与 `ui/float.lua` 有重叠——它基于
  `vim.lsp.util.open_floating_preview`（带自动尺寸/hover 语义），定位不同，保留。

---

## 3. 本轮实施的重构（U1–U5）

新增 `lua/poste-http/ui/` 五个组件，全部遵循 columns.lua 确立的约定
（纯函数优先、无隐藏全局状态、可 headless 单测）：

| 模块 | API | 替代的重复 |
|---|---|---|
| `ui/text.lua` | `truncate(s, max)` / `middle(s, max)` — display-width 感知 | U3 五套截断 |
| `ui/semantics.lua` | `method_hl(method)` / `status_hl(status)` — 唯一映射源 | U4 四套 method 表 + 两套 status |
| `ui/winbar.lua` | `render_tabs(tabs, active_id)` — TabLine 拼接 | U5 两套 winbar |
| `ui/render.lua` | `set_lines(buf, lines, opts)` — modifiable 三连 | U2 十处样板 |
| `ui/float.lua` | `open(opts)` — scratch buffer + 居中 + border/title + q/Esc + WinClosed/on_close 兜底 + 失败清理；`center(w,h)` 纯几何 | U1 九处浮窗 |

迁移的调用点：help.lua、commands.lua(ImportResolve)、variable_inspector.lua、
outline.lua、select.lua、history.lua（list+detail 渲染与 winbar）、buffer.lua（winbar
与 set_lines）、view.lua（pending timer）、json.lua、format/image.lua（浮窗）、
format/verbose.lua（method/status 映射）、symbols.lua。

行为变化（有意为之，均为修复性质）：

1. help.lua / image.lua 的浮窗创建获得失败清理与 pcall 保护（原先无）。
2. outline / symbols / variable_inspector 的截断统一为 display-width 语义，CJK 不再
   被字节切断；省略号统一为 `…`（columns 内部因列规格语义保留 `...`，见其文档注释）。
3. outline/symbols 的 method 高亮补齐 OPTIONS/SCRIPT（原先 fallback 灰色）。
4. `ui/semantics.status_hl` 保留 history 的 `≤0 → Comment` 语义，verbose 使用同一函数。

AGENTS.md 约定更新：`lua/poste-http/ui/` 定位从「纯函数、window-free」调整为
「纯函数组件 + 保留少数薄窗口原语（float），窗口逻辑仍不得散落在 http/ 业务模块」。

## 4. 后续路线（U6–U8 已于同日实施，各为独立 commit）

1. ~~U6：image.lua 拆分~~ **已完成** — 下载/TTL/hash/临时文件与内容类型表迁入
   `http/image_cache.lua`（10 个单测），`format/image.lua` 保留渲染/适配器并重导出，
   format.lua facade 与既有测试打桩方式不变。
2. ~~U8：select.pick_float → `ui/picker.lua`~~ **已完成** — 独立选择器组件，外关路径
   改走 ui/float 的 `on_close`（pattern 版 WinClosed），浮窗创建失败会 resolve(nil)
   而非挂死调用方；select.lua 保留 snacks 优先 + vim.ui.select 异常兜底。
3. ~~U7：buffer.lua keymap 表格化~~ **已完成** — 新增 `ui/keymaps.lua`
   （`register`/`register_all`，统一「config 覆盖默认、false 停用」语义），
   buffer.lua ~160 行 setup_keymaps 与 history.lua 两个 keymap setup 改为数据驱动。
   view/history 的 tab 模型已通过 U5 的 `ui/winbar.lua`（render_tabs/cycle）收敛，
   剩余的 get_active_tabs 差异是两个 surface 各自的状态派生，属合理边界，不再合并。
4. state.lua setter 化（R7，2026-07 计划遗留）：仍开放，待有真实一致性 bug 驱动时再做。

## 5. 验收（已执行）

- TDD：`tests/ui_text_spec.lua`（9）、`tests/ui_semantics_spec.lua`（6）、
  `tests/ui_winbar_spec.lua`（7）、`tests/ui_render_spec.lua`（6）、
  `tests/ui_float_spec.lua`（9）、`tests/http/image_cache_spec.lua`（10）、
  `tests/ui_picker_spec.lua`（8）、`tests/ui_keymaps_spec.lua`（5）先行 red→green，
  共 60 个新用例。
- 全量 `tests/run.sh` 全绿：79 个 spec 文件（grammar/injection 脚本 + Lua 用例），
  exit 0；luacheck 维持基线 70 warnings / 0 errors（本轮 0 新增）。
- Headless 冒烟：help / outline 开关、history 双浮窗、变量检查器、body/verbose
  视图渲染均通过。
- 实施中发现并修正的坑已记入 `LEARNINGS.md`（本地 `render` 函数名遮蔽、
  pcall 截断多返回值、`nvim_win_get_config` 返回形状、headless feedkeys 的
  startinsert 竞争、PlenaryBustedFile 不带 minimal_init）。

---

*本报告聚焦结构与重复度问题。正确性专项见 `code-review-2026-08-13.md`（已全部修复）。*
