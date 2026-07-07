# Poste Prompt 增强方案：结构化选项 + 动态映射

## 1. 背景

当前 `<<var [opt1, opt2]` 只支持纯 `string[]`，picker 显示的就是选项值本身，选中后值直接作为变量填入请求。

已有基础设施：
- `select.lua` 的 `normalize_items` 已支持 `{name, key, description}` 结构
- `Snacks.picker.select` 的 `format_item` 已渲染 `name + description`
- 回调返回 `item.key` 作为选中值

需要补齐：
- **语法解析**：将 `|` 分隔的 tuple 解析为 `{name, key, description}`
- **动态映射**：支持 `| {name: path, key: path, desc: path}` 从 response 中提取三字段
- **高亮**：新语法元素在 `poste_http.vim` 中高亮
- **补全**：新语法元素的自动补全
- **文档**：更新说明文档

---

## 2. 语法设计

### 2.1 静态 tuple（`|` 分隔）

```http
# 向后兼容：纯 string[]
<<method [GET, POST, PUT, DELETE]

# 2字段：name|key
<<method [GET|get, POST|post]

# 3字段：name|key|description
<<method [GET|get|send a GET request, POST|post|send a POST request]
```

**解析规则**（对括号 `[...]` 内按逗号切分后的每个 token）：

| 格式 | name | key | description |
|------|------|-----|-------------|
| `GET` | `"GET"` | `"GET"` | `""` |
| `GET|get` | `"GET"` | `"get"` | `""` |
| `GET|get|send request` | `"GET"` | `"get"` | `"send request"` |

- 0 个 `|` → string（兼容旧语法）
- 1 个 `|` → `[name, key]`
- 2+ 个 `|` → `[name, key, 后面所有]`（description 中可以包含 `|`）

Picker 显示效果：

```
▶ GET    send a GET request
  POST   send a POST request
  PUT    send a PUT request
```

选中 `GET` 后，写入 `@method = get`（注意是 key 而非 name）。

### 2.2 动态映射（pipe + jq 风格投影）

```http
# 将一个请求的 response body（array）映射为 picker 选项
<<email [{{request_1.response.body | {name: .[].commit.author.name, key: .[].commit.author.email, desc: .[].commit.author.name} }}]
```

**语法**：`{{<response_ref> | {name: <path>, key: <path>, desc: <path>} }}`

- `<response_ref>`：已有的 `RequestName.response.body[.path]` 语法
- `|`：pipe，分隔 response ref 和映射表达式
- `{name: <path>, key: <path>, desc: <path>}`：jq 风格的 object 构造
  - 顺序不敏感
  - 字段名支持 `name` / `key` / `desc` / `description`
- `<path>`：点分路径，支持 `[]` 通配符（复用现有的 `get_nested_value` / `resolve_segments`）

**可选简写**：如果省掉 `|` 右侧的映射，且 response body 已经是 `[{name, key, description}]` 结构，直接使用：

```http
<<email [{{request_1.response.body}}]
```

### 2.3 向后兼容

所有旧语法继续工作：

```http
<<username                        → text input（不变）
<<method [GET, POST]              → string[] picker（不变）
<<var [{{Req.response.body.f}}]   → dynamic string[]（不变）
```

---

## 3. 实现步骤（TDD）

### Step 1：新测试文件 `tests/request_vars_structured_spec.lua`

遵循现有测试模式（参考 `tests/test_completion_context_spec.lua`），使用 `describe`/`it` 和 `assert`。

需要测试的用例：

#### 静态 tuple 解析（单元测试 `parse_structured_options`）

```lua
it("parses simple string options")
  -- input: "GET, POST, PUT"
  -- → [{name="GET",key="GET"},{name="POST",key="POST"},{name="PUT",key="PUT"}]

it("parses 2-field tuples with |")
  -- input: "GET|get, POST|post"
  -- → [{name="GET",key="get"},{name="POST",key="post"}]

it("parses 3-field tuples with |")
  -- input: "GET|get|This is GET, POST|post|This is POST"
  -- → [{name="GET",key="get",desc="This is GET"},{name="POST",key="post",desc="This is POST"}]

it("handles | in description")
  -- input: "A|a|desc with | pipe"
  -- → [{name="A",key="a",desc="desc with | pipe"}]

it("trims whitespace around name/key")
  -- input: "GET | get | GET method, POST|post"
  -- → [{name="GET",key="get",desc="GET method"},{name="POST",key="post"}]

it("handles single option without comma")
  -- input: "GET|get"
  -- → [{name="GET",key="get"}]

it("handles empty description")
  -- input: "GET|get|"
  -- → [{name="GET",key="get",desc=""}]
```

#### 动态映射表达式解析（单元测试 `parse_dynamic_mapping`）

```lua
it("parses simple response ref without mapping")
  -- input: "RequestName.response.body"
  -- → { ref="RequestName.response.body", mapping=nil }

it("parses response ref with pipe and mapping")
  -- input: "RequestName.response.body | {name: .[].login, key: .[].id}"
  -- → { ref="RequestName.response.body", mapping={name=".[].login", key=".[].id"} }

it("parses mapping with dots and brackets")
  -- input: "Req.resp.body | {name: .[].author.name, key: .[].author.email, desc: .[].author.bio}"
  -- → { ref="Req.resp.body", mapping={name=".[].author.name", key=".[].author.email", desc=".[].author.bio"} }

it("parses mapping with description alias")
  -- input: "... | {name: .x, key: .y, description: .z}"
  -- → { ref="...", mapping={name=".x", key=".y", description=".z"} }

it("handles no space around pipe")
  -- input: "Req.body|{name: .x, key: .y}"
  -- → { ref="Req.body", mapping={name=".x", key=".y"} }
```

#### 映射应用（单元测试 `apply_jq_mapping`）

```lua
it("applies mapping to array of objects")
  -- data = [{login="a", id=1}, {login="b", id=2}]
  -- mapping = {name=".[].login", key=".[].id"}
  -- → [{name="a", key="1"}, {name="b", key="2"}]

it("applies mapping with nested paths")
  -- data = [{author: {name: "Alice", email: "a@x.com"}}, {author: {name: "Bob", email: "b@x.com"}}]
  -- mapping = {name=".[].author.name", key=".[].author.email"}
  -- → [{name="Alice", key="a@x.com"}, {name="Bob", key="b@x.com"}]

it("returns empty array for empty input")
  -- data = []
  -- → []

it("handles single object (not array)")
  -- data = {login: "admin", id: 0}
  -- mapping = {name=".login", key=".id"}
  -- → [{name="admin", key="0"}]
```

#### 集成测试

```lua
it("static tuples passes {name,key,desc} to picker")
it("dynamic mapping builds {name,key,desc} from mock response")
it("string[] fallback still produces {name,key} via normalize_items")
it("select callback writes @var = key into result")
it("cancel returns nil")
```

### Step 2：实现解析函数 `request_vars.lua`

在 `request_vars.lua` 中新增三个函数：

#### `parse_structured_options(options_str)`

```lua
--- Parse options string into {name, key, description}[].
--- @param options_str string  Content inside [...] (comma-separated)
--- @return table  Array of {name, key, description}
local function parse_structured_options(options_str)
  local result = {}
  for opt in options_str:gmatch("[^,]+") do
    local trimmed = vim.trim(opt)
    if trimmed ~= "" then
      -- Split by | to detect structured tuple
      local parts = vim.split(trimmed, "|", { plain = true })
      if #parts == 1 then
        -- Simple string (backward compatible)
        local name = vim.trim(parts[1])
        table.insert(result, { name = name, key = name, description = "" })
      else
        -- Structured: name|key[|description...]
        local name = vim.trim(parts[1])
        local key = vim.trim(parts[2])
        -- Rest is description (join with | to preserve | in desc)
        local desc_parts = {}
        for i = 3, #parts do
          table.insert(desc_parts, parts[i])
        end
        local description = vim.trim(table.concat(desc_parts, "|"))
        table.insert(result, { name = name, key = key, description = description })
      end
    end
  end
  return result
end
```

#### `parse_dynamic_mapping(options_str)`

```lua
--- Parse dynamic mapping expression from options string.
--- Looks for pattern: "{{<ref> | {name: path, key: path, desc: path} }}"
--- @param options_str string
--- @return string|nil ref, table|nil mapping
local function parse_dynamic_mapping(options_str)
  -- Extract {{...}} ref from options string
  local ref = options_str:match("{{([^}]+)}}")
  if not ref then return nil, nil end
  -- Check for pipe + mapping
  local response_ref, mapping_expr = ref:match("^(.-)%s*|%s*{(.-)}$")
  if not response_ref then
    return ref, nil
  end
  -- Parse mapping fields from "{name: path, key: path, desc: path}"
  local mapping = {}
  for field_expr in mapping_expr:gmatch("[^,]+") do
    local field, path = field_expr:match("^%s*(%w+)%s*:%s*(.+)$")
    if field and path then
      -- Normalize field name: desc -> description
      field = field == "desc" and "description" or field
      mapping[field] = vim.trim(path)
    end
  end
  return response_ref, mapping
end
```

#### `apply_jq_mapping(value, mapping)`

```lua
--- Apply jq-style path mapping to resolved response data.
--- @param value table  Response data (array or single object)
--- @param mapping table  {name="path", key="path", description="path"}
--- @return table  Array of {name, key, description}
local function apply_jq_mapping(value, mapping)
  -- Normalize to array
  local items = type(value) == "table" and vim.tbl_islist(value) and value or { value }
  local result = {}
  for _, item in ipairs(items) do
    if type(item) == "table" then
      local entry = {}
      for _, field in ipairs({ "name", "key", "description" }) do
        if mapping[field] then
          local resolved = get_nested_value(item, mapping[field])
          entry[field] = resolved ~= nil and tostring(resolved) or ""
        end
      end
      if entry.name or entry.key then
        table.insert(result, entry)
      end
    end
  end
  return result
end
```

然后修改 `handle_prompt_variables` 中的两段逻辑：

**a) 静态选项路径**（当前第 614-637 行）：

```lua
-- 原来：
local options = {}
for opt in options_str:gmatch("[^,]+") do
  table.insert(options, vim.trim(opt))
end
poste_select.select(options, prompt, callback)

-- 改为：
local options = parse_structured_options(options_str)
poste_select.select(options, prompt, callback)
```

**b) 动态选项路径**（当前第 525-610 行）：

```lua
-- 在 resolve 出 value 后，判断是否有 pipe + mapping：
local ref_text, mapping = parse_dynamic_mapping(options_str)
if mapping then
  local items = apply_jq_mapping(value, mapping)
  if #items > 0 then
    poste_select.select(items, prompt, callback)
    return
  end
end
-- 回退到原有 flatten 逻辑（向后兼容）
```

### Step 3：语法高亮更新

#### `syntax/poste_http.vim`

新增高亮组：

```vim
" | separator inside prompt options
syn match PostePromptOptSep '|' contained

" {name: path, key: path, desc: path} inside dynamic options
syn region PostePromptMapping start='{' end='}' contained
  \ contains=PostePromptMappingField,PostePromptMappingPath,PostePromptMappingColon
syn match PostePromptMappingField '\<name\|key\|desc\|\%(description\)\>' contained
syn match PostePromptMappingColon ':' contained
syn match PostePromptMappingPath '\.[^,}]*' contained

" Update PostePromptOpts to include new contained groups
syn match PostePromptOpts '\[.\{-}\]' contained
  \ contains=PosteVarRef,PosteMagicVar,PostePromptOptSep,PostePromptMapping
```

高亮组链接：

```vim
hi def link PostePromptOptSep     Delimiter
hi def link PostePromptMappingField  Type
hi def link PostePromptMappingColon  Operator
hi def link PostePromptMappingPath   Identifier
```

#### `lua/poste/http/highlights.lua`

在 `syntax_links` 列表和 `state.apply_highlight_overrides` 调用中添加：

```lua
{ "PostePromptOptSep",    "Delimiter" },
{ "PostePromptMappingField", "Type" },
{ "PostePromptMappingColon", "Operator" },
{ "PostePromptMappingPath",  "Identifier" },
```

### Step 4：补全更新

#### `lua/poste/http/data.lua`

新增：

```lua
M.prompt_mapping_fields = { "name", "key", "desc", "description" }
```

#### `lua/poste/http/context_detector.lua`

在 `detect_context` 中检测 pipe 后的 mapping 上下文：

```lua
-- Inside the variable context detection block:
-- If after_open has pipe followed by {, offer mapping field completion
if after_open:match("|%s*{%s*$") or after_open:match("|%s*{%s*%w*$") then
  return "prompt_mapping", after_open
end
```

#### `lua/poste/http/item_builder.lua`

在 `get_items_for_context` 中添加 `"prompt_mapping"` 上下文处理：

```lua
elseif ctx == "prompt_mapping" then
  items = M.build_keyword_items(data.prompt_mapping_fields, KIND_PROPERTY)
  return items
end
```

### Step 5：文档更新

#### `README.md`

在 Prompt Variables 章节添加新语法说明：

```markdown
## Prompt Variables

Prompt variables allow interactive input when running a request.

### Syntax

- `<<varname` — text input prompt
- `<<varname [opt1, opt2, ...]` — selection from list (simple strings)
- `<<varname [name|key|desc, name|key|desc]` — selection with display name, substitution key, and description

  Example:
  ```http
  <<method [GET|get|Send a GET request, POST|post|Send a POST request]
  ```
  Picker shows:
  ```
  ▶ GET    Send a GET request
    POST   Send a POST request
  ```
  Selecting `GET` substitutes `@method = get` in the request.

- `<<varname [{{Req.response.body | {name: path, key: path, desc: path} }}]` — dynamic options from another request's response with jq-style mapping

  Example:
  ```http
  <<email [{{1.response.body | {name: .[].commit.author.name, key: .[].commit.author.email, desc: .[].commit.author.name} }}]
  ```

  If the response body is already in `{name, key, description}` format, the mapping can be omitted:
  ```http
  <<email [{{1.response.body}}]
  ```
```

---

## 4. 涉及文件清单

| 文件 | 操作 | 说明 |
|------|------|------|
| `lua/poste/http/request_vars.lua` | **修改** | 新增 `parse_structured_options`, `parse_dynamic_mapping`, `apply_jq_mapping`；修改 `handle_prompt_variables` |
| `syntax/poste_http.vim` | **修改** | 新增 `PostePromptOptSep`, `PostePromptMapping`, `PostePromptMappingField`, `PostePromptMappingColon`, `PostePromptMappingPath` |
| `lua/poste/http/highlights.lua` | **修改** | 注册新 highlight 组 |
| `lua/poste/http/data.lua` | **修改** | 新增 `prompt_mapping_fields` |
| `lua/poste/http/context_detector.lua` | **修改** | 新增 `prompt_mapping` context 检测 |
| `lua/poste/http/item_builder.lua` | **修改** | 新增 `prompt_mapping` 上下文补全 |
| `tests/request_vars_structured_spec.lua` | **新建** | TDD 测试用例 |
| `README.md` | **修改** | 更新 Prompt Variables 文档 |

**不需要修改：**
- `lua/poste/select.lua` — 已支持 `{name, key, description}`
- `lua/poste/http/cache.lua` — line_type 检测不变
- `lua/poste/http/completion.lua` — 通过 data/item_builder/context_detector 间接更新

---

## 5. 优先级顺序

| 优先级 | 任务 | 估算 |
|--------|------|------|
| **P0** | Step 2a: `parse_structured_options` + 集成到静态路径 | ~2h |
| **P0** | Step 1: 测试用例（静态部分） | ~2h |
| **P0** | Step 3: 语法高亮 `|` | ~1h |
| **P1** | Step 2b: `parse_dynamic_mapping` + `apply_jq_mapping` + 集成 | ~3h |
| **P1** | Step 1: 测试用例（动态部分） | ~2h |
| **P1** | Step 3: 动态映射高亮 `{name: path}` | ~1h |
| **P2** | Step 4: 补全提示 | ~1.5h |
| **P2** | Step 5: 文档更新 | ~1h |

**建议实施顺序**：P0 静态 tuple → P0 高亮 → P1 动态映射 → P1 动态高亮 → P2 补全 → P2 文档

---

## 6. 完整示例

```http
### 1. Get users (dependency)
GET https://api.github.com/repos/folke/snacks.nvim/commits
Accept: application/json

### 2. Send email (consumer)
# Static tuple: name|key|description
<<method [GET|get|HTTP GET method, POST|post|HTTP POST method, PUT|put|HTTP PUT method]

# Dynamic mapping from request_1 response
# Extract author info from commit list
<<email [{{1.response.body | {name: .[].commit.author.name, key: .[].commit.author.email, desc: .[].commit.author.name} }}]

POST https://httpbin.org/post
Content-Type: application/json

{
  "method": "{{method}}",
  "email": "{{email}}"
}
```

Picker 运行时显示：

```
For 'method':
  ▶ GET    HTTP GET method
    POST   HTTP POST method
    PUT    HTTP PUT method

For 'email':
  ▶ Alice  alice@example.com
    Bob    bob@example.com
```

选中后实际发送的请求：

```json
{
  "method": "get",
  "email": "alice@example.com"
}
```
