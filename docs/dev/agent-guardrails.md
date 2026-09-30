# Agent Guardrails — 硬约束与事故清单

> 写给在本仓库工作的 AI agent（对人类贡献者同样有效）。
> 每条规则都来自真实事故，标注出处；开工前先读 `AGENTS.md` 与 `LEARNINGS.md`，
> **写 UI 代码或写测试之前**必读本文件。
> 维护约定：新踩的坑 → 先进 `LEARNINGS.md`；若它反映的是「流程会反复诱导犯错」
> 而非一次性失误，再升级为这里的规则。

规则分级：

- **MUST（硬规则）**：违反视为实现错误，review 直接打回。§5 的 grep 自检可机检。
- **SHOULD（默认规则）**：偏离时必须在提交说明里写明理由。

---

## 1. UI 渲染 MUST 走 `lua/poste-http/ui/` 原语，禁止手搓

**事故（2026-08-30，`code-review-2026-08-30.md`）**：`ui/` 只有 `columns.lua` 时，
9 处浮窗样板守卫完备度分三档——`help.lua` 打开失败不清理 buffer、`image.lua`
连 `pcall` 都没有、只有 `select.lua` 有 WinClosed 兜底；截断有 5 套实现 3 种语义
（outline/inspector 是字节级，CJK 被切碎）；method→高亮映射 4 份且已漂移
（outline/symbols 不认识 OPTIONS/SCRIPT）。**样板复制必然漏守卫、映射必然漂移。**

| 要做的事 | 必须用 | 禁止手写 |
|---|---|---|
| 浮窗 | `ui/float.open` | `nvim_open_win` + 手写居中/q 键/失败清理/WinClosed |
| 写行进 buffer | `ui/render.set_lines` | modifiable 三连（历史 bug：漏半截 → 空分支不渲染） |
| 显示截断 | `ui/text.truncate` / `ui/text.middle` | `#s` 字节截断、`strchars` 字符截断 |
| method/status 高亮 | `ui/semantics.method_hl` / `status_hl` | 就地写映射表（已经漂移过 4 份） |
| winbar tab 行 | `ui/winbar.render_tabs` / `cycle` | 手拼 `TabLineSel` 字符串 |
| 键位注册 | `ui/keymaps.register(_all)` | `get_keymap + if k then keymap.set` 逐条手写 |
| 列对齐 | `ui/columns.render` | `string.format("%-8s")` 拼列 |
| 兜底选择器 | `ui/picker.open` | 复制一份搜索/导航/关闭兜底逻辑 |
| 用户提示 | `ui/notify.notify` | 直接调 `vim.notify`（§5.1 可机检） |

```lua
-- ❌ 禁止：手搓浮窗（守卫一定会漏——历史上 9 处漏了 3 种）
local ok, win = pcall(vim.api.nvim_open_win, buf, true, {
  relative = "editor", width = w, height = h,
  row = math.floor((vim.o.lines - h) / 2), col = math.floor((vim.o.columns - w) / 2),
  style = "minimal", border = "rounded", title = t, title_pos = "center",
})

-- ✅ 正确：守卫（失败清理、close keymap、on_close、无 title 回退）在原语里
local buf, win = float.open({ width = w, height = h, title = t, on_close = cleanup })
```

需要原语没有的能力时，**扩展原语并补测试**（如 `close_keys = {}`、`win_opts`、
`base_opts` 都是这么加的），不要绕过它。

### 1.1 消息文案风格（`ui/notify` 契约，2026-09-30 收敛）

**事故（2026-09-30 review）**：113 处 `vim.notify` 直接调用沉淀出 7 种前缀
（`[Poste]`/`Poste:`/`poste:`/`poste-http`/`PosteHttp`/`[poste]`/无前缀）×
4 种 title 写法，`run.lua` 自己就混两种。归属信息忽隐忽现，noice/fidget 用户
无法按插件过滤。

- **归属由 title 承担**（`constants.NOTIFY_TITLE`），消息正文是裸句子，禁止
  任何前缀。确需子场景区分时用 `opts.title` 覆盖。
- **wrapper 不改写正文**（NUL 清理 + 200 列截断除外）：句首大写由调用点负责；
  行首工具名/占位符（`jq error`、`{{var}}`）保持原样——自动大写会把
  "jq error" 变成 "Jq error"。
- **level 判定**：状态告知/成功回执 = INFO；前置条件不满足、用户取消、可恢复
  降级 = WARN；操作执行失败（请求、导入、脚本、外部命令）= ERROR。
- **notify 与 state.log 互不重复**：`ui/notify` 已自动镜像进 log sink，调用点
  不要再对同一条消息手写 `state.log`；反过来纯诊断信息（用户不需要看）直接
  `state.log`，不要 notify。
- **禁止静默失败**：任何走到 `callback(false/nil)` 的失败分支必须已有调用点
  侧 notify（批处理路径逐项 notify 视为已覆盖），只打错误指示器不算提示。

---

## 2. 分层 MUST：`format/` 只做「响应体 → 行数据」

**事故（U6）**：`format/image.lua` 涨到 682 行，混了内容类型表、第三方渲染适配、
URL 下载+缓存（网络 I/O）、浮窗 UI 四种职责。

- `http/format/` 内禁止：网络请求、磁盘缓存、`nvim_open_win`、临时文件管理。
  这类基础设施放独立模块（参照 `http/image_cache.lua`）。
- 窗口代码不进 `http/` 业务模块（AGENTS.md 原有约定，`ui/float.lua` 是唯一例外）。
- 新文件超过 ~500 行、或一个文件里能数出 ≥3 种职责时，先拆再继续加功能。

---

## 3. Lua 语言陷阱（本次实撞，必读）

### 3.1 局部名遮蔽 require 的模块

**事故**：`outline.lua` 有本地函数 `render`，新加的
`local render = require("poste-http.ui.render")` 被它遮蔽，运行时炸
`attempt to index upvalue 'render' (a function value)`，测试才暴露。

- **MUST**：require 一个模块前，先看本文件是否已有同名 local（函数或变量）；
  冲突时用别名（`local ui_render = require(...)`）并注释原因。

### 3.2 pcall 截断多返回值

**事故**：`pcall(function() return float.open(...) end)` 只拿到第一个返回值
（buf），把 buf id 当 window 去关，窗口关不掉、测试失败。

```lua
-- ❌ 只拿到 buf
local ok, out_win = pcall(function() return float.open(opts) end)
-- ✅ 显式收窄到需要的值
local ok, out_win = pcall(function()
  local _, w = float.open(opts)
  return w
end)
```

- **MUST**：对返回多值的函数做 pcall 包裹时，显式写出你要的那几个值。

### 3.3 通过 `M.` 动态调用的函数才能被测试打桩

**事故（U6 迁移时规避）**：`http_image_preview_spec` 直接给
`image_mod.download_image_url` 赋桩函数；若调用方在模块加载时绑定
`local download = image_cache.download_image_url`，桩将失效。

- **MUST**：模块内调用自身可被替换（测试打桩）的函数时，一律经 `M.fn(...)`
  动态派发，不提前绑定 local。

---

## 4. 测试 MUST（headless 实撞清单）

| # | 规则 | 事故 |
|---|---|---|
| T1 | **feedkeys 逐键喂**：一次 `feedkeys("jj<CR>", "mx")` 会与排队中的 `startinsert!` 竞争，第二个键被吞。每键一次 feedkeys + `vim.wait` | picker 规格第一次跑挂 |
| T2 | **headless 不真正进 insert 模式**。要测 TextChangedI 搜索路径，直接改搜索行 + `doautocmd TextChangedI` 驱动真实回调 | 过滤断言 3≠1 |
| T3 | **`PlenaryBustedFile` 不加载 `minimal_init`**，依赖 `helpers.*` 的 spec 只能经 `tests/run.sh`（目录模式）验证；单文件跑报 `module 'helpers.mock_nvim' not found` 不是被测代码的锅 | U6 验证时误判 |
| T4 | **`vim.v.shell_error` 只读**。模拟命令失败用 `saved_system({ "false" })` 跑真 `false` 命令 | image_cache 规格跑挂 |
| T5 | **API 形状**：`nvim_buf_get_keymap` 的 lhs 是字面量 `"<Esc>"` 不是 `"\27"`；`nvim_win_get_config().title` 是 chunk 表 `{{text}}`；`relative="editor"` 的 `row/col` 是数字。断言前先探针确认形状 | ui_float 规格 3 处误判 |
| T6 | **断言实现契约，不要凭想象写期望值**。写断言前读被测函数的文档注释（如 `ui/text.truncate` 是「占满预算」语义：`max-1` 宽内容 + 省略号） | truncate 期望值写错 2 处 |
| T7 | **`helpers.gui_harness` 的 `strdisplaywidth` 桩是字节版**（`#s`）。显示宽度相关的行为不要在 harness 下断言精确值，用真实 nvim 规格（`tests/ui_*_spec.lua` 风格） | 迁移时规避 |

TDD 流程（AGENTS.md 原有约定）不变：先写 spec 跑出 red（通常是 module not found），
实现后 green；bug fix 必带能抓住它的回归测试。

---

## 5. 收工自检（MUST 全部通过）

### 5.1 UI 硬规则 grep（命中 = 违规，除非在允许清单里）

```bash
# 浮窗只允许 ui/float.lua 创建
grep -rn "nvim_open_win" lua/ | grep -v "lua/poste-http/ui/float.lua"
# modifiable 三连只允许 ui/render.lua（buffer.lua 的 get_response_buffer 里
# 创建时锁一次属合法）
grep -rn 'nvim_set_option_value("modifiable"' lua/ | grep -v "ui/render.lua\|http/buffer.lua"
# method/status → 高亮映射只允许语义模块与高亮定义处
grep -rln "PosteMethodGET\|PosteStatus2xx" lua/ | grep -v "ui/semantics.lua\|http/highlights.lua"
# winbar 拼接只允许 ui/winbar.lua
grep -rln "TabLineSel" lua/ | grep -v "ui/winbar.lua"
# 字符级截断原语只允许 ui/text.lua 与 ui/columns.lua
grep -rln "strcharpart\|strchars(" lua/ | grep -v "ui/text.lua\|ui/columns.lua"
# 用户提示只允许 ui/notify.lua 触达 vim.notify（tests/run.sh 已内置此门禁）
grep -rn "vim\.notify" lua/ | grep -v "lua/poste-http/ui/notify.lua"
```

以上清单 = 2026-08-30 收敛后的合法残留。**新增命中必须走 ui/ 原语**；确需第
二处时先扩展原语并更新本清单。

### 5.2 验证三件套

1. `./tests/run.sh` 的 **exit code 必须为 0**——不要只看每个 spec 的
   `Failed : 0`：曾有「逐 spec 全 0 但 exit=1」的情况，真因是另一个 spec
   加载失败。`grep -c "Testing:"` 应等于 spec 文件总数，少了就是有文件没跑。
2. `luacheck lua/` **0 errors 且无新增 warnings**（当前基线 70 条，见
   `code-review-2026-08-30.md` §5）。
3. 涉及浮窗/视图的改动，headless 冒烟真实打开一次（help/outline/history/
   inspector/body+verbose 视图，参照 review 报告 §5 的冒烟脚本）。

### 5.3 提交纪律

- 一个 phase（一个 review 条目）一个 commit，不跨条目混合——与 2026-07
  重构计划的「每个 Phase 独立可回退」一致。
- 改完代码同步更新：`docs/dev/file-index.md`（新模块）、`LEARNINGS.md`
  （新坑）、对应 review 报告的条目状态。文档漂移本身就是 2026-08-13 审查
  的一整类发现（D01–D17）。

---

## 6. 写新代码前的 SHOULD

1. **先 grep 再写**：新增任何工具函数（截断、居中、keymap 读取、时间格式化…）
   前，先 `grep -rn` 全仓库确认没有现成实现——ui/ 五组件就是「先写后发现重复」
   的翻车结果。
2. **复制粘贴超过 ~10 行即视为需要抽公共模块**，尤其是带守卫的样板。
3. 两处实现「逻辑同构、仅参数不同」时（winbar、tab 切换、importer 交互流），
   抽参数化原语，不要容忍第三份拷贝出现。
4. 给 `lua/poste-http/ui/` 加原语时遵守其约定：纯函数优先、无隐藏模块级可变
   状态、几何/解析部分可 headless 单测；窗口原语（float）保持薄。

---

*来源：`docs/dev/code-review-2026-08-30.md`（U1–U8）及同日重构过程。
维护人：每次违反本文件的事故，修完后在此标注条目号。*
