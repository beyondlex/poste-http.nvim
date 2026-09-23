local curl_exec = require("poste-http.http.curl_exec")

describe("curl_exec.execute", function()
  local orig_jobstart
  local captured_args
  local captured_opts
  local fake_job_id

  before_each(function()
    orig_jobstart = vim.fn.jobstart
    captured_args = nil
    captured_opts = nil
    fake_job_id = 12345
    vim.fn.jobstart = function(cmd, opts)
      captured_args = cmd
      captured_opts = opts
      return fake_job_id
    end
  end)

  after_each(function()
    vim.fn.jobstart = orig_jobstart
  end)

  it("builds curl command with method and URL", function()
    curl_exec.execute({
      method = "POST",
      url = "https://api.example.com/users",
      headers = { { "Content-Type", "application/json" } },
      body = '{"name": "test"}',
    }, function() end)

    assert.is_string(captured_args)
    assert.matches("curl", captured_args)
    assert.matches("https://api%.example%.com/users", captured_args)
    assert.matches("-X POST", captured_args)
    assert.matches("Content%-Type: application/json", captured_args)
    assert.matches("--data%-binary", captured_args)
  end)

  it("asks curl for %{num_redirects} into a redirect count file", function()
    -- body (-o) and headers (-D) go to their own files, so stdout only
    -- carries the --write-out output; it is shell-redirected into the
    -- count file response_parser reads.
    curl_exec.execute({ method = "GET", url = "https://api.example.com" }, function() end)
    assert.matches("%-%-write%-out '%%{num_redirects}'", captured_args)
    assert.matches("1> ", captured_args)
  end)

  it("emits -- before the URL so it can never parse as flags", function()
    -- The URL is curl's only free-position argument; a value there starting
    -- with `-` would be parsed as options. Option VALUES are safe regardless
    -- of quoting (getopt consumes the next argv as the optarg), so the `--`
    -- separator is the real guard.
    curl_exec.execute({ method = "GET", url = "https://example.com/x" }, function() end)
    assert.matches("%-%- https://example%.com/x", captured_args)
  end)

  it("returns error when URL is empty", function()
    local result
    curl_exec.execute({ method = "GET", url = "" }, function(r) result = r end)
    assert.is_not_nil(result)
    assert.matches("No URL", result.error)
  end)

  it("returns error when jobstart fails", function()
    vim.fn.jobstart = function() return -1 end
    local result
    curl_exec.execute({ method = "GET", url = "https://example.com" }, function(r) result = r end)
    assert.is_not_nil(result)
    assert.matches("Failed to start curl", result.error)
  end)

  it("triggers parse_error on non-zero exit", function()
    local callback_result
    curl_exec.execute({ method = "GET", url = "https://example.com/api" }, function(r) callback_result = r end)

    assert.is_not_nil(captured_opts)
    assert.is_function(captured_opts.on_exit)

    captured_opts.on_exit(fake_job_id, 7)

    vim.wait(100, function() return callback_result ~= nil end)
    assert.is_not_nil(callback_result)
    assert.equals("error", callback_result.protocol)
    assert.equals(0, callback_result.status)
  end)

  it("triggers parse_response on zero exit with output", function()
    local callback_result
    curl_exec.execute({ method = "GET", url = "https://example.com/api" }, function(r) callback_result = r end)

    captured_opts.on_stdout(fake_job_id, { "stdout line 1", "stdout line 2" }, nil)
    captured_opts.on_stderr(fake_job_id, { "stderr line" }, nil)
    captured_opts.on_exit(fake_job_id, 0)

    vim.wait(100, function() return callback_result ~= nil end)
    assert.is_not_nil(callback_result)
  end)

  it("handles file include errors", function()
    local file_include = require("poste-http.http.file_include")
    local orig_expand = file_include.expand_file_includes
    file_include.expand_file_includes = function()
      return nil, "File not found: /nonexistent"
    end

    local result
    curl_exec.execute({ method = "GET", url = "https://example.com", body = "< /nonexistent" }, function(r) result = r end)

    assert.is_not_nil(result)
    assert.matches("File not found", result.error)

    file_include.expand_file_includes = orig_expand
  end)

  it("creates temp directory and cleans up on error", function()
    vim.fn.jobstart = function() return -1 end
    local result
    curl_exec.execute({ method = "GET", url = "https://example.com" }, function(r) result = r end)
    assert.is_not_nil(result)
    assert.matches("Failed to start curl", result.error)
  end)

  it("redacts sensitive header values from the log", function()
    local state = require("poste-http.state")
    local orig_log = state.log
    local logged
    state.log = function(_, msg)
      logged = msg
    end
    vim.fn.jobstart = function() return -1 end

    curl_exec.execute({
      method = "GET",
      url = "https://api.example.com/secret",
      headers = {
        { "Authorization", "Bearer sekrit-token-123" },
        { "X-Api-Key", "super-secret-key" },
        { "Content-Type", "application/json" },
      },
    }, function() end)

    state.log = orig_log

    assert.is_not_nil(logged)
    assert.matches("curl: ", logged)
    assert.is_false(logged:find("sekrit%-token%-123", 1, true) ~= nil,
      "Authorization value must not appear in log")
    assert.is_false(logged:find("super%-secret%-key", 1, true) ~= nil,
      "X-Api-Key value must not appear in log")
    assert.matches("Authorization: %[REDACTED%]", logged)
    assert.matches("X%-Api%-Key: %[REDACTED%]", logged)
    assert.matches("Content%-Type: application/json", logged)
  end)

  it("adds --max-time from opts.timeout in seconds", function()
    curl_exec.execute({
      method = "GET",
      url = "https://api.example.com/slow",
      timeout = 5000,
    }, function() end)

    assert.matches("--max%-time 5", captured_args)
  end)

  it("defaults --max-time when no timeout given", function()
    curl_exec.execute({
      method = "GET",
      url = "https://api.example.com/slow",
    }, function() end)

    assert.matches("--max%-time 30", captured_args)
  end)

  it("returns error when request body temp file cannot be written", function()
    local orig_open = io.open
    io.open = function(path, mode)
      if path:find("body$") then
        return nil, "permission denied"
      end
      return orig_open(path, mode)
    end

    local result
    curl_exec.execute({
      method = "POST",
      url = "https://api.example.com",
      body = '{"a": 1}',
    }, function(r) result = r end)

    io.open = orig_open

    assert.is_not_nil(result)
    assert.matches("Failed to write request body", result.error)
  end)
end)

-- The body a .http file declares is annotated JSON (`//`/`#`/`--` comments,
-- blank lines). It is normalized on the way out — after `< path` expansion, so
-- an external payload file gets the same treatment — and never rewritten when
-- the result would not parse.
describe("curl_exec.execute JSON body normalization", function()
  local orig_jobstart
  local captured_cmd

  before_each(function()
    orig_jobstart = vim.fn.jobstart
    captured_cmd = nil
    vim.fn.jobstart = function(cmd)
      captured_cmd = cmd
      return 12345
    end
  end)

  after_each(function()
    vim.fn.jobstart = orig_jobstart
  end)

  local function sent_body()
    local raw = captured_cmd:match("%-%-data%-binary (%S+)")
    if not raw then return nil end
    -- shell_escape may or may not quote the path; either way, unwrap it.
    local path = raw:gsub("'", ""):gsub("^@", "")
    return table.concat(vim.fn.readfile(path), "\n")
  end

  it("strips comments and blank lines from a JSON body", function()
    curl_exec.execute({
      method = "POST",
      url = "https://api.example.com/users",
      headers = { { "Content-Type", "application/json" } },
      body = '{\n  "a": "b",\n  // trimmed\n\n  "c": "https://x.test/p"\n}',
    }, function() end)

    local body = sent_body()
    assert.equals('{\n  "a": "b",\n  "c": "https://x.test/p"\n}', body)
    assert.is_true(pcall(vim.json.decode, body))
  end)

  it("normalizes a body pulled in by a < path include", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local path = dir .. "/payload.json"
    local fd = io.open(path, "wb")
    fd:write('{\n  "a": 1,\n  -- gone\n}')
    fd:close()

    curl_exec.execute({
      method = "POST",
      url = "https://api.example.com/users",
      body = "< " .. path,
    }, function() end)

    assert.equals('{\n  "a": 1\n}', sent_body())
  end)

  it("leaves a non-JSON body alone", function()
    curl_exec.execute({
      method = "POST",
      url = "https://api.example.com/login",
      headers = { { "Content-Type", "application/x-www-form-urlencoded" } },
      body = "a=1\n\nb=2",
    }, function() end)

    assert.equals("a=1\n\nb=2", sent_body())
  end)

  it("sends an unparseable JSON-shaped body as written, with a warning", function()
    local state = require("poste-http.state")
    local orig_log = state.log
    local logged = {}
    state.log = function(level, msg)
      logged[#logged + 1] = level .. ": " .. msg
    end

    local src = '{\n  "a": ,,\n}'
    curl_exec.execute({
      method = "POST",
      url = "https://api.example.com/users",
      body = src,
    }, function() end)

    state.log = orig_log
    assert.equals(src, sent_body())
    assert.matches("not parseable", table.concat(logged, "\n"))
  end)
end)