# Code Review 2026-09-05 — 全仓质量分析与重构记录

> 视角：正确性之外的第四类审查——代码质量（DRY / 职责 / 可测性 / Neovim 规范）。
> 前置：2026-08-13（F01–F29，已修）、2026-08-30（U1–U8 UI 专题，第一阶段已修）。
> 本轮不复述已修项；先全量数据分析，再按清单重构，全部小步提交、TDD、套件全绿。

---

## 1. 方法与数据

- 全仓 104 个 Lua 文件 / ~21k 行（`wc -l` 排序 + 大文件通读）。
- 覆盖矩阵：模块 basename ↔ `tests/**/<name>_spec.lua` 精确匹配 + 间接引用
  计数（spec 中 `require` 该模块的文件数）。
- DRY 扫描：跨文件同名 `local function` ≥2 处的清单逐一人工比对语义。
- 规范扫描：废弃 API（`nvim_buf_set_option` 等）、guardrails §1 禁止模式
  grep、`vim.keymap.set` 绕过 `ui/keymaps`、autocmd augroup 卫生。

## 2. 本轮已重构（8 个提交）

| # | 问题 | 类别 | 修复 | 验证 |
|---|------|------|------|------|
| R1 | `ui/picker.lua`、`http/import.lua` 使用已废弃的 `nvim_buf_set_option` | Neovim 规范 | 改 `nvim_set_option_value`（mock buffer 兼容，LEARNINGS 2026-07-04） | picker/import spec 全绿 |
| R2 | `error_response` 三份逐字拷贝（graphql/grpc/websocket executor），仅 `metadata.method` 不同 | DRY（guardrail「不容忍第三份同构拷贝」红线） | 收敛到 `http/response.lua` 的 `response.error_response(req, method, msg)`；executor 各留一行偏应用 | 新增 4 用例 + 三套 executor spec 全绿 |
| R3 | `use_ts()` 三处手拷（nav/outline/context_detector），仅 config key 不同、两处重复 parser 检查 | DRY | `ts_query.feature_enabled(feature)` / `enabled_for(buf, feature)`（nil buf = 仅配置，保持原语义）；删掉两处因此死亡的 `state` require | 新增 7 用例；nav/outline/detect_context/folding spec 全绿 |
| R4 | `buffer_setup.lua` 以 `get_keymap + if k then vim.keymap.set` 手写 12 个映射——guardrails §1 点名的禁止模式，也是 `ui/keymaps` 收敛后最后一个漏网面 | Neovim 规范 / DRY | 声明式 spec 表 + `register_all`；原语按约定扩展：`opts.modes`（ask_ai 需 n+x）、修复 `register_all` 无 base_opts 时丢弃 `spec.opts` 的缺陷（均带回归 spec） | ui_keymaps_spec 6 用例 + 全套件 |
| R5 | `http/json.lua`（170 行）**零测试**；且藏着一个真 bug：`get_key_paths` 生成的 `.items[1]` 路径 `_jsonpath_query` 不认（只匹配裸 `[N]` 步骤），用户选内置路径必失败 | 覆盖 / 正确性 | 步骤解析改为 token 序列（key / `[N]` / `[]`），生成器与求值器对称；新增 11 用例 | json_spec 11/11 |
| R6 | `http/curl.lua`（166 行）**零测试**；核心解析器 `parse_curl` 是未暴露 local | 覆盖 / 可测性 | `M.parse_curl = parse_curl`；新增 10 用例（引号剥离、续行符、`-X/-H/-d/--data-raw`、GET→POST 提升、剪贴板为空/解析失败的告警路径） | curl_spec 10/10 |

最终门禁：`./tests/run.sh` exit 0（89 spec 文件全跑）、`luacheck` 69 warnings
（等于重构前基线，0 新增）、guardrails §5.1 grep 清洁。

## 3. 覆盖率结论

- **间接覆盖良好**（≥5 个 spec 引用）：state、describe、vars、cache、run、
  orchestration、scripts、context_detector、import、item_builder 等。
- **本轮清零**：json、curl。
- **接受零直接覆盖**（内容为纯数据/文档，不承载逻辑）：`data.lua`（954 行
  补全数据表，drift 由 `methods_spec` 守护）、`lua_docs.lua`（脚本 API 文档
  串）、`md5.lua`（vendored 算法）、`constants.lua`、`jq_mapping.lua`。
- **后续值得补**（按价值排序）：`import_parser.lua`（294 行，import/run 行
  解析，边界多）、`format_file.lua`（请求格式化，用户可见面）、
  `import_postman/openapi/swagger`（外部格式转换，fixture 驱动成本低）。

## 4. 职责与体量观察（记录，未动大刀）

| 文件 | 行数 | 现状 | 建议 |
|------|------|------|------|
| `http/import.lua` | 1115 | 混合三类职责：指令解析/索引（`parse_import_line`、`build_import_index`）、执行引擎（`execute_run_directive`、`execute_import_via_curl`）、Lua 导入解析（`resolve_lua_imports`、`resolve_lua_keypath` ≈200 行） | 第三类与主流程无共享状态，可拆 `http/lua_import.lua`；前两类间共享 scratch-buffer 逻辑，拆分需先补行为护栏 |
| `http/run.lua` | 801 | pipeline 编排 + 响应处理 + 视图/指示器/历史协调。钩子（executor、`on_progress`）已外移，剩余是真正的编排职责 | 现状可辩护；若继续长，把 `handle_curl_response`/`handle_directive_response` 的响应规范化部分抽 `http/response_flow.lua` |
| `http/format/verbose.lua` | 782 | 渲染（format_*）+ 高亮（apply_verbose_highlights，含 inline virt_text）两职责 | 下次触碰时把 highlights 半拆为 `format/verbose_hl.lua`（同 image/image_meta 先例） |
| `http/data.lua` | 954 | 纯数据表 | 可接受；若继续膨胀再按 header/method/completion 分文件 |
| `state.lua` | 279 | config + 运行时状态 + keymap + log 四合一（2026-08-30 已标 SHOULD） | 维持既有结论：等下一次 config 结构变更有自然拆分窗口 |

## 5. Neovim 规范面（本轮核查结论）

- ✅ 子进程回调统一 `vim.schedule` 包装（新增 executor 沿用）。
- ✅ UI 原语（float/render/text/winbar/keymaps/columns/picker）收敛后无
  绕过；本轮补齐最后两处（buffer_setup、executors 内部无窗口代码）。
- ✅ 选项 API 全部走 `nvim_set_option_value`/`vim.bo`（R1 清除最后三处废弃调用）。
- ✅ autocmd 均有具名 augroup 且 BufDelete 自清理（27 处逐一核对）。
- ⚠️ `vim.validate` 全仓 0 使用——公共 API（`setup(opts)`、executor req）
  可在后续版本渐进加入；非本轮目标。

## 6. 复现/回归

全部重构均为行为保持型（除 R5 为真 bug 修复，带回归 spec）；任何一条可
以单独 revert。提交序列：d627924 → 42ba8fa → e5cb4b5 → 250489e → 9e64cb6
→ 0efb30c。

---

*Code review 2026-09-05 — 分析 + 重构轮（6 项重构、2 个真 bug、21 个新用例）*
