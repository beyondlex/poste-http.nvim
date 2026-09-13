# Code Review 2026-08-13 修复跟踪

> 基准：`e0db389` | 来源：`docs/dev/code-review-2026-08-13.md`

## 第一优先级（用户可见的正确性）— 已完成

- [x] F01: 失败请求渲染为成功 — 修 `parse_error` status + `parse_headers_file` 空文件默认
- [x] F02: orchestration 缺 `state` require
- [x] F03+F06: TS 查询层崩溃 (`collect_matches`) + `get_node_text` 不存在
- [x] F05: 异步回调错误兜底 + `_busy` 复位（含 F22）

## 第二优先级（文档/配置对齐）— 已完成

- [x] F09+D01: `require("poste")` → `require("poste-http")`（README + keymaps.md）
- [x] F10: 修 `default_env` 同步，删 `poste_binary`/`split_size`
- [x] D02-D17: 文档漂移清单逐项修

## 第三优先级（测试基建）— 已完成

- [x] F23: 新增 `curl_exec_spec.lua`（stub jobstart）
- [x] F24: 契约测试改名 `contract_spec.lua`
- [x] F25: 删除 SQL 孤儿文件
- [x] F27: `run.sh` 加 `-u NONE` + 参数化 plenary 路径

## 第四优先级（结构性重构）— 已完成

- [x] F12: 块边界收敛到 `describe` 单一来源
- [x] F15: nav 双实现合一
- [x] F20: import.lua 拆分 + importer 交互流去重
- [x] F08: 缓存失效策略（changedtick-only）

---

## 第五优先级（P0 正确性缺陷）

- [x] F04: 依赖链状态跨请求泄漏 — `_chain_dep_set`/`_chain_dep_order`/`request_response_cache` 在 `M.resolve_content_dependencies` 入口重置
- [x] F07: 三个 importer 真实崩溃 — `next(example)` 对标量 schema、`table.concat` 接表、Postman `?` 翻倍、`gsub` 接数字

## 第六优先级（P1 功能损坏/性能）

- [x] F11: `:PosteJqFilter` 已从文档移除；`{{Name.res.body.X}}` 添加 `.res.` → `.response.` 别名
- [x] F13: 高亮四套实现漂移 — 已同步 `queries/` ← `tree-sitter-poste-http/queries/` 的 `highlights.scm`
- [x] F14: `select.lua` 浮窗加 `WinClosed` 兜底 + `Snacks` 安全 require
- [x] F16: 渲染层全量重渲染 — pending 定时器窗口可见性检查、outline/fileref 防抖
- [x] F17: `columns.lua` CJK 字节偏移 — 改用 `#lead_sp`/`#pad_sp` 累积，避免 `pad_byte` 漂移
- [x] F18: `sanitize_lines` 改用 `vim.split` 保留空行 — 空行后 extmark 不错行
- [x] F19: 死代码 12 项 — 删零调用函数、合并重复分支、修 `format.lua` break 提前终止循环、修 jq 退出码分支不可达
- [x] F21: history 纯内存 — `add_entry`/`delete_entry` 序列化到 `stdpath("data")/poste-http/history.json`，`M.load()` 启动加载 + 恢复 id counter + 上限裁剪；`http_history_max`/`persist_history`/`history_file` 提为配置项

## 第七优先级（P2 测试体系）

- [x] F26: 空测试与假测试 — indicators_spec 5 个空 `it()` 全部实现；variable_ref_spec 改用真实 `request_deps.find_request_variable_refs`
- [ ] F28: 覆盖缺口 — 21+ 模块零测试引用（本轮已新增 `zero_coverage_smoke_spec.lua`，覆盖 nested_access/import_parser/三个 import_*/multipart/md5/file_include/prompt_vars/var_collector/format_file/constants 共 34 项冒烟测试，含 F07 崩溃回归；GUI 强耦合模块待后续 harness）
- [x] F29: 测试卫生 — `grammar_spec.sh`（修 `request_body`→`json_body` 陈旧断言）与 `injection_spec.sh`（重写：heredoc-in-`-c` 根本不可用、删硬编码 Homebrew 路径、修空 stdin grep、修 `request_body`→`json_body`/`json`→`poste_json`）已并入 `run.sh`；`dofile("./tests/helpers/mock_nvim.lua")` CWD 依赖改 `require("helpers.mock_nvim")`；`math.randomseed(42)` 固定种子；`test_http_completion_fixtures_spec` 补 `after_each` 清理临时目录（删从不调用的 `teardown_env_json`）；`http_image_preview_spec` 临时文件统一 `make_tmp_file` + `after_each` 删除；新增 `.github/workflows/ci.yml`（tree-sitter CLI + Neovim 0.10 + plenary，跑 `tests/run.sh`）；`vim.wait` 轮询与 `mock_nvim` 浅实现属深层重构，留待后续

## 第八优先级（P3 安全与健壮性）

§6 共 29 项（见报告 §6），子项跟踪：
- [x] 明文日志 — `curl_exec.lua` 敏感头（Authorization/Cookie/X-Api-Key 等）脱敏 `[REDACTED]`；`util.redact_url_query` 掩码 query 值，`run.lua` 日志改用之
- [x] shell 转义缺 `[]` — `copy.lua:14` 特字符集合补 `[`/`]`，IPv6 URL 导出单引号包裹；新增 `copy_spec.lua` 4 测试（无修复则 IPv6 用例失败）
- [x] `<` 路径展开误伤脚本标记 — `file_include.lua:22` 排除 `< {%` 脚本行；冒烟 spec 加回归
- [x] 路径拼接用字符串 — `run.lua:772`、`cache.lua:564`、`script_block.lua:64`、`vars.lua:187`；`script_block.lua:75` 未转义
- [x] gsub 捕获陷阱 — `format_file.lua:93-99` 还原 `{{var}}` 时 `%1`-`%9` 崩溃
- [x] `@var` 解析三套实现 — `scripts.lua` 与 `vars.lua` 模式收敛（复用 vars.lua 解析器 + 多行支持）
- [x] 脚本 env 目录错误 — `scripts.lua:57-62` `nvim_buf_get_name(0)`（改传 file_dir，跨文件依赖正确）
- [x] curl 超时选项未生效 — `curl_exec.lua:41` 无 `--max-time`/job 杀死
- [x] body 临时文件写失败静默跳过 — `curl_exec.lua:60-66`
- [x] `request_deps.lua:74` 请求名含 `.` 无法解析
- [x] env.json 缓存按秒级 mtime — `cache.lua:421-423`
- [x] 行号 0-based/1-based 混用 — `cache.find_request_line` 等
- [x] `symbols.lua:71` 只扫 `start_line + 20` 行；`:24-34` 字节截断切碎 CJK
- [x] blink keyword pattern 不含 `-` — `completion.lua:39-41`（含 nvim-cmp 同步）；列号约定统一为 1-based 行 / 0-based 列（对齐 `nvim_win_get_cursor`）
- [x] `context_detector.lua:46-48` 列号约定不一致
- [x] `folding.lua:22-33` 缓存不按 buffer 键控
- [x] `nav.lua:100,112` 用 `^###` 而非 `^%s*###`
- [x] `cache.lua:473-486` 光标在块尾注释上返回 nil（尾注释归属块，空行仍为块间空隙）
- [x] `import.lua:698-715` post-script 块扫描越界跳过（用原始 block start 扫原始 content）
- [x] `resolve.lua:71-77` on_complete 非函数守卫（doc 与实现统一）
- [x] `verbose.lua:216,240,377` 硬编码宽度 80（opts.width 参数化 + separator 同宽）
- [x] `verbose.lua:15,182-187,595-681` 模块级可变状态（r 附加字段优先于模块级）
- [x] `verbose.lua:594-629` 字符串启发式分区误判（section_lines 显式标记替代正则）
- [x] `buffer_setup.lua:96` namespace 泄漏（模块级单 namespace 替代 per-buffer）
- [x] formatters 写磁盘副作用 — `body.lua:26-31`、`verbose.lua:339-344` 秒级文件名覆盖（hrtime ms 防冲突）
- [x] `boundary_indicator.lua` 快照而非实时（CursorMoved 接线 + double clear_all 修复）
- [x] `indicators.lua:85-99` 单一全局 spinner（per-request timer + BufDelete 清理）
- [x] `history.lua:240` 每次渲染强制光标回第 1 行（按 entry+view 保存/恢复光标位置）
- [x] luacheck 95 warnings → 70（清理 8 文件：unused var、shadowing、redefinition）