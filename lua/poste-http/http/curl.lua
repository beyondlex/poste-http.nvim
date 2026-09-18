--- Curl command parser: converts curl commands to HTTP request format.
local M = {}

--- Read a file for import-time expansion. Text-oriented on purpose: the
--- importer pastes into an editable buffer, so binary @file bodies are out
--- of scope.
local function read_import_file(path)
  if not path or path == "" then return nil end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or type(lines) ~= "table" then return nil end
  return table.concat(lines, "\n")
end

--- Percent-encode like curl --data-urlencode: everything outside the
--- RFC 3986 unreserved set, with space as %20.
local function urlencode(s)
  return (s:gsub("[^%w%-_.~]", function(c)
    return string.format("%%%02X", c:byte())
  end))
end

--- curl --data-urlencode piece forms: `name=value`, `=content`, `content`,
--- and the file forms `name@file` / `@file` / `name>file` / `>file` whose
--- content is read and encoded now (the import bakes it in).
local function build_urlencode_piece(piece)
  local file_name, path = piece:match("^([^=@]*)[@>](.+)$")
  if file_name then
    local content = read_import_file(vim.trim(path))
    if not content then return nil end
    if file_name == "" then return urlencode(content) end
    return file_name .. "=" .. urlencode(content)
  end
  local key, value = piece:match("^([^=]+)=(.*)$")
  if key then return key .. "=" .. urlencode(value) end
  if piece:sub(1, 1) == "=" then return urlencode(piece:sub(2)) end
  return urlencode(piece)
end

--- Expand curl's `@file` data bodies (-d/--data/--data-binary; --data-raw
--- never expands). The import bakes the content in because the only .http
--- body file reference (`< path`) is multipart-only.
local function maybe_expand_data(value)
  if type(value) == "string" and value:sub(1, 1) == "@" then
    local content = read_import_file(value:sub(2))
    if content then return content end
  end
  return value
end

--- Parse one -F/--form piece: `name=value`, `name=@file` (attach with
--- filename), `name=<file` (content only), `--form-string` passes
--- expand_at=false so `@` stays literal. curl's `;type=` / `;filename=` /
--- `;enc=` directives after a file path are dropped. File parts keep the
--- PATH instead of baking content in — the .http body's `< path` line is
--- resolved per run, so re-runs pick up file changes and binary uploads
--- never pass through the text importer.
local function parse_form_piece(piece, expand_at)
  local name, rest = piece:match("^([^=]+)=(.*)$")
  if not name then return nil end
  local part = { name = name }
  local sigil = rest:sub(1, 1)
  -- --form-string (expand_at=false) treats @/< as literal text; only -F
  -- and --form expand file sigils.
  local is_file = expand_at and (sigil == "@" or sigil == "<")
  local path = is_file and rest:sub(2) or nil
  if path and path ~= "" then
    -- Strip trailing ;key=value directives right-to-left; a lone `;` or a
    -- directive-shaped prefix stays part of the path.
    while true do
      local stripped = path:match("^(.-);%a+=[^;]*$")
      if not stripped or stripped == "" then break end
      path = stripped
    end
    part.file_path = path
    part.content_only = sigil == "<"
  else
    part.value = rest
  end
  return part
end

--- Render form parts as multipart body text in the same shape copy_as_curl
--- parses back out (boundary lines, Content-Disposition, `< path` refs).
local function build_multipart_body(parts, boundary)
  local lines = {}
  for _, part in ipairs(parts) do
    lines[#lines + 1] = "--" .. boundary
    if part.file_path and not part.content_only then
      lines[#lines + 1] = string.format('Content-Disposition: form-data; name="%s"; filename="%s"',
        part.name, vim.fn.fnamemodify(part.file_path, ":t"))
    else
      lines[#lines + 1] = string.format('Content-Disposition: form-data; name="%s"', part.name)
    end
    lines[#lines + 1] = ""
    if part.file_path then
      lines[#lines + 1] = "< " .. part.file_path
    else
      lines[#lines + 1] = part.value
    end
  end
  lines[#lines + 1] = "--" .. boundary .. "--"
  return table.concat(lines, "\n")
end

--- Import-time multipart boundary. Deterministic is fine: the delimiter
--- only has to be unique within the one body that declares it.
local function generate_boundary()
  return string.format("----PosteBoundary%08x%04x",
    os.time(), math.floor(os.clock() * 65536) % 65536)
end

--- Basic auth from `-u user:pass`, as the header the .http file would write.
local function add_basic_auth(headers, creds)
  if creds and creds ~= "" and vim.base64 and vim.base64.encode then
    table.insert(headers, { "Authorization", "Basic " .. vim.base64.encode(creds) })
  end
end

--- Parse curl command and extract method, URL, headers, and body.
--- Supports: curl -X METHOD, -H header (incl. empty-value `Name:`/`Name;`),
--- -d/--data/--data-binary (incl. @file), --data-raw, --data-urlencode,
--- -F/--form/--form-string (as a multipart body with `< path` file refs),
--- -u/--user (as an Authorization: Basic header), -G/--get (data moves to
--- the query string), --url[=]. Value flags without a .http mapping (-o/-m/
--- …) are consumed so their values can't be mistaken for the URL; the URL
--- is the FIRST bare argument (curl semantics). Backslash escapes inside
--- "…" are honored.
--- Returns: { method = "POST", url = "...", headers = {...}, body = "..." }
local function parse_curl(cmd)
  if not cmd or cmd == "" then
    return nil, "Empty curl command"
  end

  -- Remove leading/trailing whitespace and line continuations
  cmd = vim.trim(cmd)
  cmd = cmd:gsub("\\\n", " ")  -- Remove backslash-newline continuations
  cmd = cmd:gsub("\\\r\n", " ")

  -- Remove "curl" command itself
  cmd = cmd:gsub("^curl%s+", "")

  local method = "GET"
  local url = ""
  local headers = {}
  local body = nil

  -- Parse arguments
  local args = {}
  local current = ""
  local in_quotes = false
  local quote_char = nil
  local i = 1

  while i <= #cmd do
    local char = cmd:sub(i, i)

    if not in_quotes then
      if char == '"' or char == "'" then
        in_quotes = true
        quote_char = char
      elseif char == ' ' or char == '\t' then
        if #current > 0 then
          table.insert(args, current)
          current = ""
        end
      else
        current = current .. char
      end
    elseif char == quote_char then
      in_quotes = false
      quote_char = nil
    elseif quote_char == '"' and char == "\\" and i < #cmd then
      -- Double quotes honor backslash escapes (POSIX shell rules): `\"`
      -- must not close the string, or pasted Windows-style bodies like
      -- -d "{\"k\": \"v\"}" arrive mangled. Single quotes are literal in
      -- the shell, so the escape pass only runs for `"..."`
      local nxt = cmd:sub(i + 1, i + 1)
      if nxt == quote_char or nxt == "\\" then
        current = current .. nxt
        i = i + 1
      else
        current = current .. char
      end
    else
      current = current .. char
    end

    i = i + 1
  end

  if #current > 0 then
    table.insert(args, current)
  end

  -- Process arguments
  -- Every --data-* piece feeds one ordered list joined with `&`, exactly as
  -- curl concatenates them on the wire (`-d a=1 -d b=2` sends `a=1&b=2`,
  -- verified against curl 8.7.1); --data-urlencode pieces are encoded at
  -- add time and keep their position in the sequence.
  local data_parts = {}
  local had_urlencode = false
  local form_parts = {}
  local get_flag = false
  local had_content_type = false
  local content_type_value = nil

  local function promote_post()
    if method == "GET" then
      method = "POST"
    end
  end
  -- True once -X/--request named an explicit method; a --get rewrite must
  -- not clobber it (curl sends the -X token, with the data still in the
  -- query string).
  local method_forced = false

  local function header_from_text(text)
    -- `Name:` (empty value) and curl's `Name;` no-value form are kept as
    -- empty-value headers instead of being dropped.
    local key, value = text:match("^([^:;]+):%s*(.*)$")
    if not key then
      key = vim.trim(text:match("^([^;]+);%s*$") or "")
      value = ""
    end
    if key and key ~= "" then
      table.insert(headers, { key, value })
      if key:lower() == "content-type" then
        had_content_type = true
        content_type_value = value
      end
    end
  end

  local idx = 1
  -- Short flags whose value we don't map into the .http form (output file,
  -- proxy, timeouts, certs, …): their value must be consumed, or a bare
  -- value like `-o out.txt` used to win the "last bare arg is the URL"
  -- scan and replace the real request target.
  local ignored_value_short = {
    o = true, A = true, e = true, b = true, x = true,
    m = true, D = true, E = true, Q = true, T = true, Y = true, y = true,
    C = true, K = true, w = true, c = true, P = true, r = true, t = true,
    U = true, z = true,
  }
  -- Same for long flags, matched in both `--flag value` and `--flag=value`
  -- shapes (the `=` shapes are handled by prefix below).
  local ignored_value_long = {
    ["--output"] = true, ["--user-agent"] = true,
    ["--referer"] = true, ["--cookie"] = true, ["--proxy"] = true,
    ["--max-time"] = true, ["--connect-timeout"] = true, ["--retry"] = true,
    ["--retry-delay"] = true, ["--dump-header"] = true, ["--cacert"] = true,
    ["--capath"] = true, ["--cert"] = true, ["--key"] = true,
    ["--resolve"] = true, ["--unix-socket"] = true, ["--config"] = true,
    ["--cookie-jar"] = true, ["--proxy-user"] = true, ["--range"] = true,
    ["--time-cond"] = true, ["--upload-file"] = true, ["--trace"] = true,
    ["--trace-ascii"] = true, ["--ftp-port"] = true,
    ["--telnet-option"] = true, ["--proto"] = true,
    ["--proto-redir"] = true, ["--request-target"] = true,
    ["--engine"] = true, ["--random-file"] = true, ["--crlfile"] = true,
    ["--pinnedpubkey"] = true, ["--pubkey"] = true,
  }
  while idx <= #args do
    local arg = args[idx]

    if arg == "-X" or arg == "--request" then
      idx = idx + 1
      method = (args[idx] or "GET"):upper()
      method_forced = true
    elseif arg:match("^%-X.") then
      -- Attached form: -XPOST
      method = arg:sub(3):upper()
      method_forced = true
    elseif arg:match("^%-%-request=") then
      method = arg:sub(#"--request=" + 1):upper()
      method_forced = true
    elseif arg == "-H" or arg == "--header" then
      idx = idx + 1
      local header = args[idx]
      if header then
        header_from_text(header)
      end
    elseif arg:match("^%-H.") then
      -- Attached form: -H'Content-Type: ...'
      header_from_text(arg:sub(3))
    elseif arg:match("^%-%-header=") then
      header_from_text(arg:sub(#"--header=" + 1))
    elseif arg == "--data-urlencode" then
      idx = idx + 1
      local piece = args[idx]
      if piece then
        local built = build_urlencode_piece(piece)
        if built then
          table.insert(data_parts, built)
          had_urlencode = true
        end
      end
      promote_post()
    elseif arg:match("^%-%-data%-urlencode=") then
      local built = build_urlencode_piece(arg:sub(#"--data-urlencode=" + 1))
      if built then
        table.insert(data_parts, built)
        had_urlencode = true
      end
      promote_post()
    elseif arg == "-d" or arg == "--data" or arg == "--data-binary" then
      idx = idx + 1
      table.insert(data_parts, maybe_expand_data(args[idx]))
      promote_post()
    elseif arg:match("^%-d.") then
      -- Attached form: -d'{}', -d@file
      table.insert(data_parts, maybe_expand_data(arg:sub(3)))
      promote_post()
    elseif arg == "--data-raw" then
      idx = idx + 1
      -- --data-raw never expands @file, matching curl
      table.insert(data_parts, args[idx])
      promote_post()
    elseif arg:match("^%-%-data=") then
      table.insert(data_parts, maybe_expand_data(arg:sub(#"--data=" + 1)))
      promote_post()
    elseif arg:match("^%-%-data%-binary=") then
      table.insert(data_parts, maybe_expand_data(arg:sub(#"--data-binary=" + 1)))
      promote_post()
    elseif arg:match("^%-%-data%-raw=") then
      -- --data-raw never expands @file, matching curl
      table.insert(data_parts, arg:sub(#"--data-raw=" + 1))
      promote_post()
    elseif arg == "-G" or arg == "--get" then
      -- Data pieces ride on the query string instead of a body; handled
      -- after the loop once the URL is final.
      get_flag = true
    elseif arg == "-F" or arg == "--form" or arg == "--form-string" then
      idx = idx + 1
      local piece = args[idx]
      local part = piece and parse_form_piece(piece, arg ~= "--form-string")
      if part then table.insert(form_parts, part) end
      promote_post()
    elseif arg:match("^%-F.") or arg:match("^%-%-form=") or arg:match("^%-%-form%-string=") then
      local piece = arg:match("^%-F(.+)$")
        or arg:match("^%-%-form=(.+)$")
        or arg:match("^%-%-form%-string=(.+)$")
      local part = parse_form_piece(piece, not arg:match("^%-%-form%-string"))
      if part then table.insert(form_parts, part) end
      promote_post()
    elseif arg == "-u" or arg == "--user" then
      idx = idx + 1
      add_basic_auth(headers, args[idx])
    elseif arg:match("^%-u.") or arg:match("^%-%-user=") then
      add_basic_auth(headers, arg:match("^%-u(.+)$") or arg:match("^%-%-user=(.+)$"))
    elseif arg == "--url" then
      idx = idx + 1
      url = url == "" and (args[idx] or "") or url
    elseif arg:match("^%-%-url=") then
      if url == "" then url = arg:sub(#"--url=" + 1) end
    elseif ignored_value_long[arg] then
      -- `--flag value` shape: drop both.
      idx = idx + 1
    elseif arg:match("^%-(%a)") then
      -- Generic short flag. Known value flags take their value from the
      -- rest of the arg (attached `-m10`) or the next arg (separate
      -- `-m 10`); boolean flags (-s, -L, -k, …) have no value to consume.
      local letter, rest = arg:match("^%-(%a)(.*)$")
      if ignored_value_short[letter] and rest == "" then
        idx = idx + 1
      end
    else
      -- Assume it's the URL: curl sends the FIRST bare argument; a second
      -- one is an additional URL, not a replacement for the first.
      if not arg:match("^-") and url == "" then
        url = arg
      end
    end

    idx = idx + 1
  end

  if url == "" then
    return nil, "No URL found in curl command"
  end

  -- curl concatenates every data piece (-d, --data-binary, --data-raw,
  -- --data-urlencode) with & in command order before sending; mirror that,
  -- and give the request the form content-type only when the command used
  -- --data-urlencode (a bare -d '{"json"}' import stays content-type-clean).
  if #data_parts > 0 then
    body = table.concat(data_parts, "&")
    if get_flag then
      -- --get moves the data onto the query string whatever -X says (curl
      -- sends `PUT /?a=1` for `--get -X PUT -d a=1`); append with & when the
      -- URL already carries a query. Without an explicit -X the request
      -- stays a GET (undo the data flags' POST promotion).
      url = url .. (url:find("?", 1, true) and "&" or "?") .. body
      body = nil
      if not method_forced then
        method = "GET"
      end
    elseif had_urlencode and not had_content_type then
      table.insert(headers, { "Content-Type", "application/x-www-form-urlencoded" })
    end
  end

  -- -F parts become a multipart body in the .http shape (boundary lines +
  -- Content-Disposition + `< path` refs). Mixing -d with -F is a curl
  -- usage error; the -d body wins here and the parts are dropped.
  if #form_parts > 0 and not body then
    local boundary
    local ct_multipart = content_type_value
      and content_type_value:match("multipart/form%-data") ~= nil
    if ct_multipart then
      boundary = vim.trim(content_type_value:match("boundary=([^;]+)") or "")
      -- A quoted boundary (`boundary="abc"`) is one value per RFC 2045; the
      -- delimiter lines must carry the unquoted token or no server can
      -- match them to the header.
      boundary = boundary:match('^"(.*)"$') or boundary
    end
    if boundary == nil or boundary == "" then
      boundary = generate_boundary()
      if ct_multipart then
        -- extend the existing multipart Content-Type in place
        for _, h in ipairs(headers) do
          if h[1]:lower() == "content-type" then
            h[2] = h[2] .. "; boundary=" .. boundary
          end
        end
      else
        table.insert(headers, { "Content-Type", "multipart/form-data; boundary=" .. boundary })
      end
    end
    body = build_multipart_body(form_parts, boundary)
  end

  return {
    method = method,
    url = url,
    headers = headers,
    body = body,
  }
end

--- Convert parsed curl to HTTP request format lines.
--- Returns array of lines to insert.
local function curl_to_http(parsed)
  local lines = {}

  -- Request separator
  table.insert(lines, "###")

  -- Request line
  table.insert(lines, string.format("%s %s", parsed.method, parsed.url))

  -- Headers
  for _, h in ipairs(parsed.headers) do
    table.insert(lines, string.format("%s: %s", h[1], h[2]))
  end

  -- Body (if present): split multi-line body into separate lines, keeping
  -- interior blank lines (they are part of the body); only trailing
  -- newlines are dropped.
  if parsed.body then
    table.insert(lines, "")  -- Empty line before body
    local normalized = parsed.body:gsub("\r\n", "\n"):gsub("\r", "\n")
    local body_lines = vim.split(normalized, "\n", { plain = true })
    while #body_lines > 0 and vim.trim(body_lines[#body_lines]) == "" do
      table.remove(body_lines)
    end
    for _, body_line in ipairs(body_lines) do
      table.insert(lines, body_line)
    end
  end

  return lines
end

--- Read curl command from clipboard and insert as HTTP request at cursor.
--- register: '+' for system clipboard, '*' for X11 primary, or any vim register
function M.paste_curl(register)
  register = register or "+"

  -- Read from register
  local content = vim.fn.getreg(register)
  if not content or content == "" then
    vim.notify("Clipboard is empty", vim.log.levels.WARN, { title = "Poste" })
    return
  end

  -- Parse curl command
  local parsed, err = parse_curl(content)
  if not parsed then
    vim.notify("Failed to parse curl: " .. err, vim.log.levels.ERROR, { title = "Poste" })
    return
  end

  -- Convert to HTTP format
  local lines = curl_to_http(parsed)

  -- Insert at current cursor position
  local row = vim.fn.line(".")
  vim.api.nvim_buf_set_lines(0, row, row, false, lines)

  vim.notify("Inserted HTTP request from clipboard", vim.log.levels.INFO, { title = "Poste" })
end

--- Exposed for tests and future importers; paste_curl is the user entry.
M.parse_curl = parse_curl

return M
