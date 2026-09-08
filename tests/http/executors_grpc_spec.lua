-- Tests for the gRPC executor (docs/dev/multi-protocol-design.md).
--
-- The executor wraps grpcurl: block elements translate to argv, and
-- grpcurl's stdout/stderr map onto the canonical response shape with
-- gRPC status codes (0-16) in `status` and the protocol-aware `ok` flag.

local grpc = require("poste-http.http.executors.grpc")

describe("grpc.parse_target", function()
  it("splits host and service method path", function()
    local t = grpc.parse_target("localhost:50051/grpc.examples.echo.EchoService/Echo")
    assert.equals("localhost:50051", t.host)
    assert.equals("grpc.examples.echo.EchoService/Echo", t.method)
  end)

  it("returns a bare host in list mode", function()
    local t = grpc.parse_target("localhost:50051")
    assert.equals("localhost:50051", t.host)
    assert.is_nil(t.method)
  end)
end)

describe("grpc.build_args", function()
  it("builds an invoke command ending with host and method", function()
    local args = grpc.build_args({
      url = "localhost:50051/pkg.EchoService/Echo",
      headers = {}, body = "", timeout = 30000,
    })
    assert.equals("grpcurl", args[1])
    assert.equals("localhost:50051", args[#args - 1])
    assert.equals("pkg.EchoService/Echo", args[#args])
    assert.is_nil(vim.tbl_contains(args, "-d") and true or nil)
  end)

  it("passes the message via stdin when a body is present", function()
    local args, stdin = grpc.build_args({
      url = "localhost:50051/pkg.EchoService/Echo",
      headers = {}, body = '{"message": "hi"}', timeout = 30000,
    })
    assert.equals("localhost:50051", args[#args - 1])
    assert.equals("pkg.EchoService/Echo", args[#args])
    local dash_d = nil
    for i, a in ipairs(args) do
      if a == "-d" then dash_d = i end
    end
    assert.is_not_nil(dash_d)
    assert.equals("@", args[dash_d + 1])
    assert.equals('{"message": "hi"}', stdin)
  end)

  it("translates @grpc-* operators into grpcurl flags", function()
    local args = grpc.build_args({
      url = "localhost:50051/pkg.EchoService/Echo",
      headers = {},
      body = "",
      timeout = 30000,
      operators = {
        ["grpc-import-path"] = { "./protos" },
        ["grpc-proto"] = { "a.proto", "b.proto" },
        ["grpc-proto-set"] = { "protoset.bin" },
        ["grpc-plaintext"] = { "" },
        ["grpc-flags"] = { "-v -connect-timeout 5" },
      },
    })

    local function flag_values(flag)
      local vals = {}
      for i, a in ipairs(args) do
        if a == flag then vals[#vals + 1] = args[i + 1] end
      end
      return vals
    end

    assert.same({ "./protos" }, flag_values("-import-path"))
    assert.same({ "a.proto", "b.proto" }, flag_values("-proto"))
    assert.same({ "protoset.bin" }, flag_values("-proto-set"))
    assert.is_truthy(vim.tbl_contains(args, "-plaintext"))
    assert.same({ "-v", "-connect-timeout", "5" }, (function()
      local idx = nil
      for i, a in ipairs(args) do
        if a == "-v" and args[i + 1] == "-connect-timeout" then idx = i break end
      end
      return idx and { unpack(args, idx, idx + 2) } or {}
    end)())
  end)

  it("sends headers as -H metadata", function()
    local args = grpc.build_args({
      url = "localhost:50051/pkg.EchoService/Echo",
      headers = { { "X-Trace-Id", "abc" } },
      body = "", timeout = 30000,
    })
    local found = false
    for i, a in ipairs(args) do
      if a == "-H" then
        assert.equals("X-Trace-Id: abc", args[i + 1])
        found = true
      end
    end
    assert.is_true(found)
  end)

  it("maps timeout to -max-time in seconds", function()
    local args = grpc.build_args({
      url = "localhost:50051/pkg.EchoService/Echo",
      headers = {}, body = "", timeout = 5000,
    })
    for i, a in ipairs(args) do
      if a == "-max-time" then assert.equals("5", args[i + 1]) end
    end
  end)

  it("builds a reflection list command for a bare host", function()
    local args = grpc.build_args({
      url = "localhost:50051", headers = {}, body = "", timeout = 30000,
    })
    -- grpcurl's list invocation needs the explicit subcommand.
    assert.equals("list", args[#args])
    assert.equals("localhost:50051", args[#args - 1])
    assert.is_nil(vim.tbl_contains(args, "-d") and true or nil)
  end)

  it("accepts the dotted service.method form", function()
    local args = grpc.build_args({
      url = "localhost:50051/pkg.OrderService.PreviewOrder", headers = {}, body = "", timeout = 30000,
    })
    assert.equals("localhost:50051", args[#args - 1])
    assert.equals("pkg.OrderService.PreviewOrder", args[#args])
  end)

  it("rejects an incomplete method with a trailing slash", function()
    local _, _, err = grpc.build_args({
      url = "localhost:50051/pkg.OrderService/", headers = {}, body = "", timeout = 30000,
    })
    assert.is_not_nil(err)
    assert.matches("pkg.OrderService/", err)
    assert.matches("service/method", err)
  end)

  it("rejects an incomplete method with a trailing dot", function()
    local _, _, err = grpc.build_args({
      url = "localhost:50051/pkg.OrderService.", headers = {}, body = "", timeout = 30000,
    })
    assert.is_not_nil(err)
    assert.matches("service/method", err)
  end)

  it("rejects a method name with no service/method separator", function()
    local _, _, err = grpc.build_args({
      url = "localhost:50051/EchoService", headers = {}, body = "", timeout = 30000,
    })
    assert.is_not_nil(err)
    assert.matches("service/method", err)
  end)

  it("rejects a method that is only a separator", function()
    local _, _, err = grpc.build_args({
      url = "localhost:50051//", headers = {}, body = "", timeout = 30000,
    })
    assert.is_not_nil(err)
  end)
end)

describe("grpc response mapping", function()
  it("maps known gRPC code names to status numbers", function()
    assert.equals(0, grpc.map_code("OK"))
    assert.equals(5, grpc.map_code("NotFound"))
    assert.equals(14, grpc.map_code("Unavailable"))
    assert.equals(16, grpc.map_code("Unauthenticated"))
    assert.is_nil(grpc.map_code("SomeWeirdCode"))
  end)

  it("builds an OK response for a successful invocation", function()
    local r = grpc.build_response({
      url = "localhost:50051/pkg.EchoService/Echo",
    }, { '{"message": "hi"}' }, {}, 0, nil)
    assert.equals("grpc", r.protocol)
    assert.equals(0, r.status)
    assert.is_true(r.ok)
    assert.equals('{"message": "hi"}', r.body)
    assert.equals("application/json", r.content_type)
    assert.equals("0", r.metadata.exit_code)
  end)

  it("maps grpcurl Code/Message errors onto gRPC statuses", function()
    local r = grpc.build_response({
      url = "localhost:50051/pkg.EchoService/Echo",
    }, {}, { "ERROR:", "  Code: NotFound", '  Message: account "42" not found' }, 1, nil)
    assert.equals("grpc", r.protocol)
    assert.equals(5, r.status)
    assert.is_false(r.ok)
    assert.matches("NotFound", r.status_text)
    assert.matches('account "42" not found', r.status_text)
  end)

  it("falls back to a transport-error response without a Code line", function()
    local r = grpc.build_response({
      url = "localhost:50051/pkg.EchoService/Echo",
    }, {}, { "grpcurl: connection refused" }, 7, nil)
    assert.equals("error", r.protocol)
    assert.equals(0, r.status)
    assert.is_false(r.ok)
    assert.matches("connection refused", r.body)
    assert.matches("exit 7", r.status_text)
  end)
end)

describe("grpc.run", function()
  local orig_jobstart, orig_chansend, orig_chanclose, orig_executable
  local captured_opts, sent, closed

  before_each(function()
    orig_jobstart, orig_chansend, orig_chanclose, orig_executable =
      vim.fn.jobstart, vim.fn.chansend, vim.fn.chanclose, vim.fn.executable
    captured_opts, sent, closed = nil, nil, nil
    vim.fn.executable = function(cmd) return cmd == "grpcurl" and 1 or 0 end
    vim.fn.jobstart = function(_, opts)
      captured_opts = opts
      return 4242
    end
    vim.fn.chansend = function(_, data) sent = data return #data end
    vim.fn.chanclose = function(_, stdin) closed = stdin end
  end)

  after_each(function()
    vim.fn.jobstart, vim.fn.chansend, vim.fn.chanclose, vim.fn.executable =
      orig_jobstart, orig_chansend, orig_chanclose, orig_executable
  end)

  it("reports a canonical error when grpcurl is missing", function()
    vim.fn.executable = function() return 0 end
    local response
    grpc.run({ url = "localhost:50051/x/Y", headers = {}, body = "" }, function(r) response = r end)
    assert.is_false(response.ok)
    assert.matches("grpcurl", response.body)
  end)

  it("streams the message body over stdin and closes it", function()
    grpc.run({
      url = "localhost:50051/pkg.EchoService/Echo",
      headers = {}, body = '{"message": "hi"}', timeout = 30000,
    }, function() end)
    assert.equals('{"message": "hi"}', sent)
    assert.equals("stdin", closed)
  end)

  it("delivers the canonical response through the callback", function()
    local response
    grpc.run({
      url = "localhost:50051/pkg.EchoService/Echo",
      headers = {}, body = "", timeout = 30000,
    }, function(r) response = r end)

    captured_opts.on_stdout(4242, { '{"ok": true}' }, nil)
    captured_opts.on_stderr(4242, {}, nil)
    captured_opts.on_exit(4242, 0)
    vim.wait(200, function() return response ~= nil end)

    assert.is_not_nil(response)
    assert.is_true(response.ok)
    assert.equals("grpc", response.protocol)
    assert.equals('{"ok": true}', response.body)
  end)

  it("reports a failure when the job cannot start", function()
    vim.fn.jobstart = function() return -1 end
    local response
    grpc.run({ url = "localhost:50051/x/Y", headers = {}, body = "" }, function(r) response = r end)
    assert.is_false(response.ok)
    assert.matches("Failed to start grpcurl", response.body)
  end)
end)
