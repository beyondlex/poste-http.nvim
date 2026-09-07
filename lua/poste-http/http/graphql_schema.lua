--- GraphQL schema-aware completion: SDL parsing, the `# @graphql-schema`
--- block operator, and field/argument/enum/type completion inside GRAPHQL
--- request bodies. Blueprint: grpc_proto.lua (parse / block info /
--- body_context / items), but everything here is offline and synchronous —
--- the schema is a plain SDL file read once per mtime, so there is no
--- background prewarm machinery.
---
--- Completion contract with item_builder: `get_body_items` returns nil when
--- no schema is pinned (caller falls back to GraphQL keywords), or a (possibly
--- empty) item list when one is.

local M = {}

local cache = require("poste-http.http.cache")
local block_operators = require("poste-http.http.block_operators")
local vars = require("poste-http.http.vars")

local uv = vim.uv or vim.loop

--- Built-in scalars (always valid type names in variable definitions).
local BUILTIN_SCALARS = { Int = true, Float = true, String = true, Boolean = true, ID = true }

--- Per-buffer schema cache: buf -> { keys = { [path] = key }, schemas = { [path] = schema } }
M._cache = {}

--- Overridable I/O hooks (tests).
M.fs_stat = function(path) return uv.fs_stat(path) end
M.read_file = function(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return content
end

--- Strip list/nonnull wrappers and leading namespace dots: "[Order!]!" -> "Order".
function M.base_type(t)
  if not t then return nil end
  return (t:gsub("[%[%]!%s]", ""):gsub("^%.", ""))
end

local DEF_KEYWORDS = {
  schema = true, scalar = true, ["type"] = true, input = true,
  interface = true, union = true, enum = true, directive = true,
}

--- Replace """...""" description blocks (no lazy patterns in Lua, so scan).
local function strip_block_strings(text)
  local out = {}
  local i = 1
  while i <= #text do
    local s = text:find('"""', i, true)
    if not s then
      out[#out + 1] = text:sub(i)
      break
    end
    out[#out + 1] = text:sub(i, s - 1)
    out[#out + 1] = " "
    local e = text:find('"""', s + 3, true)
    if not e then break end -- unterminated: drop the rest
    i = e + 3
  end
  return table.concat(out)
end

--- Body text between the first top-level `{` and its matching `}`.
local function brace_body(text)
  local open = text:find("{", 1, true)
  if not open then return nil end
  local depth = 0
  for i = open, #text do
    local c = text:sub(i, i)
    if c == "{" then
      depth = depth + 1
    elseif c == "}" then
      depth = depth - 1
      if depth == 0 then
        return text:sub(open + 1, i - 1)
      end
    end
  end
  return text:sub(open + 1)
end

--- Parse one field definition: `name(arg: T = d, ...): Type`.
--- Argument defaults are stripped naively (a `=` inside a string default
--- truncates), and comma splitting ignores object-literal defaults — both
--- are acceptable for completion purposes.
local function parse_field(line)
  local fname = line:match("^%s*([%w_]+)%s*")
  if not fname then return nil end
  local rest = line:sub(#fname + 1):match("^%s*(.*)$") or ""
  local field = { type = nil, args = nil }

  if rest:sub(1, 1) == "(" then
    local close = rest:find(")", 1, true)
    if close then
      local args_text = rest:sub(2, close - 1)
      rest = rest:sub(close + 1)
      for _, piece in ipairs(vim.split(args_text, ",", { plain = true })) do
        piece = (piece:gsub("=.*$", ""))
        local aname, atype = piece:match("^%s*([%w_]+)%s*:%s*(.-)%s*$")
        if aname and atype ~= "" then
          field.args = field.args or {}
          field.args[aname] = atype
        end
      end
    end
  end

  local ftype = rest:match("^%s*:%s*(.-)%s*$")
  if not ftype or ftype == "" then return nil end
  field.type = ftype
  return fname, field
end

--- Collect field definitions from a type body; lines are joined while their
--- parens stay unbalanced (multi-line argument lists).
local function parse_type_body(body)
  local fields = {}
  local pending = nil
  for line in body:gmatch("[^\n]+") do
    local t = vim.trim(line)
    if t ~= "" then
      pending = pending and (pending .. " " .. t) or t
      local opens = select(2, pending:gsub("%(", ""))
      local closes = select(2, pending:gsub("%)", ""))
      if opens == closes then
        local fname, field = parse_field(pending)
        if fname then fields[fname] = field end
        pending = nil
      end
    end
  end
  return fields
end

--- Parse GraphQL SDL into a completion index:
---   types   = { [name] = { kind = "object"|"input"|"interface",
---                          fields = { [fname] = { type, args = { [aname] = T } } } } }
---   enums   = { [name] = { values = { ... } } }
---   unions  = { [name] = { members = { ... } } }
---   scalars = { [name] = true }  (includes the five built-ins)
---   roots   = { query/mutation/subscription -> type name }
function M.parse_sdl(text)
  local schema = {
    types = {},
    enums = {},
    unions = {},
    scalars = vim.deepcopy(BUILTIN_SCALARS),
    roots = { query = "Query", mutation = "Mutation", subscription = "Subscription" },
  }
  if not text or text == "" then return schema end

  text = strip_block_strings(text)
  text = (text:gsub('"[^"]*"', " "))
  text = text:gsub("#[^\n]*", "")
  -- strip directive usages; directive DEFINITIONS are skipped wholesale by
  -- the slicer below
  text = text:gsub("@%s*[%w_]+%s*%b()", "")
  text = text:gsub("@%s*[%w_]+", "")

  -- slice the document at definition keywords; `extend` is folded into the
  -- following keyword's slice so the keyword check stays uniform. Keywords
  -- only count at the top level — an argument named `type`/`input` inside
  -- parens, or a field inside a brace body, must not split a definition.
  local slices = {}
  local pos = 1
  local paren_depth, brace_depth = 0, 0
  while pos <= #text do
    local s, e, _, word = text:find("()%f[%a](%a+)", pos)
    if not s then break end
    local seg = text:sub(pos, s - 1)
    paren_depth = math.max(0, paren_depth
      + select(2, seg:gsub("%(", "")) - select(2, seg:gsub("%)", "")))
    brace_depth = math.max(0, brace_depth
      + select(2, seg:gsub("%{", "")) - select(2, seg:gsub("%}", "")))
    local after = text:sub(s + #word, s + #word)
    local before = s > 1 and text:sub(s - 1, s - 1) or ""
    if paren_depth == 0 and brace_depth == 0
      and DEF_KEYWORDS[word] and not after:match("[%w_]") and not before:match("[%w_]") then
      local start = s
      local pre = text:sub(math.max(1, s - 12), s - 1)
      local es = pre:find("%f[%w]extend%s*$")
      if es then
        start = s - #pre + es - 1
      end
      slices[#slices + 1] = start
    end
    pos = e + 1
  end

  for i, start in ipairs(slices) do
    local finish = (slices[i + 1] or (#text + 1)) - 1
    local slice = text:sub(start, finish)
    local body = slice:gsub("^%s*extend%s+", "")
    local kw = body:match("^%s*(%a+)")
    local name = body:match("^%s*%a+%s+([%w_]+)")

    if kw == "schema" then
      for op, tname in slice:gmatch("([%a]+)%s*:%s*([%a][%w_]*)") do
        if schema.roots[op] ~= nil then schema.roots[op] = tname end
      end
    elseif kw == "scalar" and name then
      schema.scalars[name] = true
    elseif kw == "union" and name then
      local members = {}
      local after_eq = body:match("^%s*union%s+[%w_]+%s*=%s*([^\n]*)")
      for m in (after_eq or ""):gmatch("[%w_]+") do
        members[#members + 1] = m
      end
      schema.unions[name] = { members = members }
    elseif kw == "enum" and name then
      local values = {}
      for v in (brace_body(body) or ""):gmatch("[%w_]+") do
        values[#values + 1] = v
      end
      schema.enums[name] = { values = values }
    elseif (kw == "type" or kw == "input" or kw == "interface") and name then
      -- skip `implements A & B` before the field body; brace_body strips the
      -- delimiters so single-line bodies parse like multi-line ones
      local body_start = body:find("{", 1, true)
      local inner = body_start and brace_body(body:sub(body_start)) or nil
      local fields = inner and parse_type_body(inner) or {}
      local existing = schema.types[name]
      if existing then
        -- `extend type Name` merges into the base definition
        for fname, f in pairs(fields) do existing.fields[fname] = f end
      else
        schema.types[name] = { kind = kw == "type" and "object" or kw, fields = fields }
      end
    end
    -- `directive` definitions (and anything unrecognized) are skipped
  end

  return schema
end

--- Scan the query text up to the cursor and report where completion should
--- happen. Mirrors grpc_proto.body_context, but for GraphQL selection sets:
---   { op = "query"|..., steps = { {field=..}|{type=..}|{field=..,arg=..,via="arg"} },
---     position = "field"|"argname"|"argvalue"|"vartype"|"fragtype",
---     field = ..., arg = ..., var = ..., partial = ... }
--- Strings, {{var}} templates, directives and comments are skipped
--- atomically so their braces/parens cannot disturb the walk.
function M.body_context(text)
  -- pre-collect fragment definitions for spread resolution
  local fragments = {}
  for fname, ftype in text:gmatch("%f[%w]fragment%s+([%w_]+)%s+on%s+([%w_]+)") do
    fragments[fname] = ftype
  end

  -- tokenize
  local toks = {}
  local i, n = 1, #text
  while i <= n do
    local c = text:sub(i, i)
    if c == " " or c == "\t" or c == "\n" or c == "\r" then
      i = i + 1
    elseif c == "#" then
      local nl = text:find("\n", i, true)
      i = nl and (nl + 1) or (n + 1)
    elseif c == "{" then
      if text:sub(i + 1, i + 1) == "{" then
        local close = text:find("}}", i + 2, true)
        i = close and (close + 2) or (n + 1)
        toks[#toks + 1] = { t = "string" }
      else
        toks[#toks + 1] = { t = "{" }
        i = i + 1
      end
    elseif c == "}" or c == "(" or c == ")" or c == ":" or c == "," then
      toks[#toks + 1] = { t = c }
      i = i + 1
    elseif c == "$" then
      local name = text:match("^%$([%w_]+)", i)
      toks[#toks + 1] = { t = "$", name = name or "" }
      i = i + 1 + (name and #name or 0)
    elseif c == "@" then
      local name = text:match("^@([%w_]+)", i)
      toks[#toks + 1] = { t = "@" }
      i = i + 1 + (name and #name or 0)
    elseif c == "." then
      if text:sub(i, i + 2) == "..." then
        toks[#toks + 1] = { t = "..." }
        i = i + 3
      else
        i = i + 1
      end
    elseif c == '"' then
      if text:sub(i, i + 2) == '"""' then
        local e = text:find('"""', i + 3, true)
        i = e and (e + 3) or (n + 1)
      else
        local j = i + 1
        while j <= n do
          local ch = text:sub(j, j)
          if ch == "\\" then
            j = j + 2
          elseif ch == '"' then
            break
          else
            j = j + 1
          end
        end
        i = j + 1
      end
      toks[#toks + 1] = { t = "string" }
    else
      local j = i
      while j <= n do
        local ch = text:sub(j, j)
        if ch:match("^[%s{},():%[%]!\"$@#]") then break end
        j = j + 1
      end
      if j == i then
        i = i + 1 -- stray punctuation (e.g. `!`): skip
      else
        toks[#toks + 1] = { t = "word", word = text:sub(i, j - 1) }
        i = j
      end
    end
  end

  -- walk the token stream, tracking the structural state at the cursor
  local st = {
    op = nil,
    steps = {}, -- { {field=..} | {type=..} | {field=.., arg=.., via="arg"} }
    mode = "root", -- root | selection | args
    pending_field = nil,
    pending_argname = nil,
    paren_field = nil,
    paren_arg = nil,
    after_colon = false,
    in_vardefs = false,
    var_name = nil,
    expect_fragtype = false,
    expect_on = false,
    pending_type = nil,
    saw_spread = false,
    saw_fragment_kw = false,
    op_just_set = false,
    last_word_role = nil,
    last_word = nil,
  }

  local function clear_word()
    st.last_word_role, st.last_word = nil, nil
  end

  local ti = 1
  while ti <= #toks do
    local tok = toks[ti]
    local t = tok.t

    if t == "@" then
      clear_word()
      local nxt = toks[ti + 1]
      if nxt and nxt.t == "(" then
        local depth = 1
        ti = ti + 2
        while ti <= #toks and depth > 0 do
          if toks[ti].t == "(" then
            depth = depth + 1
          elseif toks[ti].t == ")" then
            depth = depth - 1
          end
          ti = ti + 1
        end
      end
    elseif t == "(" then
      clear_word()
      if st.mode == "root" and st.op and not st.in_vardefs then
        st.in_vardefs = true
      elseif st.mode == "selection" then
        st.paren_field = st.pending_field
        st.pending_field = nil
        st.mode = "args"
      end
    elseif t == ")" then
      clear_word()
      if st.mode == "args" then
        st.mode = "selection"
        st.pending_field = st.paren_field
        st.paren_field, st.paren_arg, st.pending_argname = nil, nil, nil
      elseif st.in_vardefs then
        st.in_vardefs = false
        st.var_name = nil
      end
      st.after_colon = false
    elseif t == "{" then
      clear_word()
      if st.mode == "args" and st.after_colon then
        -- input object literal in an argument value position
        st.steps[#st.steps + 1] = { field = st.paren_field, arg = st.paren_arg, via = "arg" }
        st.mode = "selection"
      elseif st.mode == "selection" or st.mode == "root" then
        if st.pending_field then
          st.steps[#st.steps + 1] = { field = st.pending_field }
        elseif st.pending_type then
          st.steps[#st.steps + 1] = { type = st.pending_type }
        end
        st.mode = "selection"
      end
      st.pending_field, st.pending_type = nil, nil
      st.after_colon = false
    elseif t == "}" then
      clear_word()
      st.steps[#st.steps] = nil
      st.pending_field = nil
      st.after_colon = false
    elseif t == ":" then
      clear_word()
      if st.mode == "args" then
        st.paren_arg = st.pending_argname
        st.pending_argname = nil
      end
      st.after_colon = true
    elseif t == "," then
      -- commas separate arguments (and are noise between fields)
      clear_word()
      if st.mode == "args" or st.in_vardefs then
        st.after_colon = false
        st.paren_arg, st.pending_argname = nil, nil
      end
    elseif t == "$" then
      clear_word()
      if st.in_vardefs then st.var_name = tok.name end
    elseif t == "..." then
      clear_word()
      st.saw_spread = true
    elseif t == "word" then
      local w = tok.word
      if st.saw_spread and w == "on" then
        st.saw_spread = false
        st.expect_fragtype = true
        clear_word()
      elseif st.saw_spread then
        st.saw_spread = false
        st.pending_type = fragments[w]
        clear_word()
      elseif st.expect_fragtype then
        st.expect_fragtype = false
        st.pending_type = w
        st.last_word_role, st.last_word = "fragtype", w
      elseif st.mode == "args" then
        if st.after_colon then
          st.last_word_role, st.last_word = "argvalue", w
        else
          st.pending_argname = w
          st.last_word_role, st.last_word = "argname", w
        end
      elseif st.mode == "selection" then
        local frame = st.steps[#st.steps]
        if st.after_colon and frame and frame.via == "arg" then
          -- input object field VALUE: not completable
          st.after_colon = false
          st.pending_field = nil
          clear_word()
        else
          st.pending_field = w
          st.last_word_role, st.last_word = "field", w
        end
      else -- root mode
        if w == "query" or w == "mutation" or w == "subscription" then
          st.op = w
          st.op_just_set = true
        elseif st.saw_fragment_kw then
          st.saw_fragment_kw = false
          st.expect_on = true
        elseif st.expect_on and w == "on" then
          st.expect_on = false
          st.expect_fragtype = true
        elseif st.in_vardefs and st.after_colon then
          st.after_colon = false
          st.last_word_role, st.last_word = "vartype", w
        elseif st.op_just_set then
          st.op_just_set = false -- operation name, skip
        elseif w == "fragment" then
          st.saw_fragment_kw = true
        else
          clear_word()
        end
      end
    end
    ti = ti + 1
  end

  local position
  if st.mode == "args" and st.after_colon then
    position = "argvalue"
  elseif st.in_vardefs and st.after_colon then
    position = "vartype"
  elseif st.expect_fragtype then
    position = "fragtype"
  elseif st.last_word_role then
    position = st.last_word_role
  elseif st.mode == "args" then
    position = "argname"
  else
    position = "field"
  end

  local partial = st.last_word_role and st.last_word or ""

  return {
    op = st.op,
    steps = st.steps,
    position = position,
    field = st.mode == "args" and st.paren_field or nil,
    arg = st.mode == "args" and st.paren_arg or nil,
    var = st.var_name,
    partial = partial,
  }
end

--- Walk `steps` from the operation's root type down; returns the type name
--- whose members complete at the cursor, or nil when the path resolves
--- nowhere (unknown fields, unions/scalars mid-path, unknown operation).
local function resolve_steps(schema, op, steps)
  if not op then return nil end
  local cur = schema.roots[op]
  if not cur then return nil end
  for _, s in ipairs(steps or {}) do
    if s.type then
      cur = s.type
    else
      local tdef = schema.types[cur]
      local f = tdef and tdef.fields and tdef.fields[s.field]
      if not f then return nil end
      local t = f.type
      if s.via == "arg" and f.args then
        t = f.args[s.arg] or f.type
      end
      cur = M.base_type(t)
    end
  end
  return cur
end

local function filter_by_prefix(items, partial)
  if partial == "" then return items end
  local out = {}
  for _, it in ipairs(items) do
    if it.label:sub(1, #partial) == partial then
      out[#out + 1] = it
    end
  end
  return out
end

local function sort_items(items)
  table.sort(items, function(a, b) return a.sortText < b.sortText end)
  return items
end

--- Completion items for the position reported by body_context.
--- Pure: takes the parsed schema index and the walker result.
function M.items_for_context(schema, bc)
  if not schema or not bc then return {} end
  local partial = bc.partial or ""

  if bc.position == "vartype" or bc.position == "fragtype" then
    local items = {}
    for name, tdef in pairs(schema.types) do
      items[#items + 1] = {
        label = name, kind = 7, -- LSP: Class
        insertText = name, filterText = name, sortText = "0" .. name,
        detail = tdef.kind or "type",
      }
    end
    for name in pairs(schema.enums) do
      items[#items + 1] = {
        label = name, kind = 7,
        insertText = name, filterText = name, sortText = "0" .. name,
        detail = "enum",
      }
    end
    for name in pairs(schema.unions) do
      items[#items + 1] = {
        label = name, kind = 7,
        insertText = name, filterText = name, sortText = "0" .. name,
        detail = "union",
      }
    end
    for name in pairs(schema.scalars) do
      items[#items + 1] = {
        label = name, kind = 7,
        insertText = name, filterText = name, sortText = "0" .. name,
        detail = BUILTIN_SCALARS[name] and "built-in scalar" or "scalar",
      }
    end
    return sort_items(filter_by_prefix(items, partial))
  end

  local cur = resolve_steps(schema, bc.op, bc.steps)

  if bc.position == "field" then
    local tdef = cur and schema.types[cur]
    if not tdef or not tdef.fields then return {} end
    local items = {}
    for fname, f in pairs(tdef.fields) do
      items[#items + 1] = {
        label = fname, kind = 10, -- LSP: Property
        insertText = fname, filterText = fname, sortText = "0" .. fname,
        detail = f.type or "",
      }
    end
    return sort_items(filter_by_prefix(items, partial))
  end

  if bc.position == "argname" then
    local tdef = cur and schema.types[cur]
    local f = tdef and tdef.fields and tdef.fields[bc.field]
    if not f or not f.args then return {} end
    local items = {}
    for aname, atype in pairs(f.args) do
      items[#items + 1] = {
        label = aname, kind = 10,
        insertText = aname, filterText = aname, sortText = "0" .. aname,
        detail = atype or "",
      }
    end
    return sort_items(filter_by_prefix(items, partial))
  end

  if bc.position == "argvalue" then
    local tdef = cur and schema.types[cur]
    local f = tdef and tdef.fields and tdef.fields[bc.field]
    local atype = f and f.args and f.args[bc.arg]
    local en = schema.enums[M.base_type(atype)]
    if not en then return {} end
    local items = {}
    for _, v in ipairs(en.values or {}) do
      items[#items + 1] = {
        label = v, kind = 12, -- LSP: Value
        insertText = v, filterText = v, sortText = "0" .. v,
        detail = "enum value",
      }
    end
    return sort_items(filter_by_prefix(items, partial))
  end

  return {}
end

--- `# @graphql-schema <path>` operator of the request block containing
--- cursor_line (with {{var}} placeholders resolved). nil when absent.
function M.get_schema_path(buf, cursor_line)
  local start_line, end_line = cache.find_request_block_bounds(buf, cursor_line)
  if not start_line then return nil end
  local lines = vim.api.nvim_buf_get_lines(buf, start_line - 1, end_line, false)
  local operators = block_operators.extract(lines)
  local path = (operators["graphql-schema"] or {})[1]
  if not path or path == "" then return nil end
  if path:find("{", 1, true) then
    local resolver = vars.build_resolver_from_state({
      buf = buf,
      block_start = start_line,
      block_end = end_line,
    })
    path = resolver:substitute(path)
  end
  return path
end

local function mtime_key(path)
  local st = M.fs_stat(path)
  local mt = st and (st.stat and st.stat.mtime or st.mtime) or nil
  return path .. "@" .. (mt and (mt.sec .. "." .. mt.nsec) or "missing")
end

--- Read + parse the SDL at `path`, cached per buffer and invalidated by the
--- file's mtime. Returns nil when the file is unreadable.
function M.load_schema(buf, path)
  local key = mtime_key(path)
  local entry = M._cache[buf]
  if entry and entry.keys[path] == key then
    return entry.schemas[path]
  end
  local text = M.read_file(path)
  if not text then return nil end
  local schema = M.parse_sdl(text)
  entry = entry or { keys = {}, schemas = {} }
  entry.keys[path] = key
  entry.schemas[path] = schema
  M._cache[buf] = entry
  return schema
end

--- First query/mutation/subscription/fragment line of the block containing
--- cursor_line (the query body start).
function M.find_body_start(buf, cursor_line)
  local start_line, end_line = cache.find_request_block_bounds(buf, cursor_line)
  if not start_line then return nil end
  local stop = math.min(end_line, cursor_line)
  for line = start_line, stop do
    local t = vim.api.nvim_buf_get_lines(buf, line - 1, line, false)[1] or ""
    if t:match("^%s*(query)%s") or t:match("^%s*(mutation)%s")
      or t:match("^%s*(subscription)%s") or t:match("^%s*(fragment)%s") then
      return line
    end
  end
  return nil
end

--- Schema-aware items for the GRAPHQL body at the cursor. Returns nil when
--- no schema is pinned (caller falls back to keyword items).
function M.get_body_items(buf, cursor_line, cursor_col)
  local path = M.get_schema_path(buf, cursor_line)
  if not path then return nil end
  local schema = M.load_schema(buf, path)
  if not schema then return {} end

  local start_line = M.find_body_start(buf, cursor_line)
  if not start_line or cursor_line < start_line then return {} end

  local lines = vim.api.nvim_buf_get_lines(buf, start_line - 1, cursor_line, false)
  if #lines == 0 then return {} end
  lines[#lines] = lines[#lines]:sub(1, cursor_col)
  local bc = M.body_context(table.concat(lines, "\n"))
  return M.items_for_context(schema, bc)
end

--- Completion items for the `graphql_schema_path` context: directories (with
--- a trailing slash) and *.graphql/*.gql files under the directory part of
--- `partial` — same segment-only insertText contract as grpc proto paths.
function M.get_schema_path_items(partial)
  partial = partial or ""
  local dir = partial:match("^(.*/)") or ""
  local name_prefix = partial:match("([^/]*)$") or ""
  local scan_dir = dir == "" and "." or dir

  local items = {}
  local fd = uv.fs_scandir(scan_dir)
  if not fd then return items end

  while true do
    local name, kind = uv.fs_scandir_next(fd)
    if not name then break end
    if name:sub(1, #name_prefix) == name_prefix then
      if kind == "directory" then
        items[#items + 1] = {
          label = name .. "/",
          kind = 19, -- LSP: Folder
          insertText = name .. "/",
          filterText = name .. "/",
          sortText = "0" .. name,
          detail = "directory",
        }
      elseif name:match("%.graphql$") or name:match("%.gql$") then
        items[#items + 1] = {
          label = name,
          kind = 17, -- LSP: File
          insertText = name,
          filterText = name,
          sortText = "1" .. name,
          detail = dir .. name,
        }
      end
    end
  end
  return sort_items(items)
end

return M
