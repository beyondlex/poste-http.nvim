local M = {}

local function resolve_file_path(path, buf_dir)
  if not path or path == "" then return nil end
  path = vim.trim(path)
  if path:sub(1, 1) == "~" then
    return vim.fn.expand("~") .. path:sub(2)
  elseif path:sub(1, 1) ~= "/" then
    return vim.fn.simplify(buf_dir .. "/" .. path)
  end
  return path
end

function M.expand_file_includes(content, buf_dir)
  if not content or content == "" then
    return content, nil
  end
  local lines = vim.split(content, "\n", { plain = true })
  local result = {}
  local had_include = false
  for _, line in ipairs(lines) do
    -- Skip script-block lines (< {% ... %} or < {%), they are not file includes.
    local ref = line:match("^%s*<(%s+.+)$")
    if ref and not line:match("^%s*< %s*{%%") then
      local path = vim.trim(ref)
      local resolved = resolve_file_path(path, buf_dir)
      if not resolved then
        return nil, "Invalid file path: " .. path
      end
      local fd = io.open(resolved, "rb")
      if not fd then
        return nil, "File not found: " .. resolved .. " (referenced from body line)"
      end
      -- io.open succeeds on directories (fopen "rb" is legal), but the read
      -- fails — nil here used to be swallowed by table.insert, silently
      -- dropping the include line (and with it the whole body).
      local file_content, read_err = fd:read("*a")
      fd:close()
      if not file_content then
        return nil, "Cannot read file: " .. resolved
          .. " (" .. tostring(read_err or "unreadable") .. ", referenced from body line)"
      end
      table.insert(result, file_content)
      had_include = true
    else
      table.insert(result, line)
    end
  end
  if not had_include then
    return content, nil
  end
  return table.concat(result, "\n"), nil
end

return M