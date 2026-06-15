--- SQL Dataset Export — CSV, TSV, JSON, Markdown, SQL INSERT.
--- Two-step interactive: format → destination (file or clipboard).
--- File exports copy the absolute path to system clipboard.
--- Path memory persisted in stdpath("cache")/poste_export_config.

local D = require("poste.sql.dataset")
local state = require("poste.state")

local M = {}

local FORMATS = {
  { value = "csv",  label = "CSV",           ext = ".csv",  desc = "Comma-separated values" },
  { value = "tsv",  label = "TSV",           ext = ".tsv",  desc = "Tab-separated values" },
  { value = "json", label = "JSON",          ext = ".json", desc = "Array of objects (pretty-printed)" },
  { value = "md",   label = "Markdown",      ext = ".md",   desc = "Pipe table" },
  { value = "sql",  label = "SQL INSERT",    ext = ".sql",  desc = "INSERT statements" },
}

-------------------------------------------------------------------------------
-- Path persistence
-------------------------------------------------------------------------------

local function get_cache_file()
  return vim.fn.stdpath("cache") .. "/poste_export_config"
end

local function load_export_config()
  local f = io.open(get_cache_file(), "r")
  if f then
    local content = f:read("*a")
    f:close()
    local ok, cfg = pcall(vim.json.decode, content)
    if ok and type(cfg) == "table" then
      return cfg
    end
  end
  return { last_dir = nil }
end

local function save_export_config(cfg)
  local f = io.open(get_cache_file(), "w")
  if f then
    f:write(vim.json.encode(cfg))
    f:close()
  end
end

-------------------------------------------------------------------------------
-- Default path resolution
-------------------------------------------------------------------------------

local function get_default_dir()
  if state.config.export_path then
    return state.config.export_path
  end
  local cfg = load_export_config()
  if cfg.last_dir then
    return cfg.last_dir
  end
  if vim.fn.has("mac") == 1 then
    return vim.fn.expand("~/Downloads")
  elseif vim.fn.has("unix") == 1 then
    return vim.fn.expand("~")
  else
    return vim.fn.expand("~/Desktop")
  end
end

local function generate_filename(body, ext)
  local base = "export"
  local data_result = body.results and body.results[1]
  if data_result and data_result.table_name then
    base = data_result.table_name
  end
  local ts = os.date("%Y%m%d_%H%M%S")
  return base .. "_" .. ts .. ext
end

-------------------------------------------------------------------------------
-- Dataset access
-------------------------------------------------------------------------------

local function get_current_data()
  local tab = D.T()
  if not tab or not tab.data then
    vim.notify("No dataset to export", vim.log.levels.WARN)
    return nil
  end
  local body = tab.data
  if body.type ~= "resultset" then
    vim.notify("Only resultset data can be exported", vim.log.levels.WARN)
    return nil
  end
  local results = body.results
  if not results or #results == 0 then
    vim.notify("No result rows to export", vim.log.levels.WARN)
    return nil
  end
  return results[1], body
end

-------------------------------------------------------------------------------
-- Formatters
-------------------------------------------------------------------------------

local function csv_escape(v)
  local s = tostring(v)
  if s:find('["\n,]') then
    return '"' .. s:gsub('"', '""') .. '"'
  end
  return s
end

local function format_csv(data_result)
  local cols = data_result.columns or {}
  local rows = data_result.rows or {}
  local lines = {}
  local header = {}
  for _, col in ipairs(cols) do
    table.insert(header, csv_escape(col.name))
  end
  table.insert(lines, table.concat(header, ","))
  for _, row in ipairs(rows) do
    local vals = {}
    for _, v in ipairs(row) do
      table.insert(vals, csv_escape(v))
    end
    table.insert(lines, table.concat(vals, ","))
  end
  return table.concat(lines, "\n")
end

local function format_tsv(data_result)
  local cols = data_result.columns or {}
  local rows = data_result.rows or {}
  local lines = {}
  local header = {}
  for _, col in ipairs(cols) do
    table.insert(header, (tostring(col.name):gsub("[\t\n]", " ")))
  end
  table.insert(lines, table.concat(header, "\t"))
  for _, row in ipairs(rows) do
    local vals = {}
    for _, v in ipairs(row) do
      table.insert(vals, (tostring(v):gsub("[\t\n]", " ")))
    end
    table.insert(lines, table.concat(vals, "\t"))
  end
  return table.concat(lines, "\n")
end

local function format_json(data_result)
  local cols = data_result.columns or {}
  local rows = data_result.rows or {}
  local objects = {}
  for _, row in ipairs(rows) do
    local obj = {}
    for i, col in ipairs(cols) do
      obj[col.name] = row[i]
    end
    table.insert(objects, obj)
  end
  return vim.json.encode(objects)
end

local function format_markdown(data_result)
  local cols = data_result.columns or {}
  local rows = data_result.rows or {}
  local lines = {}
  local header_parts = {}
  for _, col in ipairs(cols) do
    table.insert(header_parts, tostring(col.name))
  end
  table.insert(lines, "| " .. table.concat(header_parts, " | ") .. " |")
  local sep_parts = {}
  for _ in ipairs(cols) do
    table.insert(sep_parts, "---")
  end
  table.insert(lines, "| " .. table.concat(sep_parts, " | ") .. " |")
  for _, row in ipairs(rows) do
    local vals = {}
    for _, v in ipairs(row) do
      table.insert(vals, (tostring(v):gsub("|", "\\|")))
    end
    table.insert(lines, "| " .. table.concat(vals, " | ") .. " |")
  end
  return table.concat(lines, "\n")
end

local function format_sql_insert(data_result)
  local cols = data_result.columns or {}
  local rows = data_result.rows or {}
  local table_name = data_result.table_name or "export"
  local col_names = {}
  for _, col in ipairs(cols) do
    table.insert(col_names, '"' .. tostring(col.name) .. '"')
  end
  local col_names_str = table.concat(col_names, ", ")
  local lines = {}
  for _, row in ipairs(rows) do
    local vals = {}
    for i, v in ipairs(row) do
      if v == nil or v == vim.NIL then
        table.insert(vals, "NULL")
      elseif type(v) == "number" then
        table.insert(vals, tostring(v))
      elseif type(v) == "boolean" then
        table.insert(vals, v and "TRUE" or "FALSE")
      else
        local s = tostring(v):gsub("'", "''")
        table.insert(vals, "'" .. s .. "'")
      end
    end
    table.insert(lines, string.format('INSERT INTO "%s" (%s) VALUES (%s);',
      table_name, col_names_str, table.concat(vals, ", ")))
  end
  return table.concat(lines, "\n")
end

-------------------------------------------------------------------------------
-- Dispatch
-------------------------------------------------------------------------------

local FORMATTERS = {
  csv = format_csv,
  tsv = format_tsv,
  json = format_json,
  md   = format_markdown,
  sql  = format_sql_insert,
}

-------------------------------------------------------------------------------
-- Export actions
-------------------------------------------------------------------------------

local function export_to_file(data_result, format_value, path)
  local fn = FORMATTERS[format_value]
  local dir = vim.fn.fnamemodify(path, ":h")
  if dir and dir ~= "" then
    vim.fn.mkdir(dir, "p")
  end
  local ok, text = pcall(fn, data_result)
  if not ok then
    vim.notify("Export failed: " .. tostring(text), vim.log.levels.ERROR)
    return
  end
  local f = io.open(path, "w")
  if not f then
    vim.notify("Cannot write to " .. path, vim.log.levels.ERROR)
    return
  end
  f:write(text)
  f:close()
  local abs_path = vim.fn.fnamemodify(path, ":p")
  vim.fn.setreg("+", abs_path)
  vim.fn.setreg('"', abs_path)
  local row_count = data_result.row_count or #(data_result.rows or {})
  vim.notify(string.format("Exported %d rows to %s (path in clipboard)", row_count, abs_path), vim.log.levels.INFO)
end

local function export_to_clipboard(data_result, format_value)
  local fn = FORMATTERS[format_value]
  local ok, text = pcall(fn, data_result)
  if not ok then
    vim.notify("Export failed: " .. tostring(text), vim.log.levels.ERROR)
    return
  end
  vim.fn.setreg("+", text)
  vim.fn.setreg('"', text)
  local row_count = data_result.row_count or #(data_result.rows or {})
  local fmt_label = ""
  for _, f in ipairs(FORMATS) do
    if f.value == format_value then
      fmt_label = f.label
      break
    end
  end
  vim.notify(string.format("Copied %d rows as %s to clipboard", row_count, fmt_label), vim.log.levels.INFO)
end

-------------------------------------------------------------------------------
-- Interactive flow
-- Functions are stored in P{} to avoid LuaJIT closure capture limits:
-- nested callbacks can only access upvalues of their direct parent, not
-- module-level locals. P is a module-level local accessible by all.
-------------------------------------------------------------------------------

local P = {}

local function save_default_dir(dir)
  local cfg = load_export_config()
  cfg.last_dir = dir
  save_export_config(cfg)
  vim.notify("Default export directory saved: " .. dir, vim.log.levels.INFO)
end

function P.format_picker(on_format)
  vim.ui.select(FORMATS, {
    prompt = "Select export format",
    format_item = function(f) return f.label .. "  " .. f.desc end,
  }, function(choice)
    if choice then on_format(choice.value) end
  end)
end

function P.browse_path(format_value)
  local data_result, body = get_current_data()
  if not data_result then return end
  local ext = ""
  for _, f in ipairs(FORMATS) do
    if f.value == format_value then ext = f.ext; break end
  end
  local filename = generate_filename(body, ext)
  local initial_dir = get_default_dir()

  local ok, finder = pcall(require, "finder")
  if not ok then
    vim.notify(
      "beyondlex/finder required for Browse. Add { \"beyondlex/finder\" } to your plugin specs.",
      vim.log.levels.ERROR
    )
    return
  end

  finder.open({
    mode = "dir",
    initial_path = initial_dir,
    on_confirm = function(path)
      local full_path = path .. "/" .. filename
      export_to_file(data_result, format_value, full_path)
      save_default_dir(path)
    end,
    on_cancel = function()
      P.destination_picker(format_value)
    end,
  })
end

function P.destination_picker(format_value)
  local _ = P
  local data_result, body = get_current_data()
  if not data_result then return end
  local dir = get_default_dir()
  local ext = ""
  for _, f in ipairs(FORMATS) do
    if f.value == format_value then
      ext = f.ext
      break
    end
  end
  local filename = generate_filename(body, ext)
  local default_path = dir .. "/" .. filename
  local destinations = {
    { value = "quick",  label = "→ " .. dir,          desc = "Quick save to default dir" },
    { value = "browse", label = "Browse...",           desc = "Pick directory (Go to Folder)" },
    { value = "clip",   label = "Clipboard",           desc = "Copy to system clipboard" },
  }
  vim.ui.select(destinations, {
    prompt = "Export " .. format_value:upper() .. " to...",
    format_item = function(d) return d.label end,
  }, function(choice)
    if not choice then
      P.format_picker(function(fmt) P.destination_picker(fmt) end)
      return
    end
    if choice.value == "clip" then
      export_to_clipboard(data_result, format_value)
    elseif choice.value == "browse" then
      P.browse_path(format_value)
    else
      export_to_file(data_result, format_value, default_path)
    end
  end)
end

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------

--- Main entry: :PosteExport [format] [destination] [path]
--- format: csv|tsv|json|md|sql (optional, prompts if omitted)
--- destination: file|clipboard (optional, prompts if omitted)
--- path: file path (only if destination=file, prompts if omitted)
function M.run(format_value, destination, path)
  if format_value and destination == "clipboard" then
    local data_result = get_current_data()
    if data_result then
      export_to_clipboard(data_result, format_value)
    end
    return
  end

  if format_value then
    P.destination_picker(format_value)
    return
  end

  P.format_picker(function(fmt)
    P.destination_picker(fmt)
  end)
end

--- Command completion helper
function M.complete(ArgLead, CmdLine)
  local parts = {}
  for word in CmdLine:gmatch("%S+") do
    table.insert(parts, word)
  end
  local n = #parts
  if n == 0 or (n == 1 and not CmdLine:match("%s$")) then
    return vim.tbl_filter(function(f) return f:find(ArgLead) ~= nil end, { "csv", "tsv", "json", "md", "sql" })
  end
  if n == 1 or (n == 2 and not CmdLine:match("%s$")) then
    return vim.tbl_filter(function(d) return d:find(ArgLead) ~= nil end, { "clipboard" })
  end
  return vim.fn.getcompletion(ArgLead, "file")
end

return M
