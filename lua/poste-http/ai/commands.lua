--- Slash commands for the "http" AI context — exposed through poste-ai's
--- command palette (typed "/" in the chat input):
---   /requests  focus this chat on a request from an open .http file
---   /env       bind the chat (and request execution) to an environment
--- The chosen bindings are displayed above the chat input, injected into the
--- system prompt and steer auto_context + codeblock execution.

local notify = require("poste-http.ui.notify").notify
local M = {}

--- Environment names from the scope file's env.json (walk-up discovery, same
--- lookup as env.pick_env).
--- @param scope table|nil chat scope snapshot
--- @return string[]|nil names, string|nil err
function M.env_names(scope)
  local util = require("poste-http.util")
  local file = scope and scope.file
  local dir = file and file ~= "" and vim.fn.fnamemodify(file, ":h") or nil
  if not dir or dir == "" then dir = vim.fn.getcwd() end
  local env_file = util.find_file_upwards("env.json", dir)
  if not env_file then return nil, "no env.json found above " .. dir end
  local ok, lines = pcall(vim.fn.readfile, env_file)
  if not ok then return nil, "cannot read " .. env_file end
  local ok2, parsed = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not ok2 or type(parsed) ~= "table" then return nil, "cannot parse " .. env_file end
  local names = {}
  for name in pairs(parsed) do
    if type(name) == "string" then names[#names + 1] = name end
  end
  table.sort(names)
  return names, nil
end

--- /requests candidates — the same requests as @req/ mentions, plain names.
--- @param prefix string filter by name prefix
--- @param scope table chat scope snapshot
--- @param cb function(candidates)
function M.complete_requests(prefix, scope, cb)
  local blocks_mod = require("poste-http.ai.blocks")
  local mentions = require("poste-http.ai.mentions")
  local items = {}
  for _, src in ipairs(mentions.sources(scope)) do
    local short = vim.fn.fnamemodify(src.file, ":t")
    for _, b in ipairs(blocks_mod.list_requests(src.content)) do
      if b.name:sub(1, #prefix) == prefix then
        items[#items + 1] = {
          label = b.name,
          description = vim.trim(((b.method or "?") .. " " .. (b.path or ""))) .. " (" .. short .. ")",
        }
      end
    end
  end
  cb(items)
end

--- /env candidates from the scoped file's env.json.
--- @param prefix string filter by name prefix
--- @param scope table chat scope snapshot
--- @param cb function(candidates)
function M.complete_envs(prefix, scope, cb)
  local names, err = M.env_names(scope)
  if not names then
    notify(err, vim.log.levels.INFO)
    cb({})
    return
  end
  local items = {}
  for _, name in ipairs(names) do
    if name:sub(1, #prefix) == prefix then
      items[#items + 1] = { label = name, description = "environment" }
    end
  end
  cb(items)
end

--- The commands table handed to poste-ai's context contract.
--- @return table
function M.list()
  return {
    {
      name = "requests",
      desc = "focus this chat on a request from an open .http file",
      complete = function(prefix, scope, cb) M.complete_requests(prefix, scope, cb) end,
      run = function(item, api)
        if item and item.label then api.set_scope("request", item.label) end
      end,
    },
    {
      name = "env",
      desc = "bind the chat (and request execution) to an environment",
      complete = function(prefix, scope, cb) M.complete_envs(prefix, scope, cb) end,
      run = function(item, api)
        if not (item and item.label) then return end
        require("poste-http.http.env").set_env(item.label)
        api.set_scope("env", item.label)
      end,
    },
  }
end

M._test = { env_names = M.env_names }

return M
