local M = {}

local INTEGER_TYPES = {
  integer = true, int = true, int2 = true, int4 = true, int8 = true,
  smallint = true, bigint = true, serial = true, bigserial = true,
  tinyint = true, mediumint = true,
}

function M.coerce_value(str, col_type)
  if str == nil or str == vim.NIL then return vim.NIL end
  local s = tostring(str):gsub("^%s+", ""):gsub("%s+$", "")

  if s == "" then return nil end

  if s == "NULL" or s == "(NULL)" then return vim.NIL end

  local ctype = (col_type or ""):lower()
  if s == "true" or s == "TRUE" then return true end
  if s == "false" or s == "FALSE" then return false end
  if ctype == "boolean" or ctype == "bool" then
    if s == "1" then return true end
    if s == "0" then return false end
  end

  local num = tonumber(s)
  if num and s:match("^%-?%d+%.?%d*$") then
    if INTEGER_TYPES[ctype] and num ~= math.floor(num) then  -- luacheck: ignore 542
    else
      return num
    end
  end

  return s
end

function M.build_column_map(parsed_cols, table_cols)
  local col_map = {}
  local unmatched_import = {}
  local matched_table = {}
  local unmatched_table = {}

  for ii, name in ipairs(parsed_cols) do
    local found = false
    for ti, tc in ipairs(table_cols) do
      if tc.name:lower() == name:lower() then
        table.insert(col_map, {
          import_idx = ii,
          import_name = name,
          table_col = tc,
          table_idx = ti,
        })
        matched_table[ti] = true
        found = true
        break
      end
    end
    if not found then
      table.insert(unmatched_import, name)
    end
  end

  for ti, tc in ipairs(table_cols) do
    if not matched_table[ti] then
      table.insert(unmatched_table, tc)
    end
  end

  return col_map, unmatched_import, unmatched_table
end

function M.build_row_values(import_row, col_map, num_table_cols)
  local row_values = {}
  for i = 1, num_table_cols do
    row_values[i] = nil
  end
  for _, mc in ipairs(col_map) do
    row_values[mc.table_idx] = import_row[mc.import_idx]
  end
  return row_values
end

function M.normalize_columns(table_cols)
  local cols = {}
  for _, tc in ipairs(table_cols) do
    table.insert(cols, {
      name = tc.name,
      type = tc.col_type,
      primary_key = tc.is_pk,
    })
  end
  return cols
end

function M.validate_and_type(import_rows, col_map, table_cols, unmatched_table)
  local valid = {}
  local bad = {}

  for ri, import_row in ipairs(import_rows) do
    local row_vals = M.build_row_values(import_row, col_map, #table_cols)
    local row_errors = {}

    for _, mc in ipairs(col_map) do
      local raw_val = import_row[mc.import_idx]
      local coerced = M.coerce_value(raw_val, mc.table_col.col_type)
      row_vals[mc.table_idx] = coerced

      if mc.table_col.is_pk and (coerced == nil or coerced == vim.NIL) then
        if not (mc.table_col.extra and mc.table_col.extra:find("auto", 1, true)) then
          table.insert(row_errors, string.format("  %s: primary key column '%s' cannot be null",
            ri + 1, mc.table_col.name))
        end
      end
    end

    if #row_errors > 0 then
      table.insert(bad, { row_idx = ri + 1, import_row = import_row, errors = row_errors })
    else
      table.insert(valid, row_vals)
    end
  end

  return valid, bad
end

return M
