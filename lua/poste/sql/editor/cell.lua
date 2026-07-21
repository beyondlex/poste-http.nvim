--- Dataset cell editor — pure functions for value conversion, validation,
--- edit state tracking. No vim.ui calls (those are in nav.lua).

local M = {}

---------------------------------------------------------------------------
-- Type classification helpers
---------------------------------------------------------------------------

local TYPES = {
  integer = { integer=true, int=true, bigint=true, smallint=true,
              serial=true, bigserial=true, smallserial=true },
  numeric = { integer=true, int=true, bigint=true, smallint=true, serial=true, bigserial=true, smallserial=true,
              numeric=true, decimal=true, real=true, float=true, double=true, double_precision=true },
  boolean = { boolean=true, bool=true },
  date    = { date=true, timestamp=true, timestamptz=true, datetime=true, datetime2=true, time=true },
  json    = { json=true, jsonb=true },
  uuid    = { uuid=true },
  text    = { text=true, varchar=true, char=true, character=true, character_varying=true,
              nvarchar=true, nchar=true, longtext=true, mediumtext=true, tinytext=true },
  ineditable = { binary=true, bytea=true, blob=true, varbinary=true,
                 geometry=true, geography=true, point=true, polygon=true, linestring=true, multipolygon=true,
                 inet=true, cidr=true, macaddr=true, macaddr8=true,
                 bit=true, varbit=true, interval=true,
                 tsvector=true, tsquery=true, xml=true, hstore=true,
                 array=true, range=true, multirange=true },
}

local function is_type(ctype, category)
  return TYPES[category] and TYPES[category][ctype:lower()] == true
end

function M.is_numeric_type(ctype) return is_type(ctype, "numeric") end
function M.is_integer_type(ctype) return is_type(ctype, "integer") end
function M.is_boolean_type(ctype) return is_type(ctype, "boolean") end
function M.is_date_type(ctype) return is_type(ctype, "date") end
function M.is_uuid_type(ctype) return is_type(ctype, "uuid") end
function M.is_text_type(ctype) return is_type(ctype, "text") end

function M.is_json_column(col_meta)
  return col_meta and col_meta.ctype and is_type(col_meta.ctype, "json")
end

function M.is_boolean_column(col_meta)
  return col_meta and col_meta.ctype and is_type(col_meta.ctype, "boolean")
end

function M.is_datetime_column(col_meta)
  return col_meta and col_meta.ctype and is_type(col_meta.ctype, "date")
end

function M.is_enum_column(col_meta)
  return col_meta and col_meta.enum_values and #col_meta.enum_values > 0 or false
end

function M.is_editable_field(col_meta)
  if not col_meta then return false end
  if col_meta.user_defined then
    return false
  end
  if col_meta.primary_key and col_meta.default then
    return true
  end
  if col_meta.primary_key then
    return false
  end
  if col_meta.ctype and TYPES.ineditable[col_meta.ctype:lower()] then
    return false
  end
  return true
end

---------------------------------------------------------------------------
-- Value parsing
---------------------------------------------------------------------------

--- Parse a user input string into a typed value suitable for SQL.
--- Handles: JSON, UUID, datetime, numbers, booleans, NULL.
function M.parse_value(input, old_val)
  if input == "(NULL)" then return vim.NIL end
  if input == "null" or input == "NULL" then return vim.NIL end
  if input == "" then
    return old_val ~= nil and vim.NIL or nil
  end
  if input == "''" then return "" end

  -- Expressions (computed in SQL)
  if input:match("^__expr:") then return input end

  local ok, parsed = pcall(vim.json.decode, input)
  if ok and type(parsed) ~= "string" then
    return parsed
  end

  if input == "true" then return true end
  if input == "false" then return false end

  local num = tonumber(input)
  if num and not input:match("^0") then
    return num
  end

  return input
end

---------------------------------------------------------------------------
-- Value validation
---------------------------------------------------------------------------

--- Validate a parsed value against column metadata.
--- Returns (true) or (false, error_message).
function M.validate_value(value, col_meta)
  if not col_meta then return true end
  if value == vim.NIL then return true end

  local ctype = col_meta.ctype and col_meta.ctype:lower() or ""

  if value == true or value == false then
    if not is_type(ctype, "boolean") then
      return false, "Cannot assign boolean to " .. (col_meta.ctype or "unknown") .. " column"
    end
    return true
  end

  if type(value) == "table" then
    if not is_type(ctype, "json") then
      return false, "Cannot assign object to " .. (col_meta.ctype or "unknown") .. " column"
    end
    return true
  end

  if type(value) == "number" then
    if is_type(ctype, "boolean") then
      if value == 1 or value == 0 then return true end
      return false, "Only 0 and 1 allowed for boolean column"
    end
    if not is_type(ctype, "numeric") then
      return false, "Cannot assign number to " .. (col_meta.ctype or "unknown") .. " column"
    end
    local val_str = tostring(value)
    if ctype == "integer" and val_str:match("%.") then
      return false, "Cannot assign decimal to integer column"
    end
    return true
  end

  if type(value) == "string" then
    if value:match("^__expr:") then return true end
    if is_type(ctype, "uuid") then
      local parts = { value:match("^(%x%x%x%x%x%x%x%x)-(%x%x%x%x)-(%x%x%x%x)-(%x%x%x%x)-(%x%x%x%x%x%x%x%x%x%x%x%x)$") }
      if not parts or #parts ~= 5 then
        return false, "Invalid UUID format"
      end
      return true
    end
    if is_type(ctype, "integer") or is_type(ctype, "numeric") then
      return false, "Cannot assign string to " .. (col_meta.ctype or "unknown") .. " column"
    end
    if is_type(ctype, "boolean") then
      return false, "Cannot assign string to boolean column"
    end
    if is_type(ctype, "date") then
      if not value:match("^%d") then
        return false, "Invalid date format"
      end
    end
    return true
  end

  return true
end

---------------------------------------------------------------------------
-- Edit state management
---------------------------------------------------------------------------

--- Create a fresh edit state tracker.
--- @return table edit_state
function M.create_edit_state()
  return {
    modified_cells = {},
    deleted_rows = {},
    added_rows = {},
    dirty = false,
    cell_errors = {},
  }
end

--- Track a cell modification.
--- @param es table Edit state
--- @param row_key string "row:col"
--- @param col number Column index
--- @param old_val any Previous value
--- @param new_val any New value
function M.track_cell_edit(es, row_key, col, old_val, new_val)
  if new_val == old_val then
    es.modified_cells[row_key] = nil
    if not next(es.modified_cells) then
      es.dirty = false
    end
    return
  end
  local row_idx = tonumber(row_key:match("^(%d+):"))
  if row_idx and es.deleted_rows[row_idx] then
    return
  end
  es.modified_cells[row_key] = { col = col, old_val = old_val, new_val = new_val }
  es.dirty = true
end

--- Track a row deletion.
--- @param es table Edit state
--- @param row_idx number Row index
function M.track_row_delete(es, row_idx)
  es.deleted_rows[row_idx] = true
  es.dirty = true
  for k, _ in pairs(es.modified_cells) do
    local r = tonumber(k:match("^(%d+):"))
    if r == row_idx then
      es.modified_cells[k] = nil
    end
  end
end

--- Track a row addition.
--- @param es table Edit state
--- @param row_data table Row data
--- @param row_idx number Row index
function M.track_row_add(es, row_data, row_idx)
  table.insert(es.added_rows, { data = row_data, row_idx = row_idx })
  es.dirty = true
end

--- Check if there are any pending changes.
function M.has_pending_changes(es)
  if not es or not es.dirty then return false end
  return next(es.modified_cells) ~= nil
      or next(es.deleted_rows) ~= nil
      or #es.added_rows > 0
end

--- Get a summary of pending changes for display.
function M.get_edit_summary(es)
  if not es then return { updates = 0, inserts = 0, deletes = 0 } end
  local ups = 0
  for _ in pairs(es.modified_cells) do ups = ups + 1 end
  local dels = 0
  for _ in pairs(es.deleted_rows) do dels = dels + 1 end
  return { updates = ups, inserts = #es.added_rows, deletes = dels }
end

--- Count pending changes (for display).
function M.count_pending_changes(es)
  if not es or not es.dirty then return { modified = 0, deleted = 0, added = 0 } end
  local mod = 0
  for _ in pairs(es.modified_cells) do mod = mod + 1 end
  local del = 0
  for _ in pairs(es.deleted_rows) do del = del + 1 end
  return { modified = mod, deleted = del, added = #es.added_rows }
end

--- Return a short text representation of pending changes.
function M.pending_changes_text(es)
  if not es or not es.dirty or not M.has_pending_changes(es) then return nil end
  local counts = M.count_pending_changes(es)
  local parts = {}
  if counts.modified > 0 then table.insert(parts, "~" .. counts.modified) end
  if counts.added > 0 then table.insert(parts, "+" .. counts.added) end
  if counts.deleted > 0 then table.insert(parts, "-" .. counts.deleted) end
  return table.concat(parts, " ")
end

--- Reset edit state, clearing all pending changes.
function M.reset_edit_state(es)
  if not es then return end
  es.modified_cells = {}
  es.deleted_rows = {}
  es.added_rows = {}
  es.dirty = false
  es.cell_errors = {}
end

--- Clear a cell error.
function M.clear_cell_error(es, row_key)
  if es and es.cell_errors then
    es.cell_errors[row_key] = nil
  end
end

--- Set a cell error.
function M.set_cell_error(es, row_key, msg)
  if not es then return end
  if not es.cell_errors then es.cell_errors = {} end
  es.cell_errors[row_key] = msg
end

---------------------------------------------------------------------------
-- JSON formatting helpers
---------------------------------------------------------------------------

--- Format a Lua table as pretty-printed JSON for editing.
--- @param val table JSON value
--- @return string
function M.format_json_input(val)
  if type(val) == "string" then return val end
  local ok, str = pcall(vim.json.encode, val)
  if ok then
    local no_esc = str:gsub('\\"', '"')
    return no_esc
  end
  return tostring(val)
end

--- Parse a JSON string into a Lua value.
--- @param input string
--- @return table|nil
function M.parse_json_input(input)
  local ok, decoded = pcall(vim.json.decode, input)
  if ok then return decoded end
  return nil
end

return M
