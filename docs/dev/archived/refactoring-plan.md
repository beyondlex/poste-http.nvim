# Poste HTTP Refactoring Plan

> Code quality & architecture improvement plan for `poste-http.nvim`.
> Based on the 2026-07 code review.

---

## Overview

| # | Issue | Severity | Effort | Risk |
|---|-------|----------|--------|------|
| **R1** | 循环依赖 `cache ↔ import ↔ resolve ↔ request_vars ↔ cache` | Critical | Small | Medium |
| **R2** | 神级模块 `request_vars.lua` (1316行, 7+职责) | Critical | Large | High |
| **R3** | 神级模块 `nav.lua` (1524行, 重复代码) | High | Large | High |
| **R4** | 代码重复: `format/body.lua` ↔ `format/verbose.lua` (~200行) | High | Small | Low |
| **R5** | `run.lua` 回调链 + 函数参数过多 (10个参数) | High | Medium | Medium |
| **R6** | `init.lua:setup()` 单体 (140行内嵌15个命令) | Medium | Small | Low |
| **R7** | 全局状态失控: 16+模块直接写 `state.*` | High | Medium | High |

### 执行顺序

```
Phase 0: 低风险先改 — R4 (重复代码抽取) + R6 (命令提取)
Phase 1: 加 characterization tests (run.lua, nav.lua, cache.lua, buffer.lua)
Phase 2: 修复 R1 循环依赖
Phase 3: 拆分 R2 request_vars.lua
Phase 4: 拆分 R3 nav.lua
Phase 5: 改造 R5 run.lua 参数表 + 扁平化
Phase 6: R7 state 封装 setter
```

---

## Phase 0: 低风险先改 (R4 + R6)

### R4 — 抽取 `format/body.lua` ↔ `format/verbose.lua` 重复代码

**目标**: 消除两文件间 ~200 行重复代码。

**做法**:
1. 创建 `lua/poste-http/http/format/util.lua`
2. 移入: `split_lines()`, `human_size()`, `is_large_body()`, `save_body_to_file()`, `json_pretty()`, `format_urlencoded_body()`
3. `body.lua` 和 `verbose.lua` 改为 `require("format.util")` + 删除本地副本
4. 运行测试验证

### R6 — 提取 `init.lua:setup()` 中的用户命令

**目标**: 消除 `setup()` 中 15 个内联命令定义。

**做法**:
1. 创建 `lua/poste-http/commands.lua` — 用数据表定义所有命令
2. `setup()` 改为循环注册
3. 移除 `_G.poste_status` 全局污染

---

## Phase 1: Characterization Tests

**目标**: 为无测试的关键模块加 characterization tests，锁定当前行为。

| 模块 | 行数 | 测试策略 |
|------|------|---------|
| `run.lua` | 679 | 测试 `M.run_request` 调用链、`execute_request` 参数处理、`handle_curl_response` 分支 |
| `nav.lua` | 1524 | 测试 `M.goto_definition`、`ts_goto_definition`、`M.goto_references` 的边界情况 |
| `cache.lua` | 634 | 测试 `M.get_buffer_cache` 的缓存命中/失效、`M.collect_import_index` |
| `buffer.lua` | 487 | 测试 `sanitize_lines`、`setup_keymaps` 的键位注册 |

---

## Phase 2: 修复循环依赖 R1

**目标**: 消除 `cache → import → resolve → request_vars → cache` 循环。

**做法**:
1. `request_vars.lua:94` 的 `require("cache")` 从函数内提到模块级 —— 利用 Lua 模块缓存机制，等 `cache.lua` 加载完后再执行 `request_vars` 的其余代码
2. 或者: 将 `collect_requests` 函数移出 `request_vars.lua` 到新模块 `request_collector.lua`，该模块不依赖 `cache.lua`

---

## Phase 3: 拆分 request_vars.lua (R2)

**目标**: 将 1316 行的神级模块拆为 4 个专注模块。

```
lua/poste-http/http/
├── request_vars.lua          ← ~200行: 公共 API + 分发
├── form_data.lua             ← 表单数据、multipart、magic vars ({{$uuid}}等)
├── prompt_vars.lua           ← <<var 指令处理、异步 UI
├── request_deps.lua          ← 跨请求依赖解析、执行链
├── jq_mapping.lua            ← jq 风格路径映射、结构化选项
```

**步骤**:
1. 先写 `form_data.lua` — 提取 `generate_uuid`、`process_form_data` 等
2. 再写 `jq_mapping.lua` — 提取 `parse_structured_options`、`parse_dynamic_mapping`、`apply_jq_mapping`
3. 再写 `prompt_vars.lua` — 提取 `handle_prompt_variables_impl` 及相关函数
4. 最后写 `request_deps.lua` — 提取依赖解析和执行链
5. `request_vars.lua` 保留为 thin facade + 兼容 re-export

---

## Phase 4: 拆分 nav.lua (R3)

**目标**: 将 1524 行的导航模块拆分 + 消除重复代码。

**做法**:
1. `nav.lua` 保留公共 API (`M.goto_definition`, `M.goto_references`)
2. 提取 `nav/ts.lua` — tree-sitter 导航逻辑 (`ts_goto_definition`, `ts_goto_references`)
3. 提取 `nav/text.lua` — 文本回退导航逻辑 (`M.goto_definition` 中非 TS 部分)
4. 消除 `ts_goto_definition` 中 `identifier` / `variable` 节点类型的重复分支

---

## Phase 5: 改造 run.lua (R5)

**目标**: 消除 10 参数函数 + 扁平化回调链。

**做法**:
1. `handle_curl_response(response, ...)` 改为 `handle_curl_response(opts)` 接收一个 table
2. `start_curl_exec(file, ...)` 同理
3. `M.run_request` 中的 3 层回调链改为命名阶段函数:
   - `prepare_request` → `execute_request` → `start_curl_exec` → `handle_curl_response`

---

## Phase 6: state 封装 (R7)

**目标**: 控制全局状态写入路径。

**做法**:
1. `state.lua` 加 setter: `M.set_last_response(resp)`, `M.set_script_variables(vars)`, `M.clear_request_scoped()`
2. 直接写 `state.last_response = ...` 的地方改为调用 setter
3. `session.lua` 使用 setter 替代直接赋值

---

## 验收标准

- [ ] 所有 Phase 完成后 `tests/run.sh` 全绿
- [ ] 每个 Phase 独立可回退，不跨 Phase 混合提交
- [ ] 无新模块 > 500 行
- [ ] 无函数 > 50 行
- [ ] 无函数参数 > 5 个
- [ ] 无循环依赖 (verified by `require` 图分析)