# Poste HTTP 代码审查报告

> 审查日期：2026-08-13
> 审查对象：`poste-http.nvim`（Lua + curl 的文件驱动 HTTP 请求执行器，约 2 万行 Lua）
> 审查方式：5 个并行子代理分区深读 + 主代理逐条核实 + NVim v0.12.3 headless 实测 + 全量测试套件实跑
> 基准 commit：`e0db389`

---

## 0. 证据等级约定

报告中每条发现都标注证据等级，避免混淆「已确认」与「疑似」：

| 等级 | 含义 |
|------|------|
| **【实测】** | 在本机 NVim v0.12.3 上 headless 复现 / 探测验证（含解析行为、崩溃、API 存在性） |
| **【代码】** | 直接阅读源码确认，行号与代码一致 |
| **【报告】** | 子代理审查报告提出，主代理抽查了相关代码但未逐行独立验证 |

「位置」列中带函数名的引用，行号与函数名均已核对；仅带模块名的引用表示该文件已核对但未定位到具体行。

---

## 1. TL;DR

| 编号 | 严重度 | 一句话结论 |
|------|--------|-----------|
| F01 | P0 | 失败的请求被渲染成「200 成功」，绿色 ✓ + 入 history |
| F02 | P0 | orchestration 脚本引用未定义的全局 `state`，`client.global.*` 一用就崩 |
| F03 | P0 | TS 查询层在 NVim ≥0.11 上崩溃，folding/文本对象/大纲/诊断四个功能是坏的 |
| F04 | P0 | 依赖链状态跨请求泄漏，第二个请求带上第一个的依赖响应 |
| F05 | P0 | 异步回调无错误兜底，关掉源 buffer 或服务器挂起会永久卡死插件 |
| F06 | P0 | `diagnostics.lua` 调用不存在的 `ts_query.get_node_text`，诊断通道静默死亡 |
| F07 | P0 | 三个 spec 导入器全部零测试，OpenAPI/Swagger/Postman 各有真实崩溃 |
| F08 | P1 | 缓存每次按键失效，补全退化为 ~13ms 同步工作且会执行导入的 Lua 文件 |
| F09 | P1 | README 教的 `require("poste")` 模块不存在，新用户照文档配置直接报错 |
| F10 | P1 | `default_env` 配置不生效、`poste_binary`/`split_size` 是死配置 |
| F11 | P1 | 文档声称的 `:PosteJqFilter`、`{{Name.res.body.X}}` 与代码不符 |
| F12 | P1 | 「单一解析权威」名不副实：块边界至少三套解析且已实际分叉 |
| F13 | P1 | 高亮四套实现并存，`queries/` 与 tree-sitter 包内的 `.scm` 已漂移 |
| F14 | P1 | `select.lua` 浮窗选择器无关闭兜底，调用方可能永久挂起 |
| F15 | P1 | 导航双实现（nav/text + nav/ts），~60% 代码逐字重复，TS 版默认关闭 |
| F16 | P1 | 渲染层到处全量重渲染（切 tab、pending 定时器、outline 逐击键） |
| F17 | P1 | `columns.lua` CJK 列宽/字节混算导致高亮错位；`sanitize_lines` 丢空行 |
| F18 | P1 | `highlights.lua` 无条件覆盖用户 `:highlight` 自定义 |
| F19 | P1 | 死代码与不可达分支清单（12 项，含 `build_pending_request` 零调用等） |
| F20 | P1 | 导入/导出层约 25% 复制粘贴 + `import.lua` 1111 行 monolith |
| F21 | P1 | History 声称「持久化」实为纯内存，重启即丢 |
| F22 | P1 | `_busy` 标志 14 处手动复位，任何漏网路径都会卡死插件 |
| F23 | P2 | 执行核心几乎无测试（curl_exec/response_parser/run_request 均被 stub） |
| F24 | P2 | 契约测试层从不运行（`test_contract.lua` 非 `*_spec.lua` 命名） |
| F25 | P2 | SQL 仓库孤儿测试文件（违反 AGENTS.md，含 `qa!` 自杀式文件） |
| F26 | P2 | 空测试与假测试（五个空 `it()`、`variable_ref_spec` 测自己的副本） |
| F27 | P2 | 套件不稳定 + 环境耦合（nav_spec 全套 7 失败/单独 12 通过；run.sh 无 `-u NONE`） |
| F28 | P2 | 覆盖缺口与「Bug fix → test」承诺落差（21+ 模块零测试引用） |
| F29 | P2 | 测试卫生：临时文件泄漏、`vim.wait` 轮询、mock_nvim 浅实现、无 CI |
| P3 | §6 | 安全与健壮性细节（明文日志、shell 转义缺 `[]`、路径拼接、gsub 陷阱等 29 项） |
| 文档 | §7 | 文档-代码漂移清单 D01–D17（`require("poste")`、`error.lua`、CLI 残留等） |

---

## 2. 方法论

1. **分区深读**：5 个子代理并行审查（核心执行管线 / UI 渲染 / 解析导航 / 导入导出与文档 / 测试体系），各自返回带 `file:line` 的编号发现。
2. **主代理逐条核实**：对全部 P0/P1 发现和大部分 P2 发现，重新阅读源码核对行号与机制；对子代理报告中与主代理判断冲突的论断，以实测为准。
3. **实测探针**：在 NVim v0.12.3 headless 环境运行 Lua 探针，验证：`iter_matches` 返回值的结构、大写 `RUN` 在发布 parser 中的解析结果、`ts_query.get_node_text` 是否存在、TS 消费者按现有写法调用是否崩溃。
4. **测试实跑**：`tests/run.sh` 全量执行，记录通过/失败；单独跑失败 spec 对照。
5. **静态检查**：`luacheck lua/` 全量执行。

**结论可信度说明**：本报告只收录「已核实」或「明确标注证据等级」的发现。任何在核实过程中被证伪的论断单独列在 §8，不混入正文。

---

## 3. P0 — 关键正确性缺陷（错误结果 / 崩溃 / 卡死）

### F01 失败的请求被渲染成「200 成功」

- 位置：`lua/poste-http/http/response_parser.lua:63-66, 73-75, 262`；`lua/poste-http/http/run.lua:212`
- 证据：【代码】
- 问题：`parse_headers_file` 在 curl 的 `-D` headers 文件为空或缺失时返回 `{ status = 200, status_text = "200 OK" }`；而 DNS 失败、连接拒绝、超时恰好不会产生 headers 文件。`parse_error`（`response_parser.lua:262`）原样继承 `parsed.status`（即 200）。`run.lua:212` 的错误分支要求 `response.status == 0 and response.protocol == "error"`，永不触发。
- 后果：一个从未到达网络的请求走成功路径——显示绿色 ✓、正文为 curl 的 stderr、被写入 history 与响应缓存。用户得到确定性的错误结果且无任何提示。
- 建议：`parse_error` 中强制 `status = 0`（或将 stderr 写入 `response.error`），确保 `run.lua:212` 分支触发；`parse_headers_file` 对空文件不要默认 200。

### F02 orchestration 脚本引用未定义的全局 `state`

- 位置：`lua/poste-http/http/orchestration.lua:8-9`（require 列表）、`:83-103`（`state.*` 调用）
- 证据：【代码】
- 问题：该文件只 `require("poste-http.http.import")` 和 `require("poste-http.util")`，全文件无 `local state`；`:83-103` 却调用 `state.set_global_var`、`state.log`、`state.global_vars`、`state.set_global_header` 等。全仓库无任何地方给全局 `state` 赋值。
- 后果：`client.global.set/get/header.*`（README 主打特性）一经执行即抛 "attempt to index global 'state' (a nil value)"，脚本以费解的报错终止，全局变量从未被设置。
- 建议：文件顶部补 `local state = require("poste-http.state")`；并为 `client.global` 补一个测试。

### F03 TS 查询层在 NVim ≥0.11 上崩溃（folding/文本对象/大纲/诊断）

- 位置：`lua/poste-http/http/ts_query.lua:82-93`（`collect_matches`）；消费者 `lua/poste-http/http/folding.lua:13`、`lua/poste-http/http/textobj.lua:47-51`、`lua/poste-http/http/outline.lua:94, 157-162`、`lua/poste-http/http/diagnostics.lua:36-78`
- 证据：【实测】本机 NVim v0.12.3 按 `collect_matches` 同款写法探测：`match` 值类型为 `table`（节点**列表**），元素才是 `userdata` 节点；对其调用 `:start()` 复现崩溃 "attempt to call method 'start' (a nil value)"。
- 问题：自 NVim 0.11 起 `Query:iter_matches` 的 `match` 是「捕获 id → 节点列表」的映射；`collect_matches` 仍把列表当单个节点存入 `captures`，所有消费者随后对列表调用 TSNode 方法。
- 后果：启用 `use_treesitter` 的 folding、文本对象、TS 大纲、诊断语义规则在当前稳定版 NVim 上全部崩溃，且无回退、无测试（这四个模块在 `tests/` 中零引用）。
- 建议：`collect_matches` 内改为 `for _, node in ipairs(match[id])` 逐节点收集；补一个 headless 测试直接驱动 `query_nodes`。

### F04 依赖链状态跨请求泄漏

- 位置：`lua/poste-http/http/request_deps.lua:49-50`（模块级 `_chain_dep_set`/`_chain_dep_order`）、`:599-600`（唯一清空点，位于 `resolve_request_variables_impl`）、`lua/poste-http/http/resolve.lua:34`（生产路径走 `_resolve_content_dependencies_impl`）
- 证据：【代码】
- 问题：生产管线（`resolve.lua:34`）调用的 `_resolve_content_dependencies_impl` 从不重置这两个模块级表；唯一清空它们的 `resolve_request_variables_impl` 在生产路径上零调用者。`request_response_cache`（`request_deps.lua:30`）也从不随源文件编辑失效。
- 后果：连续两个「带依赖」的请求，第二个的 `_dep_chain` 包含第一个的依赖响应——多响应视图与 history 出现陈旧条目；编辑依赖块后仍返回首次执行的旧响应。
- 建议：在 `execute_deps_for_block` 入口重置两个表；响应缓存按 session/changedtick 关联失效。

### F05 异步回调无错误兜底，可永久卡死插件

- 位置：`lua/poste-http/http/run.lua:172-272`（`handle_curl_response`）、`:386-428`（`handle_directive_response`）、`:763-766`（`_busy` 守卫）
- 证据：【代码】
- 问题：两个回调的整个函数体在 `vim.schedule` 中执行，无 `pcall`、无 `nvim_buf_is_valid` 守卫。curl 运行期间用户关闭/wipe 源 buffer 后，`run.lua:261`（`nvim_buf_get_lines`）与 `run.lua:91`（`find_assertion_line` 内）抛 "Invalid buffer id"，`state._busy = false` 永不执行。
- 后果：此后每个 `run_request` 都只回 "Request already in progress"，必须重启 Neovim。`LEARNINGS.md` 记录同类卡死（`http/busy-wedge`）已发生过两次，属于反复踩坑的路径。
- 建议：回调体包 `pcall`，并保证任何路径都复位 `_busy`（`finally` 语义）；访问 buffer 前先 `nvim_buf_is_valid`。

### F06 `diagnostics.lua` 调用不存在的函数

- 位置：`lua/poste-http/http/diagnostics.lua:37, 67` 调用 `ts_query.get_node_text`；`lua/poste-http/http/ts_query.lua` 只有 `node_text`（`:32`）
- 证据：【实测】探针输出 `ts_query.get_node_text exists: false`。
- 问题：`update_diagnostics` 在遍历 `@var` 定义时必然走到 `:37`，抛 "attempt to call field 'get_node_text' (a nil value)"。
- 后果：整个诊断通道（含语法错误遍历）静默死亡；用户看不到任何诊断，也无报错提示。
- 建议：改为 `ts_query.node_text`；补测试覆盖至少一个 `@var` 行的诊断调用。

### F07 三个 spec 导入器零测试且各有真实崩溃

- 位置：
  - `lua/poste-http/http/import_openapi.lua:39`：`next(example)`——`schema_to_example` 对标量 schema 返回字符串/数字（`import_parser.lua:74-76, 93-115`），`next("2024-01-01")` 抛 "bad argument #1 to 'next' (table expected, got string)"。【代码】
  - `lua/poste-http/http/import_swagger.lua:77-80` + `lua/poste-http/http/import_parser.lua:17-25`：`schema_to_example` 对 object schema 返回**表**，`generate_http_block` 直接 `table.concat(lines)` 崩溃。任何带 body schema 的 POST/PUT/PATCH 都会触发。【代码】
  - `lua/poste-http/http/import_postman.lua:38-40`：`parse_url` 返回 `raw .. "?" .. query`，而 Postman 集合的 `url.raw` 通常已含 query 串，结果查询参数翻倍（如 `?page=1&limit=10?page=1&limit=10`）。【代码】
  - `lua/poste-http/http/import_postman.lua:154`：对可能为数字的变量值执行 `:gsub`，崩溃。【报告】
- 证据：【代码】+【报告】
- 后果：OpenAPI/Swagger/Postman 导入在常见输入上直接报错或产出错误文件；三个导入器在 `tests/` 中没有任何 spec。
- 建议：`import_openapi` 修 `type(example) == "table"` 判断；`import_swagger` 改用 `vim.json.encode`（对齐 OpenAPI 版）；`import_postman` 先判断 `raw` 是否已含 `?` 再拼接；三个导入器各补一个冒烟测试。

---

## 4. P1 — 高优先级（配置 / API / 文档断裂、功能损坏、性能）

### 4.1 配置与公开 API

#### F08 缓存每次按键失效，补全退化为同步重扫且会执行导入的 Lua

- 位置：`lua/poste-http/http/cache.lua:22-29`（`TextChangedI`/`TextChanged` 清空缓存）、`lua/poste-http/http/import.lua:203-216`（`build_import_index` 对 `import ./x.lua` 执行 `load` + `pcall(fn)`）
- 证据：【代码】；子代理在 1200 行文件上实测冷启动级联约 13.27 ms/击键
- 问题：`cache.lua:43-47` 的 changedtick 守卫本可检测真实变更，`:22-29` 的逐击键清空是多余且有害的。清空后重建级联包含：全文件行扫描、tree-sitter `describe` 解析、import 索引重建——后者会 `read_file` 每个被导入文件并**执行其中 Lua**。
- 后果：补全/指示器场景下每次按键 ~13ms 同步主线程工作，文件越大越差；且「在补全上下文里打字」即可触发导入文件中的任意代码执行（延迟 + 供应链双重风险）。
- 建议：删除逐击键清空，仅依赖 changedtick 失效；或实现增量 `on_bytes` 修补；import 索引与 buffer 扫描解耦缓存。

#### F09 README 教的入口模块不存在

- 位置：`README.md:69, 150`；`docs/user/keymaps.md:6, 109, 137`（均写 `require("poste").setup()`）；`lua/` 下只有 `poste-http/`
- 证据：【代码】`lua/poste.lua` 与 `lua/poste/init.lua` 均不存在。
- 后果：新用户照文档配置，`require("poste")` 直接抛 "module 'poste' not found"。
- 建议：全部改为 `require("poste-http").setup()`。

#### F10 `default_env` 配置不生效；`poste_binary`/`split_size` 是死配置

- 位置：`lua/poste-http/state.lua:4`（`poste_binary`，全库零读取）、`:7`（`split_size`，全库零读取）、`:62`（`current_env = config.default_env`，模块加载时求值）；`lua/poste-http/init.lua:32-34`（setup 合并 opts 后不同步 `current_env`）
- 证据：【代码】
- 问题：`setup({ default_env = "prod" })` 只改 `config.default_env`，`current_env` 仍是模块加载时的 "dev"；`split_size` 定义了但响应窗口从未按它开尺寸（`buffer.lua:484-494` 只用 `split_direction`）；`poste_binary` 是已删除 Rust CLI 的残留。
- 后果：用户配置三项里有三项无效或误导。
- 建议：`setup()` 内若用户显式传 `default_env` 则同步 `current_env`；删除两个死配置（或实现 `split_size`）。

#### F11 文档声称的命令与语法不存在 / 不匹配

- 位置：`README.md:14`（`:PosteJqFilter`）；`README.md:10`、`docs/dev/file-index.md:51`（`{{Name.res.body.X}}`）；`lua/poste-http/http/request_deps.lua:130`（只匹配 `%.response%.` / `%.request%.`）
- 证据：【代码】`commands.lua` 与 `plugin/poste.lua` 的命令列表中无 `PosteJqFilter`；`request_deps.lua:130` 的 match 模式无 `.res.`。
- 后果：用户执行不存在的命令、按文档语法写链式引用得到未解析的字面量。
- 建议：删除或实现 `:PosteJqFilter`；文档改为 `{{Name.response.body.X}}`（或代码补 `.res.` 别名并加测试）。

### 4.2 解析架构

#### F12 「单一解析权威」名不副实，块边界至少三套解析且已分叉

- 位置：`lua/poste-http/http/block_boundary.lua:1-3`（自称单一来源）但 `compute_block_range` 仅 `describe.lua:56` 调用；`cache.lua` 内联重算 `end_line`/`last_content_line`（`:176-182, 277-279, 287-292`，两个分类分支约 82% 重复）；`describe.lua:102-124` 只在 `request_block` 节点建块
- 证据：【代码】
- 问题与后果：
  1. 文件首个请求**不带 `###`** 时，`describe_content` 返回 0 个块（`describe.lua:102-124` 只认 `request_block` 节点），语义块经 `normalize_to_semantic` 降级后丢失 method/path/headers/body，`boundary_indicator` 与消费方静默失去全部请求语义；
  2. `cache.lua:77` 用 `###%s*` 而 `:86` 用 `###%s+` 提取块名——`###Name`（无空格）时 `block.name` 有值但 `req_names` 没有，补全/导航缺条目；
  3. `describe_content`（`describe.lua:171-187`）在 tree-sitter 不可用时只 `return {}, nil` 并打日志，**从不向上报错**——`run.lua:311` 的 `desc_err` 分支是死代码；架构文档宣称的「CLI fallback」不存在。
- 建议：`cache.lua` 统一调用 `block_boundary.compute_block_range`；`describe.lua` 对无 `###` 开头的文件也建块；统一 `###` 匹配；删除两个重复分支。

#### F13 高亮四套实现并存且已漂移

- 位置：`queries/poste_http/highlights.scm` vs `tree-sitter-poste-http/queries/highlights.scm`（diff 确认不一致：pre_script/post_script/script_block 规则不同）；另有两套：`syntax/poste_http.vim`、`lua/poste-http/http/highlights.lua`
- 证据：【代码】`diff` 实测两文件内容不同；`injections.scm`/`folds.scm` 两副本一致
- 问题：AGENTS.md 明确要求「语法 ↔ grammar 同步」，但运行时副本与 grammar 包副本靠手工同步，已漂移。
- 后果：同一语法在不同安装方式（仓库 rtp vs grammar 包）下高亮不一致；修高亮要同步四处。
- 建议：确定唯一权威副本，构建脚本自动复制到另一处（或运行时只读一处）。

#### F14 `select.lua` 浮窗选择器无关闭兜底，调用方可能永久挂起

- 位置：`lua/poste-http/select.lua:84-89`（`resolve` 只在 keymap 调用）、`:31`（直接用全局 `Snacks`）、`:180-184`（仅 pcall `require("snacks.picker")`）
- 证据：【代码】
- 问题：浮窗被 `:q`、`<C-w>c` 或鼠标关闭时无 `WinClosed`/`BufWipeout` 兜底，`on_select` 永不回调；且 `Snacks` 全局未初始化时 `:31` 抛未处理错误。
- 后果：环境切换/变量提示等调用方无限阻塞；snacks 安装但未初始化时直接报错。
- 建议：浮窗加 `WinClosed` autocmd 调 `resolve(nil)`；`Snacks` 访问包 `pcall`。

### 4.3 重复与死代码

#### F15 导航双实现，约 60% 代码逐字重复，TS 版默认关闭

- 位置：`lua/poste-http/http/nav/text.lua`（734 行，`goto_definition` 占 428 行）、`lua/poste-http/http/nav/ts.lua`（693 行）、`lua/poste-http/init.lua:37`（`use_treesitter.nav` 默认 false）、`lua/poste-http/http/nav.lua:12-14`（仅按配置分发，无 parser 可用性回退）
- 证据：【代码】归一化后 221/671 行逐字相同（主代理测量）；子代理测量 ts.lua 约 60% 行在 text.lua 中逐字存在
- 问题：同一功能两套实现（正则 vs tree-sitter），共享 notify 文案（"File not found"/"Definition not found"/"Import not found for alias"）；已实际分叉（如 RUN 处理不一致）。TS 版是默认关闭的 opt-in，且启用后缺 parser 时直接报 "No tree-sitter node under cursor" 而非回退。
- 后果：修一次导航要改两遍；两版行为已不一致；投入最大的 TS 版默认不生效。
- 建议：抽取共享的 goto_definition/goto_references 核心，以「节点提供器」（TS 节点或正则 span）为参数，删除两个并行函数体。

#### F16 渲染层到处全量重渲染

- 位置：`lua/poste-http/http/view.lua:17-35`（200ms pending 定时器全量重渲染，窗口关闭后仍往隐藏 buffer 渲染）、`:37-55`（`render_view` 每次切 tab 全量 `nvim_buf_set_lines` + extmark 重建）、`lua/poste-http/http/outline.lua:449-463`（每次按键 `TextChangedI` 全量 tree-sitter 解析+重渲染）、`lua/poste-http/buffer_setup.lua:97-117`（每次按键全文件重扫重标）
- 证据：【代码】
- 后果：大响应（数万行 JSON）切 tab、补全、移动光标时可见卡顿；`verbose.lua:510-581` 的逐 token extmark 让开销进一步放大。
- 建议：单响应也走预渲染 buffer 缓存；定时器只在窗口存在且视图为 verbose 时更新；outline/文件引用标记做防抖。

#### F17 `columns.lua` 混算显示宽度与字节长度，CJK 高亮错位

- 位置：`lua/poste-http/ui/columns.lua:183-204`（`byte_offset = byte_offset + spec.lead + pad_byte * padn + #vis`；`padn` 来自 `disp_width`，`#vis` 是字节数）
- 证据：【代码】
- 后果：含宽字符（CJK）的单元格之后，所有列 `cell.col`/`end_col`（history 列表直接喂给 extmark，`history.lua:344-365`）字节偏移错误，状态/耗时/时间戳高亮错位。
- 建议：字节偏移按 `#lead_sp + #pad_sp + #vis` 累积（或显示宽度与字节偏移分开跟踪）。

#### F18 `sanitize_lines` 丢空行导致高亮错行

- 位置：`lua/poste-http/http/buffer.lua:446-458`（`line:gmatch("[^\n\r]+")` 跳过空串）；`view.lua:50`、`buffer.lua:166`（高亮基于未 sanitize 的 `lines` 计算）
- 证据：【代码】`"a\n\nb"` 经该函数得 `{"a","b"}`。
- 后果：内容含空行（如错误详情 `verbose.lua:318`、截断的 multipart `multipart.lua:110`）时，空行之后所有 extmark 高亮错行。
- 建议：按 `\n` 拆分并保留空串条目；或先 sanitize 再计算高亮位置。

#### F19 死代码与不可达分支清单

- 位置与证据（均【代码】）：
  1. `lua/poste-http/http/run.lua:278-383` `build_pending_request`：零调用者；内部 `elseif desc_err` 与 `else` 两个回退分支逐字重复约 20 行（`:331-370`），且 `desc_err` 恒为 nil（见 F12）。
  2. `lua/poste-http/http/run.lua:150-161` `set_result_indicator`：三分支中两个相同——断言失败时传 `"success"`，渲染出矛盾的「✓ ✘ 2/5 tests」（绿勾 + 红叉）。
  3. `lua/poste-http/http/run.lua:194-210` 与 `:212-222`：两个错误分支逐字重复。
  4. `lua/poste-http/http/run.lua:407`：`find_assertion_line(..., indicator_line + 1, indicator_line + 50)` 魔数 50，run 指令后超过 50 行的断言块静默丢失。
  5. `lua/poste-http/http/request_deps.lua:245-325` `build_dep_order`/`execute_deps_sequential`：零调用者。
  6. `lua/poste-http/http/describe.lua:154-156`：`multipart_boundary`/`multipart_form_data` 分支是空 `if ... end`。
  7. `lua/poste-http/http/response_parser.lua:211-214`：XML 与 HTML 分支匹配同一 `^%s*<`，HTML 分支不可达。
  8. `lua/poste-http/http/response_parser.lua:84-85`：`code_str` 赋值后丢弃；`lua/poste-http/http/curl_exec.lua:58` `cookie_file` 创建后未使用。
  9. `lua/poste-http/http/format.lua:126-129` `apply_request_highlights`：`line:find(":", 3)` 为 nil 时用 `break`——第一行冒号在第二列的 header（如 `A: value`）会**终止整个高亮循环**，而非跳过该行。
  10. `lua/poste-http/http/format/verbose.lua:37-46` 死 export `detect_filetype` 与重复的 `content_type_map`（活副本在 `format.lua:27-55`）。
  11. `lua/poste-http/http/copy.lua:116-137` `resolve_request_content`：零调用者。
  12. `lua/poste-http/http/json.lua:85-98`：`pcall(vim.fn.system)` 捕获不到非零退出码（`system` 不抛错），jq 出错时错误消息被当结果渲染，「jq error」分支实际不可达。
- 建议：逐一删除或修正；每条死代码删除前用 `grep` 确认无引用（本报告已确认上述项）。

#### F20 导入/导出层约 25% 复制粘贴 + import.lua monolith

- 位置：三个 importer 的 `read_spec`（逐字相同）、`run()`/finder 交互流（各约 32 行，仅标题字符串不同）、文件名清洗、env 组装；`lua/poste-http/http/import.lua`（1111 行）把 Lua 模块加载器写了三遍（`:206-230, 984-1014, 1077-1088`）
- 证据：【代码】`import_postman.lua:125-166` 与另外两个 importer 的 `run()` 结构逐行对应。
- 后果：修 import 流程要同步三份；import.lua 已到难以单点修改的规模。
- 建议：把交互流抽进 `import_parser.lua`（它已集中了生成/写入）；import.lua 按职责拆 5 个左右模块。

### 4.4 数据与持久化

#### F21 History 声称「持久化」实为纯内存

- 位置：`lua/poste-http/http/history.lua:64-81`（`add_entry` 仅 `table.insert(state.http_history, ...)` + 上限 100）；`docs/dev/file-index.md`（"history UI + persistence"）
- 证据：【代码】history.lua 全文件无磁盘读写。
- 后果：重启 Neovim 即丢全部 history；且每条深拷贝整个响应（`truncate_response` + `vim.deepcopy`），100 条 × 最多 100KB ≈ 10MB 常驻内存。
- 建议：`add_entry` 时序列化到 `stdpath("data")`，启动时加载；`http_history_max` 提为配置项。

#### F22 `highlights.lua` 无条件覆盖用户 `:highlight` 自定义

- 位置：`lua/poste-http/http/highlights.lua:127-201`（`define_hl_custom` 无条件执行）、`:240-241`（`ColorScheme`/`VimEnter` autocmd 重跑 `M.setup`）
- 证据：【代码】
- 问题：注释（`:35-37`）承诺用户 `:highlight` 覆盖可持久，但只有 `syntax_links` 尊重已有值，`define_hl_custom` 全部硬重置为 One-Dark 系深色值。
- 后果：用户手动覆盖在每次换 colorscheme 后消失；浅色主题下硬编码深色不可读。
- 建议：`define_hl_custom` 加与 `syntax_links` 相同的「已有组不覆盖」守卫，或全部迁入 `config.highlights`。

---

## 5. P2 — 测试体系问题

> 说明：AGENTS.md 声明「TDD first」「Bug fix → test」，以下发现直接与该声明相关。

### F23 执行核心几乎无测试

- 位置：`lua/poste-http/http/curl_exec.lua`（161 行：参数构建、shell 转义、临时文件、jobstart、退出处理）、`lua/poste-http/http/response_parser.lua:134,221`（`parse_response`/`parse_error`）、`lua/poste-http/http/run.lua:762-873`（`run_request` 管线）、`lua/poste-http/http/curl.lua`（`paste_curl`）
- 证据：【代码】`tests/` 中 4 个 spec 把 `curl_exec.execute` 替换为 stub（`run_busy_spec.lua:13-25`、`request_deps_spec.lua:145-158`、`import_spec.lua:480-484,541-545`、`orchestration_integration_spec.lua:80-90`）；git 历史 `586b171` 显示曾用真 curl 打 `127.0.0.1:8899` 后被移除。
- 后果：shell 命令构造、临时文件、curl 输出解析——注入/转义/泄漏类 bug 的温床——可无声回归（F01、F05 均为该区域 bug）。
- 建议：新增 `curl_exec_spec.lua`：stub `vim.fn.jobstart` 捕获命令、手动触发 `on_exit`/`on_stdout`，断言解析结果与临时目录清理。

### F24 契约测试层从不运行

- 位置：`tests/contract/test_contract.lua`（非 `*_spec.lua` 命名）；plenary 只发现 `*_spec.lua`；`docs/dev/testing.md:20-27` 声称该层存在
- 证据：【代码】`tests/run.sh` 用 `PlenaryBustedDirectory tests/`，glob 规则不含 `test_contract.lua`。
- 后果：文档化测试层形同虚设。
- 建议：改名 `contract_spec.lua`。

### F25 SQL 仓库孤儿文件

- 位置：`tests/diag/diag_context.lua`、`diag_stmt.lua`、`diag_space_trigger.lua`、`diag_winbar.lua`、`tests/bench/bench_dataset.lua`、`bench_dataset_driver.lua`、`tests/http/test_winbar_alignment.lua`
- 证据：【代码】以上文件均 `require("poste.sql.*")`，违反 AGENTS.md「No require poste.sql.*」；`diag_context.lua:90-91` 还执行 `vim.cmd("qa!")`。
- 后果：一旦被测试发现即崩掉整个测试进程；当前是纯死重。
- 建议：已删除（`experiments/prototype.lua` 亦同）。

### F26 空测试与假测试

- 位置：`tests/http/indicators_spec.lua:27-44`（五个空 `it()`，仅注释）；`tests/http/variable_ref_spec.lua`（自实现 `strip`/`find_request_variable_refs` 副本做断言，不 require 被测模块，删掉 `nav.lua` 也照样过）；`tests/http/state_contract_spec.lua`（开头自认 "These are NOT 'good design' tests"，多为琐碎不变量）
- 证据：【代码】
- 后果：绿色数量虚高，实际保护为零。
- 建议：实现或删除空 `it`；`variable_ref_spec` 改为驱动真实模块。

### F27 套件不稳定 + 环境耦合

- 位置：`tests/run.sh:10`（硬编码 `$HOME/.local/share/nvim/lazy/plenary.nvim`）、`tests/run.sh:18-23`（无 `-u NONE`，加载用户完整配置）、`tests/injection_spec.sh:10`（硬编码 Homebrew 路径）、`tests/http/methods_spec.lua:7-8`（相对 CWD 找 `grammar.js` 并用正则抓取 token）
- 证据：【实测】本机全套执行：nav_spec 7 个失败（E303 swap 文件冲突）、单独跑 12/12 通过——顺序依赖、`goto_definition` 打开真实文件后不清理 buffer；另一环境 836 测试全过但 `run.sh` 退出码 1（被开发者 nvim 配置污染）。
- 后果：CI（目前不存在）与本地结果不可复现。
- 建议：`run.sh` 加 `-u NONE` 与 XDG 临时目录；plenary 路径参数化；nav_spec 的 `after_each` 清理 buffer。

### F28 覆盖缺口与 TDD 承诺落差

- 位置：全 `lua/poste-http/**` 对照 `tests/**`
- 证据：【代码】21-26 个模块零测试引用，含：`import_openapi`/`import_swagger`/`import_postman`（F07 的崩溃源头）、`folding`、`diagnostics`、`textobj`、`file_include`、`form_data`、`format_file`、`commands`、`buffer_setup`、`install`、`help`、`lua_docs`、`nested_access`、`prompt_vars`、`var_collector`、`multipart`、`constants`、`script_snippet`、`import_parser`、`copy`、`curl`、`env`、`md5`、`highlights`、`outline`。
- git 历史：多个 bug fix 无配套测试（`6547218` copy_as_curl、`a07d7bc` highlight、`1eb8cd8` run-case、`64124f5`、`47b2d06`、`16405f1`、`0bef9b5`）；`2ca22fb` 声称「tests use public API」但 `request_deps_spec.lua` 仍调私有 `_resolve_content_dependencies_impl`；`7e4e12a` 自认曾存在顺序依赖断言。
- 建议：为每个零覆盖模块至少补一个冒烟 spec；把「bug fix → 测试」落实为 PR 检查。

### F29 其余测试卫生问题

- `tests/http/http_image_preview_spec.lua` 与 `test_http_completion_fixtures_spec.lua` 创建临时文件/目录从不清理（后者 `teardown_env_json` 定义了但从不调用）；`math.random` 未播种；`tests/http/request_deps_spec.lua:9,173` 用 `vim.wait(100)` 轮询；两个 spec 用 `dofile("./tests/helpers/mock_nvim.lua")`（依赖 CWD）；`run_spec.lua` 六处重复 `package.loaded[...] = nil` 样板；completion 相关测试分散在 6 个文件。
- `tests/helpers/mock_nvim.lua`：`nvim_buf_get_lines` 恒返回 `{""}`（无法表示 buffer 内容）、`jobstart` stub 不触发 `on_stdout`/`on_exit`、`uv.new_timer` 不回调、`vim.schedule` 同步执行（掩盖重入 bug）——因此它恰恰测不了最需要测的模块。
- 无 CI 配置（无 `.github/`）；`grammar_spec.sh`/`injection_spec.sh` 不在 `run.sh` 中。

---

## 6. P3 — 安全与健壮性细节

- **明文日志**（【代码】）：`curl_exec.lua:107` 记录完整 curl 命令（含 `-H "Authorization: ..."`）；`run.lua:726` 记录 URL（可能含 query token）。建议脱敏后再写日志。
- **shell 转义缺 `[]`**（【代码】）：`copy.lua:14` 的特字符集合不含 `[`/`]`，IPv6 URL（`http://[::1]/`）导出为 curl 命令时会被 shell 误处理。
- **`<` 路径展开误伤脚本标记**（【代码】）：`file_include.lua:22` 的 `^%s*<(%s+.+)$` 会匹配单行 `< {% ... %}` 脚本行，把脚本内容当文件路径解析。建议先排除 `{%`。
- **路径拼接用字符串而非 `vim.fs.joinpath`**（【代码】）：`run.lua:772`、`cache.lua:564`、`script_block.lua:64`、`vars.lua:187`，Windows 分隔符会出错；`script_block.lua:75` 把未转义路径拼进生成的 Lua 字符串（路径含 `"` 时产生非法 Lua）。
- **gsub 捕获陷阱**（【代码】）：`format_file.lua:93-99` 用 `gsub` 还原 `{{var}}` 占位符，变量值含 `%1`-`%9` 时抛 "invalid capture index"；LEARNINGS 已记录同类 `gsub` 多返回值问题（`format.lua:469` 历史）。
- **`@var` 解析三套实现**（【代码】）：`scripts.lua:16-52, 88-103` 与 `vars.lua:86-122, 124-161` 名字模式不同（`%w[%w_]*` vs `%S+`），且只有 `vars.lua` 支持 `>>>`/`<<<` 多行值——脚本变量会静默丢弃多行值。建议收敛到单一解析器。
- **脚本 env 目录错误**（【代码】）：`scripts.lua:57-62` `read_env_vars` 用 `nvim_buf_get_name(0)`（当前 buffer）解析 env.json，跨文件依赖脚本拿到的是调用方 env 而非依赖文件 env。
- **curl 超时选项未生效**（【代码】）：`curl_exec.lua:41` 读取 `opts.timeout` 后从未使用（无 `--max-time`、无 job 杀死）——服务器挂起即卡死（叠加 F05）。
- **body 临时文件写失败静默跳过**（【代码】）：`curl_exec.lua:60-66` `io.open(..., "w")` 失败时仅跳过写入仍追加 `--data-binary @body`，curl 发送空 body 或报错，用户无感知。
- **`request_deps.lua:74` 模式**（【代码】）：`^([^%.]+)%.([^%.]+)%.([^%.]+)` 使含 `.` 的请求名（如 `### get.user`）永远无法被解析为依赖。
- **env.json 缓存按秒级 mtime**（【代码】）：`cache.lua:421-423` 用 `mtime.sec` 判断失效，同一秒内的编辑不生效。
- **行号 0-based/1-based 混用**（【代码】）：`cache.find_request_line` 返回 0-based、`vim.fn.line(".")` 1-based，调用点手动 ±1（如 `run.lua:793`），是 LEARNINGS 中一串 off-by-one 的根源。
- **`symbols.lua:71` 只扫 `start_line + 20` 行**（【代码】）：预脚本超过 20 行的块在 outline 中显示 `--`；`:24-34` 按字节截断可能切碎 CJK 字符产生非法 UTF-8。
- **blink keyword pattern 不含 `-`**（【代码】）：`completion.lua:39-41` `[#%w_]+` 使 `Content-Ty` 只匹配 `Ty`，接受补全可能变成 `Content-Content-Type`。
- **`context_detector.lua:46-48` 列号约定不一致**（【代码】）：`ts_detect_script_context` 期望 1-based 列，但补全路径传 0-based（`completion.lua:52` → `item_builder.lua:373`），行首为负列；脚本上下文补全可能错位。
- **`folding.lua:22-33` 缓存不按 buffer 键控**（【代码】）：`cached_tick`/`cached_separators` 用 `buf = 0`，两个 changedtick 相同的 buffer 共享分隔符表。
- **`nav.lua:100,112` 用 `^###`**（【代码】）：其他层（`block_boundary.lua:13`、`cache.lua:70`）用 `^%s*###`，缩进的分隔符 `]]`/`[[` 跳过。
- **`cache.lua:473-486` 光标在块尾注释上返回 nil**（【代码】）：`get_block_at_line` 对 `last_content_line` 之后的行返回 nil，`run.lua:514` 因此放弃执行——光标落在块尾注释/分隔行时请求不跑且无提示。
- **`import.lua:698-715` post-script 定位风险**（【报告】）：预脚本注入与变量覆盖把 `opts.line` 推到 `orig_block_end` 之后时，post-script 的块扫描可能越界跳过。
- **`resolve.lua:71-77` 文档与实现不符**（【代码】）：doc 声称 `on_complete` 可为 `function|string|nil`，`finish` 直接调用——传字符串即崩（当前无调用方传字符串，属潜在崩溃）。
- **`verbose.lua:216,240,377` 硬编码宽度 80**（【代码】）：General/Header/Connection 行按 80 列渲染，而分隔符按真实窗口宽度——窄窗口下不一致。
- **`verbose.lua:15,182-187,595-681` 模块级可变状态**（【报告】）：`_sep_lines`/`_fmt_method` 全局残留先于响应字段被读取，乱序渲染（多响应预渲染、history 浏览）时高亮用错数据。
- **`verbose.lua:594-629` 字符串启发式分区**（【代码】）：body 以 `"  "` 前缀渲染且内含 "Status Code: 200" 之类的行时，被误判为视图节标题，body 范围被截断。
- **`buffer_setup.lua:96` namespace 泄漏**（【代码】）：`nvim_create_namespace("poste_fileref_" .. buf)` 每 buffer 一个，NVim 的 namespace 不回收。
- **`formatters 写磁盘副作用`**（【报告】）：`body.lua:26-31`、`verbose.lua:339-344` 在渲染路径保存附件文件；`util.lua` 的 `os.date("%Y%m%d_%H%M%S")` 秒级文件名，同一秒两个下载互相覆盖。
- **`boundary_indicator.lua` 快照而非实时**（【报告】）：`refresh` 只在 toggle 时调用（`:78-93`），无 CursorMoved 接线；`clear_all` 在 `:26-31` 被调两次。
- **`indicators.lua:85-99` 单一全局 spinner**（【代码】）：第二个并发请求会停掉第一个的 spinner 帧；`_extmarks` 从不在 `BufDelete` 清理。
- **`history.lua:240` 每次渲染强制光标回第 1 行**（【报告】）：浏览时丢失阅读位置。
- **luacheck 95 warnings**（【实测】）：`luacheck lua/` 输出 95 warnings / 0 errors，含 20+ unused variable（`init.lua:10` 未用 `symbols` 等）与多处变量遮蔽（`treesitter.lua:267`、`ts_query.lua:62`）。

---

## 7. 文档-代码漂移清单

> 以下为「文档写了 X，代码是 Y」的确定差异（【代码】核实），按影响排序：

| # | 文档位置 | 声称 | 实际 |
|---|---------|------|------|
| D01 | `README.md:69,150`、`docs/user/keymaps.md:6,109,137` | `require("poste").setup()` | 模块不存在，应为 `poste-http`（F09） |
| D02 | `README.md:152` | 配置 `poste_binary` | 已删除的 Rust CLI 残留，代码零读取（F10） |
| D03 | `README.md:14` | `:PosteJqFilter` 命令 | 命令不存在（F11） |
| D04 | `README.md:10`、`file-index.md:51` | `{{Name.res.body.X}}` | 代码只认 `.response.`/`.request.`（F11） |
| D05 | `architecture-overview.md` | describe.lua「CLI fallback」 | CLI 已删除，且无任何回退解析器（F12） |
| D06 | `file-index.md:19` | 共享层有 `error.lua` | 文件不存在 |
| D07 | `file-index.md:123`、`rust-retirement-plan.md`、`docs/dev/http/README.md` | formatter「tree-sitter based」 | `format_file.lua` 是纯字符串处理 |
| D08 | `file-index.md` | history「persistence」 | 纯内存（F21） |
| D09 | `LEARNINGS.md`（多条目） | 路径 `lua/poste/http/*`、Rust parser 引用 | 路径缺 `-http`，Rust 已删除——按 AGENTS.md 该文件是开工必读 |
| D10 | `run.lua:303,608`、`cache.lua:14`、`scripts.lua:256` | 注释「via CLI」「Rust parser」 | 陈旧注释 |
| D11 | `docs/dev/http/openapi-import-plan.md` | 基于 `crates/poste-cli` 的规划 | CLI 已删除，属活文档残留 |
| D12 | `docs/user/http/variables.md:293` | 变量「sent to the CLI」 | 无 CLI |
| D13 | `AGENTS.md` | 列出不存在的 `cli.lua`；语法同步目录名 `tree-sitter-http/` | 实际目录 `tree-sitter-poste-http/` |
| D14 | `README.md:3` | `**HTTP request execution for Neovim.` | 未闭合的加粗标记 |
| D15 | `.gitignore` | `/target`、`/Cargo.lock` | Rust 时代残留 |
| D16 | `tdd-guide.md:16,33` | `tests/http_*_spec.lua` | 实际布局 `tests/http/<name>_spec.lua` |
| D17 | `README.md` | lazy 示例 `config = function() require("poste").setup() end` | 同上 D01；且 `plugin/poste.lua:27` 已无条件调用 setup，用户再调一次属双跑（有 `vim.g.poste_setup_done` 防重，但 opts 合并时序依赖插件加载顺序） |

---

## 8. 被证伪 / 修正的论断

> 诚实记录审查过程中被推翻的假设，防止后续维护者误信。

1. **「发布的 parser 拒绝大写 `RUN`，诊断误报语法错误」——证伪**【实测】。
   对仓库内全部三份 `.so`（`parser/poste_http.so`、`runtime/parser/poste_http.so`、`tree-sitter-poste-http/tree-sitter-poste_http.so`）逐一用 NVim v0.12.3 加载解析 `RUN #Login`、`Run ./x.http`、`RUn #Y`：全部正确解析为 `run_directive`，无 ERROR 节点。`grammar.js:286-292` 的大小写不敏感已编入发布的二进制。
   **但同一论断的另一半成立**【代码】：`cache.lua:256` 的 `^[A-Z]+%s+%S` 在大写 `run` 检查（`:265`）之前匹配，大写 `RUN` 行被纯文本层分类为 "request"（`has_run` 永不置位）。影响有限：`resolve_run_at_cursor` 用自己的大小写不敏感 `parse_run_line` 检测，`has_run` 无外部消费者。结论：这是「双解析层对同一行分类不一致」的又一实例（见 F12），而非 parser 缺陷。
2. **「Swagger 导入在 `import_swagger.lua:70-82` 因未守卫 `operation.parameters` 崩溃」——修正**。`operation.parameters` 在 `:67` 有 `and operation.parameters` 守卫，不崩；真正的崩溃在 `:77-80` 把 `schema_to_example` 返回的表传给 `generate_http_block`（F07），机制不同。

---

## 9. 正面项（避免报告一边倒）

- `lua/poste-http/http/format.lua` 已重构为 facade + `format/` 子模块，注释明确指引新代码直接 require 子模块——证明作者具备拆分大型模块的能力。
- 测试套件 836 个用例大部分是真实断言且约 1.5s 跑完（headless）；`tests/run.sh` 结构简单清晰。
- `lua/poste-http/ui/columns.lua` 的设计方向（纯函数、无窗口、可单测）正确，问题仅在实现细节（F17）。
- `completion.lua` 的注册逻辑对 blink/nvim-cmp 双通道做了多层 pcall 防御。
- `import_parser.lua` 已集中 `generate_http_block`/`write_output` 等共享逻辑——三个 importer 的重复（F20）是「抽得不够」而非「完全没抽」。
- `.gitignore` 正确地排除了全部编译产物（`.so`/`.dylib`/`.wasm`/`.o`），仓库不含二进制。

---

## 10. 修复优先级建议

### 第一优先级（用户可见的正确性）

1. F01：失败请求显示成功——修 `parse_error` 的 status。
2. F02：orchestration 缺 `state` require。
3. F03+F06：TS 查询层崩溃 + 不存在的函数——修 `collect_matches` 与 `get_node_text`，各补一个 headless 测试。
4. F05：异步回调错误兜底 + `_busy` 复位（与 F22 一并处理）。

### 第二优先级（文档/配置对齐，成本低收益高）

5. F09 + D01：`require("poste")` → `require("poste-http")`（README 与 keymaps.md）。
6. F10：修 `default_env` 同步，删 `poste_binary`/`split_size`。
7. D02-D17：文档漂移清单逐项修。

### 第三优先级（测试基建，防复发）

8. F23：新增 `curl_exec_spec.lua`（stub jobstart 捕获命令 + 触发回调）。
9. F24：契约测试改名 `contract_spec.lua`。
10. F25：删除 SQL 孤儿文件；F27：`run.sh` 加 `-u NONE` + 参数化 plenary 路径；补齐 CI。

### 第四优先级（结构性重构，需排期）

11. F12：块边界收敛到 `describe` 单一来源。
12. F15：nav 双实现合一。
13. F20：import.lua 拆分 + importer 交互流去重。
14. F08：缓存失效策略（changedtick-only + import 索引独立缓存）。

---

## 附录 A：实测探针（可在本机复现）

```lua
-- 探针 1：iter_matches 返回值的结构（NVim ≥0.11 为节点列表）
local parser = vim.treesitter.get_string_parser("GET /x\n", "poste_http")
local root = parser:parse()[1]:root()
local q = vim.treesitter.query.parse("poste_http", "((request_line) @rl)")
for _, match in q:iter_matches(root, nil, 0, -1) do
  for id, node in pairs(match) do
    print(type(node))               -- 实测输出: table（节点列表）
    if type(node) == "table" then
      for _, n in ipairs(node) do print(n:type()) end  -- userdata
    end
  end
end

-- 探针 2：按 ts_query.collect_matches 的写法消费 → 崩溃
local ok, err = pcall(function()
  -- node 实为列表，node:start() 抛 "attempt to call method 'start' (a nil value)"
end)

-- 探针 3：ts_query.get_node_text 是否存在
print(require("poste-http.http.ts_query").get_node_text ~= nil)  -- false
```

```bash
# 测试套件实跑（注意：run.sh 无 -u NONE，退出码会被开发者 nvim 配置污染）
XDG_CACHE_HOME=/private/tmp/xdg-cache XDG_STATE_HOME=/private/tmp/xdg-state ./tests/run.sh
```

---

*本报告基于 2026-08-13 的仓库状态（HEAD `e0db389`）撰写。修复完成后，建议在本报告基础上增量更新（在对应条目追加「已修复」注记）或删除已修复条目，避免文档再次与代码脱节。*
