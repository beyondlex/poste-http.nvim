vim.opt.runtimepath:prepend(".")

local out = {}
local function log(s) table.insert(out, s) end
local pass, fail = 0, 0
local function check(label, got, expected)
  if got == expected then log("PASS: " .. label); pass = pass + 1
  else log(string.format("FAIL: %s  got=%s  expected=%s", label, tostring(got), tostring(expected))); fail = fail + 1 end
end

local sql_comp = require("poste.sql.completion")
local state    = require("poste.state")

-- ── 1. blocked list patch logic ───────────────────────────────────────────────
log("\n=== blink blocked list patch ===")
local orig = { " ", "\n", "\t" }
local patched = function(ft)
  if ft == "poste_sql" or ft == "poste_sqlite" then
    return vim.tbl_filter(function(c) return c ~= " " end, orig)
  end
  return orig
end

check("lua: space blocked",           vim.tbl_contains(patched("lua"),          " "), true)
check("poste_sql: space NOT blocked", vim.tbl_contains(patched("poste_sql"),    " "), false)
check("poste_sqlite: space NOT blocked", vim.tbl_contains(patched("poste_sqlite"), " "), false)
check("poste_sql: newline still blocked", vim.tbl_contains(patched("poste_sql"), "\n"), true)
check("poste_sql: tab still blocked",    vim.tbl_contains(patched("poste_sql"), "\t"), true)

-- ── 2. get_completions with space after WHERE ─────────────────────────────────
log("\n=== get_completions after WHERE<space> ===")
state.sql = { context = { connection = "test-conn", database = "blog" } }
sql_comp.cache_tables({ { name = "authors" } })
sql_comp.cache_columns("authors", { { name = "id" }, { name = "username" } })

local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "###", "SELECT * FROM authors WHERE " })
vim.api.nvim_buf_set_option(buf, "filetype", "poste_sql")
vim.api.nvim_set_current_buf(buf)

local line = "SELECT * FROM authors WHERE "
local items = nil
sql_comp.new():get_completions({ line = line, cursor = { 2, #line } }, function(r) items = r end)

if items == nil then
  log("FAIL: callback not called"); fail = fail + 1
else
  local labels = {}
  for _, item in ipairs(items.items) do labels[item.label] = true end
  check("returns id column",       labels["id"],       true)
  check("returns username column", labels["username"],  true)
  check("no SELECT keyword",       labels["SELECT"],   nil)
end

log(string.format("\n=== RESULT: %d passed, %d failed ===", pass, fail))
vim.fn.writefile(out, "/tmp/poste_space_trigger_diag.txt")
vim.cmd("qa!")
