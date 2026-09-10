--- Implicit per-request context for the "http" AI chat: the focused request
--- block plus the blocks it chains from ({{Name.response.*}} refs), always in
--- raw {{placeholder}} form — the variable resolver is never invoked for
--- prompt content. When nothing specific is focused, falls back to a compact
--- request list of the focus file.

local M = {}

local MAX_DEPS = 3
local MAX_CHARS = 8000

--- Render the context block from a focus table (pure seam).
--- focus: { file, env, block|nil, blocks, lines }
--- @param focus table
--- @return string
function M.render(focus)
  local blocks_mod = require("poste-http.ai.blocks")
  local md = ("## Request context (auto)\nFile `%s` env `%s`:\n")
    :format(focus.file, tostring(focus.env or "?"))

  if focus.block then
    local text = blocks_mod.block_text(focus.lines, focus.block)
    md = md .. "\n```http\n" .. text .. "\n```\n"
    local included = 0
    for _, name in ipairs(blocks_mod.dep_names(text)) do
      if included >= MAX_DEPS then break end
      local dep = blocks_mod.find_block(focus.blocks, name)
      if dep and dep.start_line ~= focus.block.start_line then
        included = included + 1
        md = md .. ("\nReferenced request `%s`:\n```http\n%s\n```\n")
          :format(name, blocks_mod.block_text(focus.lines, dep))
      end
    end
  else
    md = md .. "Requests in this file:\n"
    for _, b in ipairs(focus.blocks or {}) do
      md = md .. ("- %s — %s\n")
        :format(b.name, vim.trim(((b.method or "?") .. " " .. (b.path or ""))))
    end
  end

  if #md > MAX_CHARS then
    -- blocks.truncate backs off an incomplete UTF-8 sequence at the cut;
    -- a bare :sub emitted invalid bytes for CJK content.
    md = blocks_mod.truncate(md, MAX_CHARS)
  end
  return md
end

--- poste-ai auto_context contract: cb(md_or_nil). nil when nothing resolves.
--- @param _text string user message text (unused — the focus is state/scope driven)
--- @param scope table chat scope snapshot
--- @param cb function(md_or_nil)
function M.auto_context(_text, scope, cb)
  local focus = require("poste-http.ai.blocks").focus(scope)
  if not focus then
    cb(nil)
    return
  end
  cb(M.render(focus))
end

M._test = { render = M.render, MAX_DEPS = MAX_DEPS, MAX_CHARS = MAX_CHARS }

return M
