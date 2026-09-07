local ts_query = require("poste-http.http.ts_query")

local M = {}
local ns = vim.api.nvim_create_namespace("poste_http_diagnostics")

local function walk(node, diagnostics, buf)
  local t = node:type()
  if t:find("ERROR") or t:find("MISSING") or t == "ERROR" then
    local sr, sc, er, ec = node:range()
    table.insert(diagnostics, {
      lnum = sr,
      col = sc,
      end_lnum = er,
      end_col = ec,
      severity = vim.diagnostic.severity.ERROR,
      message = "Syntax error: unexpected " .. t,
      source = "poste-http",
    })
  end
  for child in node:iter_children() do
    walk(child, diagnostics, buf)
  end
end

local function check_semantic_rules(root, diagnostics, buf)
  local _ = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  local seen_vars = {}

  local var_query = [[
    (variable_definition (var_name) @name)
  ]]
  local ok, query = pcall(vim.treesitter.query.parse, "poste_http", var_query)
  if ok then
    for _, match in query:iter_matches(root, buf, 0, -1) do
      for id, nodes in pairs(match) do
        if type(id) == "number" and nodes then
          for _, node in ipairs(nodes) do
            local name = ts_query.node_text(node, buf)
            if seen_vars[name] then
              local sr, sc = node:start()
              table.insert(diagnostics, {
                lnum = sr,
                col = sc,
                end_lnum = sr,
                end_col = sc + #name,
                severity = vim.diagnostic.severity.WARN,
                message = "Duplicate variable definition: @" .. name,
                source = "poste-http",
              })
            end
            seen_vars[name] = true
          end
        end
      end
    end
  end

  local empty_header_query = [[
    (header
      (header_key) @key
      (header_value) @val
      (#eq? @val ""))
  ]]
  local ok2, query2 = pcall(vim.treesitter.query.parse, "poste_http", empty_header_query)
  if ok2 then
    for _, match in query2:iter_matches(root, buf, 0, -1) do
      for id, nodes in pairs(match) do
        if type(id) == "number" and nodes then
          for _, node in ipairs(nodes) do
            if query2.captures[id] == "key" then
              local sr, sc = node:start()
              local key_text = ts_query.node_text(node, buf)
              table.insert(diagnostics, {
                lnum = sr,
                col = sc,
                end_lnum = sr,
                end_col = sc + #key_text,
                severity = vim.diagnostic.severity.HINT,
                message = "Empty header value: " .. key_text,
                source = "poste-http",
              })
            end
          end
        end
      end
    end
  end
end

function M.update_diagnostics(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if vim.bo[buf].filetype ~= "poste_http" then return end

  vim.diagnostic.reset(ns, buf)

  local root = ts_query.get_root(buf)
  if not root then return end

  local diagnostics = {}
  walk(root, diagnostics, buf)
  check_semantic_rules(root, diagnostics, buf)

  if #diagnostics > 0 then
    vim.diagnostic.set(ns, buf, diagnostics)
  end
end

function M.enable(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if vim.bo[buf].filetype ~= "poste_http" then return end

  local group = vim.api.nvim_create_augroup("PosteHttpDiagnostics_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "InsertLeave" }, {
    group = group,
    buffer = buf,
    callback = function()
      M.update_diagnostics(buf)
    end,
  })

  vim.api.nvim_create_autocmd("BufDelete", {
    group = group,
    buffer = buf,
    callback = function()
      vim.diagnostic.reset(ns, buf)
    end,
  })

  M.update_diagnostics(buf)
end

function M.disable(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  vim.diagnostic.reset(ns, buf)
  pcall(vim.api.nvim_del_augroup_by_name, "PosteHttpDiagnostics_" .. buf)
end

return M