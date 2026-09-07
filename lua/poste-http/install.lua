local M = {}

local GRAMMARS = {
  {
    name = "poste_http",
    dir = "tree-sitter-poste-http",
    src = "src/parser.c",
    so = "poste_http.so",
  },
  {
    name = "poste_json",
    dir = "tree-sitter-poste-json",
    src = "src/parser.c",
    so = "poste_json.so",
  },
  {
    name = "poste_graphql",
    dir = "tree-sitter-poste-graphql",
    src = "src/parser.c",
    so = "poste_graphql.so",
  },
}

local function plugin_root()
  local src = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(src, ":h:h:h")
end

local function parser_dir()
  return vim.fn.stdpath("data") .. "/site/parser"
end

local function cc()
  if vim.fn.executable("cc") == 1 then return "cc" end
  if vim.fn.executable("gcc") == 1 then return "gcc" end
  return nil
end

local function needs_compile(grammar_dir, so_path)
  local parser_c = grammar_dir .. "/src/parser.c"
  if vim.fn.filereadable(parser_c) ~= 1 then
    return false, "source not found: " .. parser_c
  end
  if vim.fn.filereadable(so_path) ~= 1 then
    return true
  end
  local src_mtime = vim.fn.getftime(parser_c)
  local so_mtime = vim.fn.getftime(so_path)
  return src_mtime > so_mtime
end

local function compile_one(grammar)
  local root = plugin_root()
  local grammar_dir = root .. "/" .. grammar.dir
  local parser_dir_path = parser_dir()

  local so_path = parser_dir_path .. "/" .. grammar.so

  local need, reason = needs_compile(grammar_dir, so_path)
  if not need then
    if reason then
      vim.notify("[Poste] " .. reason, vim.log.levels.WARN)
    end
    return false, reason
  end

  local c = cc()
  if not c then
    vim.notify(
      "[Poste] C compiler not found. Install cc/gcc or run :PosteHttpBuildParsers manually.",
      vim.log.levels.WARN
    )
    return false
  end

  if vim.fn.isdirectory(parser_dir_path) ~= 1 then
    vim.fn.mkdir(parser_dir_path, "p")
  end

  local src_path = grammar_dir .. "/" .. grammar.src
  local obj_path = parser_dir_path .. "/" .. grammar.name .. ".o"
  local include_path = grammar_dir .. "/src"
  local cmd_obj = string.format(
    "%s -c -I%s -fPIC -O2 -o %s %s",
    c, include_path, obj_path, src_path
  )
  local cmd_so = string.format(
    "%s -shared -o %s %s",
    c, so_path, obj_path
  )

  local out = vim.fn.system(cmd_obj)
  local ok1 = vim.v.shell_error == 0
  if not ok1 then
    vim.notify("[Poste] Failed to compile " .. grammar.name .. " parser: " .. (out or ""), vim.log.levels.ERROR)
    pcall(vim.fn.delete, obj_path)
    return false
  end

  out = vim.fn.system(cmd_so)
  local ok2 = vim.v.shell_error == 0
  pcall(vim.fn.delete, obj_path)
  if not ok2 then
    vim.notify("[Poste] Failed to link " .. grammar.name .. " parser: " .. (out or ""), vim.log.levels.ERROR)
    pcall(vim.fn.delete, so_path)
    return false
  end

  vim.notify("[Poste] Compiled " .. grammar.name .. " parser", vim.log.levels.INFO)
  return true
end

function M.ensure_parsers()
  if vim.fn.executable("cc") ~= 1 and vim.fn.executable("gcc") ~= 1 then
    return
  end
  for _, grammar in ipairs(GRAMMARS) do
    compile_one(grammar)
  end
end

function M.force_build()
  local ok = false
  for _, grammar in ipairs(GRAMMARS) do
    if compile_one(grammar) then
      ok = true
    end
  end
  if not ok then
    vim.notify("[Poste] No parsers were compiled. Check :PosteInfo for details.", vim.log.levels.ERROR)
  end
end

return M