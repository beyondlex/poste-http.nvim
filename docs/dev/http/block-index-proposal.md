# 块索引方案（Agent-Ready）

> 基于 `docs/dev/http/syntax-reference.md` 定义的 HTTP 语法规范。

---

## 0. 背景与动机

### 问题

HTTP 补全系统和相关模块当前用「逐行模式匹配」来回答「我在文档的哪个位置？」——这不是结构查询，是字符串猜测。具体症状：

**A. 5+ 处独立的 `###` 边界检测**
- `indicators.lua`、`boundary_indicator.lua`、`request_vars.lua`、`symbols.lua`、`import.lua` 各自实现同一套 `###` 回溯/前扫逻辑
- 边缘处理不一致：有的返回 0-indexed、有的 1-indexed、有的跳过注释、有的不跳过
- 一处修 bug 其他处不感知

**B. 补全热路径 O(n) 扫描**
- `context_detector.lua:detect_script_context` 每次按键从 buffer 头读到光标行，逐行 `:find("{%")` / `%}`
- `cache.lua:collect_request_vars` 每次补全触发都重新 `find_request_block_bounds` + 读 block lines + 模式匹配
- 对 100+ 行的 `.http` 文件，每次补全触发 ~200 次 Lua 字符串操作 + Nvim API 调用

**C. 无单一事实源**
- 新增一个上下文类型（如 body JSON 路径补全）需要在 `context_detector.lua` 的 if-else 链中加新分支
- 无法直接回答「光标在第几块、块内哪个 section」

### 目标

1. 消除所有重复的 `###` 边界扫描，统一为一份代码
2. 补全热路径从 O(n) 降为 O(1) 查表
3. 文档结构显式建模，后续扩展不需要改扫描逻辑
4. 行为零变化——补全内容和体验不变，只改内部查询方式

### 验收标准

- `detect_script_context` 不再调用 `nvim_buf_get_lines` 扫描——只用 `line_type[]` 查表
- `collect_request_vars` 不再调用 `find_request_block_bounds` 和 `nvim_buf_get_lines`
- Phase 3 完成后，`indicators.lua` 中 `find_request_block_bounds` 和 `find_request_line` 不再包含扫描逻辑——全是委托
- 全部现有测试通过
- 无 `###` 边界检测的重复实现残留

---

## 1. 数据模型（唯一确定结构）

只有一个结构：**`line_type` 数组** + **`blocks` 列表**。没有 `sections`。

```lua
--- 每个 buffer 一份，由 `cache.lua` 持有
--- 字段格式：类型后跟 `?` 表示该字段可能为 nil
buffer_blocks[buf] = {
  changedtick = ct,          -- vim.api.nvim_buf_get_changedtick(buf)

  --- 文件级区域（第一个 `###` 之前）
  file_vars    = { ["name"] = true, ... },
  file_imports = {
    { type = "bare",   path = "./auth.http" },
    { type = "aliased", path = "./orders.http", alias = "orders" },
  },

  --- 请求块列表（按文档顺序）
  blocks = {
    [1] = {
      name       = "Get Users",     -- ### 后文本，trim 后，可能为 ""
      start_line = 7,               -- ### 行号（1-indexed）
      end_line   = 42,              -- 块末行（下一个 ### - 1，或文件末尾）

      --- 预计算数据
      block_vars = { ["name"] = true, ... },  -- 块内所有 @var 定义名
      has_pre    = false,           -- 是否有 pre-script
      has_post   = false,           -- 是否有 post-script
      has_run    = false,           -- 是否有 run 指令
    },
    ...
  },

  --- 逐行类型映射（关键结构）
  --- key = 行号（1-indexed）
  --- value = 行类型字符串
  line_type = {
    [1]  = "file",         -- 文件级区域（import / @var / # comment / 空行）
    [2]  = "file",
    ...
    [7]  = "head",         -- ### 行
    [8]  = "var",          -- @var / @env 定义
    [9]  = "pre_script",   -- pre-script 行（< {%  或  < ./lua  或  内部行  或  %}）
    [10] = "pre_script",
    [11] = "prompt",       -- <<name 提示变量行
    [12] = "var",          -- @var 定义（与 pre-script 交错）
    [13] = "request",      -- METHOD URL 行
    [14] = "header",       -- Key: Value 行
    [15] = "header",
    [16] = "empty",        -- 空行（headers/body 分隔）
    [17] = "body",         -- body / run / file include / 注释
    [18] = "run",          -- run 指令行
    [19] = "body",         -- body 继续
    [20] = "empty",        -- 空行
    [21] = "post_script",  -- post-script 行（> {%  或  > ./lua  或  内部行  或  %}）
    [22] = "post_script",
    [23] = "post_script",
  },
}
```

**为什么不用 `sections` 而用 `line_type`：**
- block head 内 `@var` / pre-script / `<<var` 可以任意交错，连续区间无法精确表示
- `line_type` 对每个补全上下文的提问（「这一行属于哪？」）直接回答 O(1)
- `sections` 可以 `line_type` 推导，不需额外存储

---

## 2. 缓存归属（唯一确定位置）

**块索引建在 `cache.lua` 里，不改 `get_buffer_cache` 签名。**

具体做法：

```
cache.lua:
  get_buffer_cache(buf)  ← 现有函数，保留签名
    → 扫描 buffer（现有逻辑：收集 file_vars、req_names）
    → 新增同一遍扫描中同时构建 line_type、blocks
    → 返回的 cache table 新增字段：.line_type, .blocks, .file_imports

  新增查询函数（全部在 cache.lua 里）：
    get_line_type(buf, line)        → string|nil
    get_block_at_line(buf, line)    → block|nil
    get_block_vars(buf, line)       → { name = true }
    get_file_vars(buf)              → { name = true }（已有）
```

不新增 `block_index.lua`。所有逻辑实现在 `cache.lua` 内。原因是：
- 缓存生命周期和失效逻辑已由 `get_buffer_cache` 的 `changedtick` 守卫 + `ensure_cache_autocmd` 处理
- 新增模块需要重新处理 `BufDelete`、`TextChanged` 等 autocmd
- 块索引是 `get_buffer_cache` 的扩展，不是独立功能

---

## 3. 扫描算法（精确到行的分类规则）

单遍扫描 buffer 所有行，对每行做分类。分类优先级（第一个匹配命中）：

```
for each line in lines:
  trimmed = vim.trim(line)

  if past_first_block == false:
    if line:match("^%s*###"):
      past_first_block = true
      type = "head"
    elseif line:match("^@(%w[%w_]*)%s*[= ]"):
      type = "var"
      file_vars[name] = true
    elseif line:match("^import "):
      type = "file"        -- 行类型统一为 "file"
      parse_import_line()  → file_imports[]
    else:
      type = "file"        -- # comment / 空行 / 其他

  else (inside a request block):
    if line:match("^%s*###"):
      type = "head"        ← 上一个块结束，新块开始
    elseif line:match("^@(%w[%w_]*)%s*[= ]"):
      type = "var"
      block_vars[name] = true
    elseif line:match("^<%s*{%%") or line:match("^<%s*%.?%."):
      type = "pre_script"
      has_pre = true
    elseif in_pre_block:                    -- 在未完的 < {% 块内
      type = "pre_script"
      if trimmed == "%}": in_pre_block = false
    elseif line:match("^>%s*{%%") or line:match("^>%s*%.?%."):
      type = "post_script"
      has_post = true
    elseif in_post_block:                   -- 在未完的 > {% 块内
      type = "post_script"
      if trimmed == "%}": in_post_block = false
    elseif line:match("^%s*<<%w") or line:match("^%s*#%s*<<"):
      type = "prompt"
    elseif line:match("^[A-Z]+%s+%S"):
      if not request_found_in_block:
        type = "request"
        request_found_in_block = true
      else:
        type = "body"      -- 第二个大写单词打头行视为 body
    elseif line:match("^[%w%-]+%s*:"):
      type = "header"
    elseif line:match("^run "):
      type = "run"
      has_run = true
    elseif trimmed == "":
      type = "empty"
      if request_found_in_block and not body_started:
        body_started = true   -- 第一个空行 = headers/body 分隔
    else:
      type = "body"
```

关键规则：
- **请求行检测**：首词全大写、第二词非空。但只在当前块中第一个匹配生效（后续大写单词行算 body）
- **pre-script 范围**：`< {%` 到下一个 `%}` 之间所有行标记为 `"pre_script"`（含头和尾）
- **post-script 范围**：同上，`> {%` 到 `%}`
- **单行 pre/post**：`< {% code %}` / `> {% code %}` 一行内完成，整行标记为 pre_script/post_script
- **外部脚本**：`< ./path.lua` / `> ./path.lua` 整行标记 pre_script/post_script
- **header 检测**：`Key: Value` 格式。此规则可能匹配 `Date: 2024` 这类值，但不影响结构分类
- **body 范围**：第一个空行（在 request 找到后）之后的所有非 empty 行

---

## 4. API 映射（精确到行）

所有现有模块的查询，映射到新的 O(1) 查询：

| 查询 | 当前实现 | 新实现 |
|------|---------|--------|
| 是否在 pre-script 内 | `detect_script_context` O(n) 扫描 | `line_type[line] == "pre_script"` |
| 是否在 post-script 内 | 同上 | `line_type[line] == "post_script"` |
| 当前块的 block vars | `collect_request_vars` 重新扫描 buffer | `get_block_at_line().block_vars` |
| 当前块的 start/end | `find_request_block_bounds` 扫描 | `get_block_at_line().start_line / end_line` |
| 是否在 body 内 | 隐式：不是其他即 body | `line_type[line] == "body"` |
| 是否在 header 内 | `:match(":")` | `line_type[line] == "header"` |
| 是否在 head 内 | `:match("@")` / 空行判断 | `{"var","pre_script","prompt","head"} ~= nil` |
| 文件级变量 | `get_buffer_cache().file_vars` | 同样的字段 |
| 所有变量（当前块） | 两次扫描：file + block | `merge(file_vars, block_vars, env_vars)` |

---

## 5. TDD 开发流程

所有修改遵循 TDD：先写测试，再写实现。

### 测试框架

使用现有 `tests/run.sh`。在 `tests/` 下新增：

```
tests/test_block_index.lua         ← 块索引构建和查询测试
tests/data/http/                   ← 测试用 .http 文件
  ├── simple.http
  ├── interleave.http              ← @var 和 pre-script 交错
  ├── multi_block.http
  ├── no_blocks.http               ← 无 ### 的文件
  ├── minimal.http                 ← 只有 ###，无其他内容
  ├── prompt.http                  ← 含 <<name 提示变量
  ├── import_run.http              ← 含 import / run
  └── edge_cases.http              ← 各种边缘案例
```

### Phase 1 测试（`test_block_index.lua`）

先写，再实现 `cache.lua` 扫描扩展：

```lua
-- Test 1: 文件级变量
-- File: @base_url = http://example.com
--        @token = abc123
--        ### Get
-- Result: file_vars = { base_url = true, token = true }

-- Test 2: 块级变量
-- File: ### Get
--        @limit = 20
--        GET /users
-- Result: blocks[1].block_vars = { limit = true }

-- Test 3: line_type 映射
-- File: ### Get
--        @page = 1
--        GET /users
--        Content-Type: application/json
--
--        {"page":1}
-- Result: line_type = { [1]="head", [2]="var", [3]="request",
--                       [4]="header", [5]="empty", [6]="body" }

-- Test 4: pre-script 多行
-- Test 5: pre-script 单行
-- Test 6: post-script
-- Test 7: @var 和 pre-script 交错
-- Test 8: no ### → 全部是 "file"
-- Test 9: 空 ### 块
-- Test 10: <<name (prompt directive)
-- Test 11: run 指令
-- Test 12: import 文件级
-- Test 13: empty line 后 body 行类型
-- Test 14: get_block_at_line 边界（### 行、块内、块间空行）
-- Test 15: get_block_vars（文件级无 vars、块级有 vars）
```

### Phase 1 实现（cache.lua）

修改 `cache.lua` 中 `get_buffer_cache` 的扫描逻辑：

```
scan_lines(lines):
  → 返回 { file_vars, blocks[], line_type{}, file_imports[] }

替换现有扫描（lines 47-63），保持返回结构新增字段
```

**不允许**修改 `get_buffer_cache` 的调用签名。现有 callers（`collect_file_vars`、`collect_request_names`）保持不变。

### Phase 2 测试（`test_completion.lua` 增量）

```lua
-- Test: detect_script_context 使用 line_type
--   line_type = { [3]="pre_script" }
--   detect_context("some pre code", buf, 3, 5) → "pre_script"

-- Test: collect_request_vars 使用 block_vars
--   blocks[1].block_vars = { name = true }
--   collect_request_vars(buf, 5) → { name = true }
```

### Phase 2 实现

修改：
- `context_detector.lua:detect_script_context` — 从扫描改为 `line_type` 查询
- `context_detector.lua:detect_context` — 从 pattern 改为 `line_type` + 精确行判断
- `cache.lua:collect_request_vars` — 从重新扫描改为 `get_block_at_line().block_vars`
- `item_builder.lua:build_script_variable_items` 中相关调用

### Phase 3 测试

```lua
-- Test: find_request_block_bounds 委托
--   blocks[1] = { start=3, end=10 }
--   find_request_block_bounds(buf, 5) → 3, 10

-- Test: collect_requests 委托
--   blocks = [{name="A", start=1, end=5}, {name="B", start=7, end=10}]
--   collect_requests(buf) → [{name="A", start=1, end=5}, {name="B",start=7,end=10}]
```

### Phase 3 实现

逐个替换委托函数，每次替换运行一次测试验证等价性：

```
1. indicators.lua:find_request_block_bounds
   → 内部调用 cache.get_block_at_line(buf, line)

2. request_vars.lua:collect_requests
   → 内部调用 cache.get_buffer_cache(buf).blocks

3. boundary_indicator.lua:find_block
   → delegate

4. symbols.lua:collect_requests
   → delegate

5. import.lua:extract_request_names
   → 如果参数是 buffer 不是 content string，走 block index
```

---

## 6. 测试运行

```bash
# 全部测试
tests/run.sh

# 仅块索引测试
tests/run.sh test_block_index

# 仅补全测试
tests/run.sh test_completion
```

每个 Phase 合并后运行全部测试确保无回归。

---

## 7. 不做的

- 不在 `context_detector.lua` 中缓存 `line_type` 的查询结果（`cache.lua` 的 `changedtick` 已足够）
- 不在 `cache.lua` 外暴露 `line_type` / `blocks` 的原始 table（通过查询函数访问，便于后期改内部结构）
- 不修改 `data.lua`
- 不修改 `completion.lua`（适配器层）
- 不修改 `get_buffer_cache` 签名
- 不修改 Rust 端
