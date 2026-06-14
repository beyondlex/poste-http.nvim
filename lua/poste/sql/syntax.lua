--- Shared SQL syntax highlighter.
--- Single source of truth for SQL highlighting; used by log viewer
--- and SQL buffer to keep highlight behavior consistent.

local M = {}

local patterns = {
  { "%-%-[^\n]-", "sqlComment" },
  { "'[^']-'", "sqlString" },
  { '"[^"]-"', "sqlString" },
  { '`[^`]-`', "sqlString" },
  { "%f[%d]%d+%.?%d*%f[^%d%w]", "sqlNumber" },
}

local kw_map = {
  sqlStatement = "SELECT FROM WHERE INSERT INTO VALUES UPDATE SET DELETE CREATE TABLE ALTER DROP INDEX JOIN LEFT RIGHT INNER OUTER CROSS FULL ON AND OR NOT IN AS ORDER BY GROUP HAVING LIMIT OFFSET LIKE BETWEEN EXISTS UNION ALL DISTINCT ASC DESC CASE WHEN THEN ELSE END COMMIT ROLLBACK BEGIN RETURNING EXPLAIN ANALYZE WITH RECURSIVE TRUNCATE PRIMARY KEY FOREIGN REFERENCES CASCADE CONSTRAINT DEFAULT CHECK UNIQUE REPLACE",
  sqlKeyword = "CAST COALESCE IF IS NULL",
  sqlType = "INT INTEGER BIGINT SMALLINT TINYINT BOOLEAN BOOL FLOAT DOUBLE DECIMAL NUMERIC REAL VARCHAR CHAR TEXT BLOB CLOB ENUM SET JSON DATE TIME DATETIME TIMESTAMP YEAR",
  sqlFunction = "COUNT SUM AVG MIN MAX NULLIF GREATEST LEAST NOW CURDATE CURTIME DATE_FORMAT CONCAT SUBSTRING UPPER LOWER LENGTH TRIM ROUND ABS COALESCE",
  sqlSpecial = "NULL TRUE FALSE",
}

--- Highlight SQL on a single buffer line using Vim SQL syntax groups.
--- @param buf number Buffer handle
--- @param ns number Extmark namespace
--- @param line_idx number Buffer line (1-indexed)
--- @param text string SQL text (without any buffer prefix)
--- @param col_offset number Column offset in buffer (e.g. prefix width)
function M.highlight_line(buf, ns, line_idx, text, col_offset)
  for _, p in ipairs(patterns) do
    local pos = 1
    while pos <= #text do
      local s, e = text:find(p[1], pos)
      if not s then break end
      vim.api.nvim_buf_set_extmark(buf, ns, line_idx - 1, col_offset + s - 1, {
        end_col = col_offset + e, hl_group = p[2], priority = 157,
      })
      pos = e + 1
    end
  end
  local upper = text:upper()
  for hl, kw_text in pairs(kw_map) do
    for kw in kw_text:gmatch("%S+") do
      local s, e = upper:find("%f[%w_]" .. kw .. "%f[^%w_]", 1)
      while s do
        vim.api.nvim_buf_set_extmark(buf, ns, line_idx - 1, col_offset + s - 1, {
          end_col = col_offset + e, hl_group = hl, priority = 155,
        })
        s, e = upper:find("%f[%w_]" .. kw .. "%f[^%w_]", e + 1)
      end
    end
  end
end

return M
