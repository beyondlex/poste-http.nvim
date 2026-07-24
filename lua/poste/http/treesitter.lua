local M = {}
local cache = require("poste.http.cache")

local ns = vim.api.nvim_create_namespace("poste_http_var_refs")
local mapping_ns = vim.api.nvim_create_namespace("poste_http_prompt_mapping")

local function highlight_var_refs(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(bufnr, mapping_ns, 0, -1)
  local request_names = cache.collect_request_names(bufnr)
  local lookup = {}
  if request_names then
    for _, name in ipairs(request_names) do
      lookup[name] = true
    end
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for l, line in ipairs(lines) do
    local row = l - 1
    local s = 1
    while s <= #line do
      local a, b, dollar, inner = line:find("{{($?)(.-)}}", s)
      if not a then break end
      if inner and inner ~= "" and dollar == "$" then
        vim.api.nvim_buf_set_extmark(bufnr, ns, row, a - 1, {
          end_row = row, end_col = b,
          hl_group = "PosteMagicVar",
          priority = 150,
        })
      elseif next(lookup) then
        local first_comp = inner:match("^%s*([^%.]+)")
        if first_comp and lookup[first_comp] then
          local ref_start = a + 1
          local ref_end = ref_start + #first_comp
          vim.api.nvim_buf_set_extmark(bufnr, ns, row, a - 1, {
            end_row = row, end_col = ref_start,
            hl_group = "PosteVarRef",
            priority = 150,
          })
          vim.api.nvim_buf_set_extmark(bufnr, ns, row, ref_start, {
            end_row = row, end_col = ref_end,
            hl_group = "PosteRequestName",
            priority = 150,
          })
          if ref_end < b then
            vim.api.nvim_buf_set_extmark(bufnr, ns, row, ref_end, {
              end_row = row, end_col = b,
              hl_group = "PosteVarRef",
              priority = 150,
            })
          end
        else
          vim.api.nvim_buf_set_extmark(bufnr, ns, row, a - 1, {
            end_row = row, end_col = b,
            hl_group = "PosteVarRef",
            priority = 150,
          })
        end
      else
        vim.api.nvim_buf_set_extmark(bufnr, ns, row, a - 1, {
          end_row = row, end_col = b,
          hl_group = "PosteVarRef",
          priority = 150,
        })
      end
      s = b + 1
    end
    -- Highlight prompt mapping keys (name:/key:/desc:) inside << [ ... ] lines
    if line:find("^%s*<<") then
      local bracket_start = line:find("%[")
      local bracket_end = bracket_start and line:find("][^]]*$")
      if bracket_start and bracket_end then
        local inner = line:sub(bracket_start + 1, bracket_end - 1)
        local pos = 1
        while pos <= #inner do
          local ma, mb = inner:find("[nkd][a-z]+:", pos)
          if not ma then break end
          local word = inner:sub(ma, mb - 1)
          if word == "name" or word == "key" or word == "desc" then
            vim.api.nvim_buf_set_extmark(bufnr, mapping_ns, row, bracket_start + ma - 1, {
              end_row = row, end_col = bracket_start + mb,
              hl_group = "PostePromptMappingField",
              priority = 160,
            })
          end
          pos = mb + 1
        end
      end
    end
  end
end

function M.enable(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].filetype ~= "poste_http" then
    return
  end
  local ok, err = pcall(vim.treesitter.start, bufnr, "poste_http")
  if not ok then
    vim.notify("[Poste] tree-sitter: " .. tostring(err), vim.log.levels.WARN)
  end
  highlight_var_refs(bufnr)
  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function()
      highlight_var_refs(bufnr)
    end,
  })
end

function M.disable(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  pcall(vim.treesitter.stop, bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(bufnr, mapping_ns, 0, -1)
end

--- Inspect the treesitter parse tree for the current buffer.
--- Displays as a notification for debugging highlight issues.
function M.inspect(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "poste_http")
  if not ok or not parser then
    vim.notify("[Poste] No tree-sitter parser active", vim.log.levels.WARN)
    return
  end
  local ok, trees = pcall(parser.parse, parser)
  if not ok or not trees or #trees == 0 then
    vim.notify("[Poste] No parse tree available", vim.log.levels.WARN)
    return
  end
  local root = trees[1]:root()
  local lines = {}
  local function dump(node, depth)
    depth = depth or 0
    local indent = string.rep("  ", depth)
    local name = node:type()
    local start_row, start_col, end_row, end_col = node:range()
    table.insert(lines, string.format("%s%s [%d:%d - %d:%d]", indent, name, start_row, start_col, end_row, end_col))
    for child in node:iter_children() do
      dump(child, depth + 1)
    end
  end
  dump(root)
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

return M