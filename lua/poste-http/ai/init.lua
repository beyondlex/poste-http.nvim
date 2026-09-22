--- poste-http AI integration — registers an "http" context on poste-ai.nvim
--- (optional dependency). Zero coupling: poste-ai is never required at load
--- time; registration is attempted in setup() and on :PosteHttpChat.
--- All prompt content carries raw {{var}} placeholders — resolved values
--- (credentials) never enter the chat.

local blocks_mod = require("poste-http.ai.blocks")

local M = {}

--- True when poste-ai.nvim is on the runtimepath.
function M.available()
  return (pcall(require, "poste-ai")) and true or false
end

--- Register (or refresh) the "http" context. Returns false when poste-ai is
--- not installed; callers decide whether that is worth telling the user.
--- @return boolean
function M.register()
  local ok, poste_ai = pcall(require, "poste-ai")
  if not ok then return false end
  poste_ai.register_context("http", {
    system_prompt = function(scope)
      return require("poste-http.ai.system_prompt").build(scope)
    end,
    auto_context = function(text, scope, cb)
      require("poste-http.ai.auto_context").auto_context(text, scope, cb)
    end,
    commands = require("poste-http.ai.commands").list(),
    mention = {
      match = function(token)
        return require("poste-http.ai.mentions").match(token)
      end,
      complete = function(prefix, cb)
        require("poste-http.ai.mentions").complete(prefix, cb)
      end,
      resolve = function(ref, cb)
        require("poste-http.ai.mentions").resolve(ref, cb)
      end,
    },
    codeblock = {
      langs = { "http" },
      confirm = function(text)
        return require("poste-http.ai.actions").confirm_http(text)
      end,
      execute = function(text, refs, cb)
        require("poste-http.ai.actions").execute_http(text, refs, cb)
      end,
      append_header = function(scope, text)
        return require("poste-http.ai.actions").append_header(scope, text)
      end,
    },
  })
  return true
end

--- Bind file/env keys on the chat scope so prompts and execution target the
--- right file and environment.
local function scope_chat_target(file, env)
  local ok, scope = pcall(require, "poste-ai.chat.scope")
  if not ok then return end
  if file and file ~= "" then scope.set("file", file) end
  if env and env ~= "" then scope.set("env", env) end
end

--- Open the AI chat with the http context active, scoped to the current
--- `.http` buffer when there is one.
function M.open_chat()
  if not M.available() then
    vim.notify("PosteHttp AI chat needs poste-ai.nvim (beyondlex/poste-ai.nvim) installed.",
      vim.log.levels.WARN, { title = "PosteHttp" })
    return
  end
  M.register()
  local poste_ai = require("poste-ai")
  poste_ai.set_active_context("http")
  local buf = vim.api.nvim_get_current_buf()
  if vim.bo[buf].filetype == "poste_http" then
    scope_chat_target(vim.api.nvim_buf_get_name(buf), nil)
  end
  poste_ai.chat("http")
end

--- Open chat + prefill input, shared by the ask entry points.
local function open_with_prefill(text, file, env)
  M.register()
  local poste_ai = require("poste-ai")
  poste_ai.set_active_context("http")
  scope_chat_target(file, env)
  poste_ai.chat("http")
  local window = require("poste-ai.chat.window")
  window.set_input_text(text)
  window.focus_input(true)
end

--- Build the ask-prefill question from response state (pure; exported via
--- _test). Directive line first, then the raw request block, errors, response
--- summary (headers + truncated body) and failed assertions.
--- @param opts table { directive, file, env, request_text, errors_lines,
---                     response, assertion_results, max_body }
--- @return string
function M.build_question(opts)
  local parts = {}
  if opts.directive and opts.directive ~= "" then
    parts[#parts + 1] = opts.directive
  end

  local where = {}
  if opts.file and opts.file ~= "" then where[#where + 1] = "file `" .. opts.file .. "`" end
  if opts.env and opts.env ~= "" then where[#where + 1] = "env `" .. opts.env .. "`" end
  if opts.request_text and opts.request_text ~= "" then
    parts[#parts + 1] = table.concat(where, ", ")
    parts[#parts + 1] = "```http\n" .. opts.request_text .. "\n```"
  end

  if opts.errors_lines and #opts.errors_lines > 0 then
    local lines = {}
    for _, l in ipairs(opts.errors_lines) do
      lines[#lines + 1] = vim.trim(l)
    end
    parts[#parts + 1] = "Errors:\n```\n" .. table.concat(lines, "\n") .. "\n```"
  end

  local r = opts.response
  if r then
    local resp = {}
    resp[#resp + 1] = ("Status: %s %s"):format(tostring(r.status or "?"), r.status_text or "")
    if r.metadata and r.metadata.method and r.url and r.url ~= "" then
      resp[#resp + 1] = ("Request: %s %s"):format(r.metadata.method, r.url)
    end
    if type(r.headers) == "table" and #r.headers > 0 then
      resp[#resp + 1] = "Response headers:"
      for _, h in ipairs(r.headers) do
        resp[#resp + 1] = "- " .. tostring(h[1]) .. ": " .. tostring(h[2])
      end
    end
    if type(r.body) == "string" and r.body ~= "" then
      resp[#resp + 1] = "Body:\n```\n"
        .. blocks_mod.truncate(r.body, opts.max_body or 4096) .. "\n```"
    end
    parts[#parts + 1] = table.concat(resp, "\n")
  end

  local ar = opts.assertion_results
  if ar and (ar.failed or 0) > 0 then
    local lines = { ("Assertions: %d/%d passed"):format(ar.passed or 0, ar.total or 0) }
    if ar.error then lines[#lines + 1] = "Error: " .. tostring(ar.error) end
    for _, t in ipairs(ar.tests or {}) do
      if (t.failed or 0) > 0 or #(t.errors or {}) > 0 then
        lines[#lines + 1] = ("- FAIL %s: %s")
          :format(t.name or "?", table.concat(t.errors or {}, "; "))
      end
    end
    parts[#parts + 1] = table.concat(lines, "\n")
  end

  return table.concat(parts, "\n\n")
end

--- `a` in the response panel: prefill the chat with the request that ran and
--- whatever results exist (errors / response / failed assertions), scoped to
--- its file and environment.
function M.ask_view()
  if not M.available() then
    vim.notify("PosteHttp AI chat needs poste-ai.nvim (beyondlex/poste-ai.nvim) installed.",
      vim.log.levels.WARN, { title = "PosteHttp" })
    return
  end
  local state = require("poste-http.state")
  local errors_mod = require("poste-http.http.errors")

  local file, request_text = nil, nil
  local lr = state.last_request
  if lr and lr.buf and vim.api.nvim_buf_is_valid(lr.buf) then
    file = vim.api.nvim_buf_get_name(lr.buf)
    local content = table.concat(vim.api.nvim_buf_get_lines(lr.buf, 0, -1, false), "\n")
    request_text = blocks_mod.block_text_at_line(content, lr.line)
  end

  local has_errors = state.last_errors and #state.last_errors > 0
  local errors_lines = has_errors and errors_mod.format_errors(state.last_errors) or nil

  local text = M.build_question({
    directive = has_errors
      and "This HTTP request failed — help me debug it:"
      or "Help me with this response:",
    file = file,
    env = state.current_env,
    request_text = request_text,
    errors_lines = errors_lines,
    response = state.last_response,
    assertion_results = state.last_assertion_results,
  })
  if vim.trim(text) == "" then
    vim.notify("nothing to ask about — run a request first", vim.log.levels.INFO, { title = "PosteHttp" })
    return
  end
  open_with_prefill(text, file, state.current_env)
end

--- `ga` in a `.http` buffer (normal or visual): prefill the chat with the
--- request under the cursor or the visual selection.
function M.ask_request()
  if not M.available() then
    vim.notify("PosteHttp AI chat needs poste-ai.nvim (beyondlex/poste-ai.nvim) installed.",
      vim.log.levels.WARN, { title = "PosteHttp" })
    return
  end
  local buf = vim.api.nvim_get_current_buf()
  if vim.bo[buf].filetype ~= "poste_http" then
    vim.notify("not a .http buffer", vim.log.levels.INFO, { title = "PosteHttp" })
    return
  end

  local l1, l2 = nil, nil
  local mode = vim.fn.mode()
  if mode:match("^[vV]") or mode == "\22" then
    l1, l2 = vim.fn.line("'<"), vim.fn.line("'>")
    if l1 > l2 then l1, l2 = l2, l1 end
    -- leave visual mode before opening the chat split
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
  end

  local state = require("poste-http.state")
  local file = vim.api.nvim_buf_get_name(buf)
  -- Only name the env when one is bound: a literal "env `nil`" in the
  -- prompt invites the model to invent one.
  local where = ("file `%s`"):format(file ~= "" and file or "scratch")
  if state.current_env and state.current_env ~= "" then
    where = where .. (", env `%s`"):format(state.current_env)
  end

  local block_text
  if l1 then
    local lines = vim.api.nvim_buf_get_lines(buf, l1 - 1, l2, false)
    block_text = table.concat(lines, "\n")
  else
    local content = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    block_text = blocks_mod.block_text_at_line(content, vim.fn.line("."))
    if not block_text then
      vim.notify("cursor is not on a request block", vim.log.levels.INFO, { title = "PosteHttp" })
      return
    end
  end

  local text = "About this request (" .. where .. "):\n\n```http\n" .. block_text .. "\n```"
  open_with_prefill(text, file ~= "" and file or nil, state.current_env)
end

M._test = {
  available = M.available,
  build_question = M.build_question,
  register = M.register,
}

return M
