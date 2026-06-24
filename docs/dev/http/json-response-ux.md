# JSON 响应体验设计

## 1. 背景

HTTP 响应 JSON body 展示体验目前是"空白区"：

| 能力 | 现状 |
|------|------|
| 语法高亮 | ✅ treesitter (filetype=json) |
| 格式化 | ✅ `pretty_body()` Lua pretty-printer |
| 折叠展开 | ❌ 无 |
| jq 过滤 | ❌ 无 |
| Raw/Pretty 切换 | ❌ 无 |
| JSON 专属 keymap | ❌ 无 |

目标：在现有 body 视图之上，为 JSON 响应添加 Vim 原生风格的折叠和 jq 探索能力。

---

## 2. 架构

纯 Lua 实现，零 Rust 变更。通过 `vim.api` 和 `vim.fn` 与 Neovim 原生机制交互。

```
view.lua (show_view "body")
  │
  ├─ filetype=json?
  │   ├─ 是 → 激活 json.lua 模块
  │   └─ 否 → 现有流程不变
  │
  └─ json.lua
      ├─ setup_buffer(buf)      → 设置 foldmethod, foldlevel, extmarks
      ├─ apply_filter(query)    → jq 子进程 → 替换 buffer 内容
      ├─ restore_original()     → 恢复原始 pretty-printed body
      ├─ toggle_raw()           → raw body ↔ pretty body 切换
      └─ get_key_paths()        → 提取 JSON key 列表（大纲导航用）
```

---

## 3. 模块：`lua/poste/http/json.lua`（新建）

### 3.1 `json.setup_buffer(buf)`

在 `render_buffer()` 中，当 filetype=json 时调用。

```lua
function M.setup_buffer(buf)
  vim.wo[buf].foldmethod = "indent"
  vim.wo[buf].foldlevel = 99
  vim.wo[buf].foldcolumn = "1"
end
```

| 选项 | 值 | 原因 |
|------|----|------|
| `foldmethod` | `"indent"` | `json_pretty()` 输出 2-space indent，天然适配 |
| `foldlevel` | `99` | 默认全部展开，用户按需折叠 |
| `foldcolumn` | `"1"` | 左侧 1 列显示折叠标记 |

如果安装了 `nvim-treesitter` 且支持 `foldexpr`，可覆写为：

```lua
if pcall(require, "nvim-treesitter") then
  vim.wo[buf].foldexpr = "nvim_treesitter#foldexpr()"
end
```

### 3.2 `json.apply_filter(query)`

```lua
function M.apply_filter(query)
  local r = state.last_response
  if not r or not r.body then return end

  -- 缓存原始 lines（仅在首次调用时缓存）
  if not state._json.original_lines then
    local buf = require("poste.http.buffer").get_buf()
    state._json.original_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  end

  local result
  if vim.fn.executable("jq") == 1 then
    -- 用 -r raw 输出 + JSON 着色
    local ok, output, _ = pcall(vim.fn.system, { "jq", query, "-r" }, r.body)
    if ok then
      -- 尝试解析为 JSON 再 pretty-print
      local parsed, err = pcall(vim.json.decode, output)
      if parsed then
        result = require("poste.http.format").pretty_body(output, "application/json")
      else
        result = output -- raw 输出（如 .data | length 返回纯数字）
      end
    else
      vim.notify("jq error: " .. (output or "unknown"), vim.log.levels.ERROR)
      return
    end
  else
    -- Lua JSONPath 回退（简化版）
    result = M._jsonpath_query(r.body, query)
  end

  if not result then return end

  -- 替换 buffer
  local buf = require("poste.http.buffer").get_buf()
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(result, "\n"))
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

  -- 更新状态
  state._json.query = query
  state._json.is_filtered = true
end
```

### 3.3 `json.restore_original()`

```lua
function M.restore_original()
  if not state._json.original_lines then return end

  local buf = require("poste.http.buffer").get_buf()
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, state._json.original_lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

  state._json.original_lines = nil
  state._json.query = nil
  state._json.is_filtered = false
end
```

### 3.4 `json.toggle_raw()`

```lua
function M.toggle_raw()
  state._json.pretty_mode = not state._json.pretty_mode
  local r = state.last_response
  local body = state._json.pretty_mode
    and require("poste.http.format").pretty_body(r.body, r.content_type)
    or r.body

  local buf = require("poste.http.buffer").get_buf()
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(body, "\n"))
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
end
```

### 3.5 `json.get_key_paths()` — 大纲导航（可选 Phase 2）

```lua
--- 递归提取 JSON 的 key 路径 + 行号
function M.get_key_paths()
  local buf = require("poste.http.buffer").get_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local paths = {}  -- { { path = ".data.items[0].name", lnum = 42 }, ... }
  -- 简单实现: 扫描行首缩进 + key pattern，构建路径栈
  return paths
end
```

### 3.6 Lua JSONPath 回退（jq 不可用时）

实现最小可用子集：

| 表达式 | 含义 | 示例 |
|--------|------|------|
| `.key` | 对象属性 | `.data` |
| `.key1.key2` | 嵌套属性 | `.data.user.name` |
| `.[n]` | 数组索引 | `.items[0]` |
| `.[]` | 数组遍历 | `.items[]` |
| `.[].key` | 遍历后取属性 | `.items[].name` |

不支持 filter 表达式（`.key?`, `select()` 等）— 提示用户安装 jq。

```lua
function M._jsonpath_query(body, query)
  local ok, data = pcall(vim.json.decode, body)
  if not ok then
    vim.notify("Invalid JSON body", vim.log.levels.ERROR)
    return nil
  end

  local steps = {}
  for step in query:gmatch("[^.]+") do
    table.insert(steps, step)
  end

  local current = data
  for _, step in ipairs(steps) do
    if type(current) ~= "table" then
      vim.notify("Cannot traverse: value is " .. type(current), vim.log.levels.WARN)
      return nil
    end

    -- Array index: [0]
    local idx = step:match("^%[(%d+)%]$")
    if idx then
      current = current[tonumber(idx) + 1]  -- JSONPath uses 0-based
    -- Array wildcard: []
    elseif step:match("^%[%]$") then
      local results = {}
      for _, item in ipairs(current) do
        table.insert(results, item)
      end
      current = results
    -- Object key: .key
    else
      -- Strip leading dot if present
      local key = step:match("^%.(.+)") or step
      if current[key] ~= nil then
        current = current[key]
      else
        vim.notify("Key '" .. key .. "' not found", vim.log.levels.WARN)
        return nil
      end
    end
  end

  return require("poste.http.format").pretty_body(vim.json.encode(current), "application/json")
end
```

---

## 4. 修改：`lua/poste/http/view.lua`

在 `show_view("body")` 分支中，当 filetype=json 时激活 json 模块：

```lua
if view == "body" then
  -- ... existing code ...
  lines = format.format_body(state.last_response)
  filetype = format.detect_filetype(state.last_response.content_type)
end

-- ↓ 新增 ↓
-- 在 render_buffer 调用后激活 json 能力
buffer.render_buffer(lines, filetype)

if filetype == "json" then
  local json = require("poste.http.json")
  local buf = buffer.get_buf()
  json.setup_buffer(buf)
  json.attach_keymaps(buf)
end
```

---

## 5. 修改：`lua/poste/http/buffer.lua`

### 5.1 响应缓冲区的 fold 配置

`get_response_buffer()` 中新增：

```lua
-- 初始窗口选项（在 split 打开后设置）
vim.wo[response_window].foldenable = true
```

### 5.2 keymap 注册

`get_response_buffer()` 中注册 JSON 专属 keymaps：

```lua
-- JSON filter (仅 filetype=json 时可通过 json.attach_keymaps 按需注册，
-- 但统一在 get_response_buffer 注册可以减少复杂度)
local k = state.get_keymap("http_response", "json_filter", "<leader>j")
if k then
  vim.keymap.set("n", k, function()
    local buf = vim.api.nvim_get_current_buf()
    local ft = vim.bo[buf].filetype
    if ft ~= "json" then return end

    vim.ui.input({ prompt = "jq> " }, function(query)
      if not query or query == "" then return end
      require("poste.http.json").apply_filter(query)
    end)
  end, opts)
end
```

---

## 6. 修改：`lua/poste/state.lua`

### 6.1 新增 JSON 状态字段

```lua
--- JSON response UX state (isolated from SQL)
M._json = {
  original_lines = nil,   -- cached buffer lines before filter
  query = nil,            -- current jq query string, nil if no filter
  is_filtered = false,    -- true when buffer shows filtered result
  pretty_mode = true,     -- true = pretty-printed, false = raw body
}
```

### 6.2 keymaps 配置

```lua
keymaps = {
  http_response = {
    -- ... existing ...
    json_filter = "<leader>j",      -- jq filter prompt
    json_restore = "<leader>jc",    -- clear filter / restore original
    json_toggle_raw = "<leader>jr", -- toggle raw/pretty display
    json_outline = "<leader>jo",    -- key path outline (Phase 2)
  },
}
```

---

## 7. 交互细节

### 7.1 jq 过滤流程

```
[body 视图, filetype=json]
  │
  ├─ <leader>j
  │   ├─ cmdline 显示: jq>
  │   ├─ 用户输入 .data.items | .[].name
  │   ├─ 按 <CR> 执行
  │   │   ├─ jq 存在 → vim.fn.system({"jq", "-r", query}, body)
  │   │   ├─ jq 不存在 → Lua JSONPath 回退
  │   │   └─ 结果替换 buffer 内容
  │   ├─ winbar 更新:
  │   │   Body [H] | jq: .data.items | .[].name
  │   └─ buffer 左下方显示标记: [filtered]
  │
  ├─ <leader>jc
  │   ├─ 恢复 original_lines
  │   ├─ 清空 query
  │   └─ winbar 恢复: Body [H]
  │
  └─ q (关闭窗口) / r (重新运行)
      └─ 自动清除 filter 状态 (重新渲染时 original_lines 已过期)
```

### 7.2 折叠交互

```
za         切换当前节点折叠
zR         全部展开
zM         全部折叠
zc         折叠当前节点
zo         展开当前节点
zr         减少折叠层级 (展开一层)
zm         增加折叠层级 (折叠一层)

[10] {                              ← foldcolumn 显示折叠标记
  >   "data": {                     ← 已折叠的 object (显示 ...)
  >   "meta": {                     ← 已折叠的 object
  >   "items": [                     ← 已折叠的 array
}
```

### 7.3 多响应导航时的状态清理

`navigate_response()` 中需要重置 filter 状态：

```lua
function M.navigate_response(direction)
  -- ... existing ...
  -- Reset JSON filter state
  state._json.original_lines = nil
  state._json.query = nil
  state._json.is_filtered = false
  -- ... re-render ...
end
```

同样，`rerun` 和窗口关闭时也需要清理。

---

## 8. 实施步骤

### Phase 1 — 折叠（~1h）

| # | 文件 | 动作 |
|---|------|------|
| 1 | `lua/poste/http/json.lua` | 新建，实现 `setup_buffer()` |
| 2 | `lua/poste/http/view.lua` | `show_view("body")` 分支，filetype=json 时调用 `json.setup_buffer()` |
| 3 | `lua/poste/state.lua` | 新增 `M._json` 字段 + keymap 条目 |

### Phase 2 — jq 过滤（~2h）

| # | 文件 | 动作 |
|---|------|------|
| 1 | `lua/poste/http/json.lua` | 实现 `apply_filter()`, `restore_original()`, `_jsonpath_query()` |
| 2 | `lua/poste/http/buffer.lua` | 注册 `<leader>j`/`<leader>jc` keymaps |
| 3 | `lua/poste/http/buffer.lua` | `navigate_response()` 中清理 filter 状态 |
| 4 | `lua/poste/http/view.lua` | winbar 显示 jq query（过滤模式下） |

### Phase 3 — Raw/Pretty 切换 + 大纲导航（~1h, 可选）

| # | 文件 | 动作 |
|---|------|------|
| 1 | `lua/poste/http/json.lua` | 实现 `toggle_raw()`, `get_key_paths()` |
| 2 | `lua/poste/http/buffer.lua` | 注册 `<leader>jr`/`<leader>jo` keymaps |

---

## 9. 依赖

### jq binary（推荐但非必须）

- macOS: `brew install jq`
- Linux: `apt install jq` / `yum install jq`
- 检测: `vim.fn.executable("jq") == 1`
- 不可用时自动降级为 Lua JSONPath 子集

### 安全性

- jq 作为子进程调用，query 字符串不用 shell 转义（用 `vim.fn.system({...}, body)` 的 list 形式避免 shell injection）
- query 内容来自用户输入，不做 eval

---

## 10. 与现有功能的关系

| 功能 | 影响 |
|------|------|
| HTTP curl 执行 | 无 — json.lua 仅影响响应展示层 |
| Redis 响应 | 无 — filetype 非 json，不激活 |
| SQL 响应 | 无 — SQL 用 dataset 视图而非 body 视图 |
| 多响应导航 | 需在 `navigate_response()` 中清理 filter 状态 |
| 重新执行 | 重新渲染时 `render_buffer()` 覆盖 buffer，filter 自动失效 |
| 断言/脚本视图 | 无 — filetype 为 markdown |
