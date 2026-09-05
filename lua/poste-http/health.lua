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
}

local function plugin_root()
  local src = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(src, ":h:h:h")
end

local function parser_dir()
  return vim.fn.stdpath("data") .. "/site/parser"
end

function M.check()
  vim.health.start("poste-http")

  local root = plugin_root()

  vim.health.start("curl")
  if vim.fn.executable("curl") == 1 then
    vim.health.ok("curl is installed")
  else
    vim.health.error("curl not found. Install curl to execute HTTP requests.")
  end

  vim.health.start("Protocol backends")
  if vim.fn.executable("grpcurl") == 1 then
    vim.health.ok("grpcurl is installed (GRPC requests)")
  else
    vim.health.warn("grpcurl not found. Install grpcurl to run GRPC requests (https://github.com/fullstorydev/grpcurl).")
  end
  if vim.fn.executable("websocat") == 1 then
    vim.health.ok("websocat is installed (WEBSOCKET requests)")
  else
    vim.health.warn("websocat not found. Install websocat to run WEBSOCKET requests (https://github.com/nickelc/websocat).")
  end

  vim.health.start("C compiler")
  if vim.fn.executable("cc") == 1 or vim.fn.executable("gcc") == 1 then
    vim.health.ok("C compiler found")
  else
    vim.health.warn("C compiler not found. Run :PosteHttpBuildParsers or :checkhealth poste-http after installing a C compiler.")
  end

  vim.health.start("tree-sitter-poste-http")
  for _, grammar in ipairs(GRAMMARS) do
    local grammar_dir = root .. "/" .. grammar.dir
    local parser_c = grammar_dir .. "/" .. grammar.src
    local so_path = parser_dir() .. "/" .. grammar.so

    if vim.fn.isdirectory(grammar_dir) == 1 then
      vim.health.ok(grammar.name .. " grammar directory found: " .. grammar.dir)
    else
      vim.health.error(grammar.name .. " grammar directory not found: " .. grammar.dir)
    end

    if vim.fn.filereadable(parser_c) == 1 then
      vim.health.ok(grammar.name .. " parser source found")
    else
      vim.health.error(grammar.name .. " parser source not found: " .. parser_c)
    end

    if vim.fn.filereadable(so_path) == 1 then
      -- A .so older than its source serves an outdated grammar silently
      -- (missing highlights, misparsed bodies), so surface the staleness.
      if vim.fn.getftime(parser_c) > vim.fn.getftime(so_path) then
        vim.health.warn(grammar.name .. " parser is stale (compiled before the current source). Run :PosteHttpBuildParsers, then restart Neovim so the new parser is loaded.")
      else
        vim.health.ok(grammar.name .. " parser compiled: " .. grammar.so)
      end
    else
      vim.health.warn(grammar.name .. " parser not compiled. Run :PosteHttpBuildParsers to compile.")
    end

    local ok, _ = pcall(vim.treesitter.get_parser, 0, grammar.name)
    if ok then
      vim.health.ok(grammar.name .. " parser active in Neovim")
    else
      vim.health.error(grammar.name .. " parser failed to load in Neovim")
    end
  end
end

return M