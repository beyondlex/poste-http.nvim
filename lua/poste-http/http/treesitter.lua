local M = {}
local cache = require("poste-http.http.cache")
local state = require("poste-http.state")
local notify = require("poste-http.ui.notify").notify

local ns = vim.api.nvim_create_namespace("poste_http_var_refs")
local mapping_ns = vim.api.nvim_create_namespace("poste_http_prompt_mapping")
local undo_ns = vim.api.nvim_create_namespace("poste_http_undo_fix")

local function invalidate_parser(bufnr)
  vim.schedule(function()
    local okp, parser = pcall(vim.treesitter.get_parser, bufnr, "poste_http")
    if okp and parser then
      if parser.invalidate then
        pcall(parser.invalidate, parser)
      else
        pcall(vim.treesitter.stop, bufnr)
        pcall(vim.treesitter.start, bufnr, "poste_http")
      end
    end
  end)
end

vim.on_key(function(key)
  if vim.fn.mode() == "n" and (key == "u" or key == "U" or key == vim.keycode("<C-R>")) then
    local bufnr = vim.api.nvim_get_current_buf()
    if vim.bo[bufnr] and vim.bo[bufnr].filetype == "poste_http" then
      invalidate_parser(bufnr)
    end
  end
end, undo_ns)

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
    if not vim.trim(line):match("^#") then
      -- Highlight client.run("#alias.Name", ...) request targets inside scripts
      local cr_s, cr_e = line:find('client%.run%s*%(')
      if cr_s then
        local qs, qe = line:find('["\']#([^"\']+)["\']', cr_e + 1)
        if qs and qe then
          local target_start = qs + 1 -- 1-based position of "#"
          local target_end = qe - 1   -- 1-based position of last target char
          local inner = line:sub(target_start, target_end)
          local dot = inner:find("%.")
          if dot then
            -- "#api." → PosteRunTarget, "Login" → PosteRequestName
            vim.api.nvim_buf_set_extmark(bufnr, ns, row, target_start - 1, {
              end_row = row, end_col = target_start + dot - 1,
              hl_group = "PosteRunTarget",
              priority = 150,
            })
            vim.api.nvim_buf_set_extmark(bufnr, ns, row, target_start + dot - 1, {
              end_row = row, end_col = target_end,
              hl_group = "PosteRequestName",
              priority = 150,
            })
          else
            vim.api.nvim_buf_set_extmark(bufnr, ns, row, target_start - 1, {
              end_row = row, end_col = target_end,
              hl_group = "PosteRequestName",
              priority = 150,
            })
          end
        end
      end

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

      -- Highlight Lua import var ref sub-parts: @var = alias.key[...].key[...]
      local var_start, var_end, var_name = line:find("^%s*@([%w_]+)%s*=%s*")
      if var_start and var_name then
        local value = line:sub(var_end + 1)
        local alias_end = value:find("^([a-zA-Z_][a-zA-Z0-9_]*%.+)")
        if alias_end then
          local alias_name = value:match("^([a-zA-Z_][a-zA-Z0-9_]*)")
          if alias_name then
            vim.api.nvim_buf_set_extmark(bufnr, ns, row, var_end, {
              end_row = row, end_col = var_end + #alias_name,
              hl_group = "PosteImportRefAlias",
              priority = 155,
            })
            local pos = var_end + #alias_name
            local rest = value:sub(#alias_name + 1)
            local seg_idx = 1
            while seg_idx <= #rest do
              local c = rest:sub(seg_idx, seg_idx)
              if c == "." then
                vim.api.nvim_buf_set_extmark(bufnr, ns, row, pos, {
                  end_row = row, end_col = pos + 1,
                  hl_group = "PosteImportRefDot",
                  priority = 155,
                })
                pos = pos + 1
                seg_idx = seg_idx + 1
              elseif c:match("[a-zA-Z_]") then
                local key_end = rest:find("[^a-zA-Z0-9_]", seg_idx)
                if not key_end then key_end = #rest + 1 end
                vim.api.nvim_buf_set_extmark(bufnr, ns, row, pos, {
                  end_row = row, end_col = pos + (key_end - seg_idx),
                  hl_group = "PosteImportRefKey",
                  priority = 155,
                })
                pos = pos + (key_end - seg_idx)
                seg_idx = key_end
              elseif c == "[" then
                local bracket_end = rest:find("]", seg_idx)
                if bracket_end then
                  bracket_end = bracket_end + 1
                else
                  bracket_end = #rest + 1
                end
                vim.api.nvim_buf_set_extmark(bufnr, ns, row, pos, {
                  end_row = row, end_col = pos + (bracket_end - seg_idx),
                  hl_group = "PosteImportRefIndex",
                  priority = 155,
                })
                pos = pos + (bracket_end - seg_idx)
                seg_idx = bracket_end
              else
                seg_idx = seg_idx + 1
                pos = pos + 1
              end
            end
          end
        end
      end
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
    notify("tree-sitter: " .. tostring(err), vim.log.levels.WARN)
  end
  highlight_var_refs(bufnr)
  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function()
      highlight_var_refs(bufnr)
    end,
  })

  if state.config.use_treesitter and state.config.use_treesitter.folding then
    vim.bo[bufnr].foldmethod = "expr"
    vim.bo[bufnr].foldexpr = "v:lua.require('poste-http.http.folding').foldexpr()"
  end

  if state.config.use_treesitter and state.config.use_treesitter.diagnostics then
    local diagnostics = require("poste-http.http.diagnostics")
    diagnostics.enable(bufnr)
  end
end

function M.disable(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  pcall(vim.treesitter.stop, bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(bufnr, mapping_ns, 0, -1)

  if state.config.use_treesitter and state.config.use_treesitter.diagnostics then
    local diagnostics = require("poste-http.http.diagnostics")
    diagnostics.disable(bufnr)
  end
end

--- Namespace used for variable-reference extmarks in source buffers.
M.ns = ns

--- (Re-)highlight variable references in a buffer with the var-ref namespace.
--- @param bufnr number
function M.highlight_var_refs(bufnr)
  highlight_var_refs(bufnr)
end

--- Inspect the treesitter parse tree for the current buffer.
--- Displays as a notification for debugging highlight issues.
function M.inspect(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "poste_http")
  if not ok or not parser then
    notify("No tree-sitter parser active", vim.log.levels.WARN)
    return
  end
  ok, trees = pcall(parser.parse, parser)
  if not ok or not trees or #trees == 0 then
    notify("No parse tree available", vim.log.levels.WARN)
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
  notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

return M
