-- Tests for gRPC proto/reflection completion support:
--   grpc_proto module (parse, argv, block info, index cache, completion items)
--   plus the grpc_method_path / grpc_proto_path completion contexts.

local grpc_proto = require("poste-http.http.grpc_proto")
local context_detector = require("poste-http.http.context_detector")
local item_builder = require("poste-http.http.item_builder")

local function block_buf(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

local function delete_buf(buf)
  vim.api.nvim_buf_delete(buf, { force = true })
end

describe("grpc_proto.parse_list_output", function()
  it("extracts fully-qualified service names, skipping blank lines", function()
    local services = grpc_proto.parse_list_output(
      "grpc.examples.echo.EchoService\n\nother.pkg.Calc\n")
    assert.equals(2, #services)
    assert.equals("grpc.examples.echo.EchoService", services[1])
    assert.equals("other.pkg.Calc", services[2])
  end)

  it("returns an empty list for empty or error output", function()
    assert.equals(0, #grpc_proto.parse_list_output(""))
    assert.equals(0, #grpc_proto.parse_list_output("Failed to dial\n"))
  end)
end)

describe("grpc_proto.parse_describe_output", function()
  it("extracts rpc method names and request types", function()
    local text = table.concat({
      "grpc.examples.echo.EchoService is a service:",
      "service EchoService {",
      "  rpc Echo ( .grpc.examples.echo.EchoRequest ) returns ( .grpc.examples.echo.EchoResponse );",
      "  rpc EchoStream ( stream .grpc.examples.echo.EchoRequest ) returns ( stream .grpc.examples.echo.EchoResponse );",
      "}",
    }, "\n")
    local methods = grpc_proto.parse_describe_output(text)
    assert.equals(2, #methods)
    assert.equals("Echo", methods[1].name)
    assert.equals("grpc.examples.echo.EchoRequest", methods[1].request_type)
    assert.equals("EchoStream", methods[2].name)
    assert.is_false(methods[1].client_stream)
    assert.is_true(methods[2].client_stream)
  end)

  it("returns an empty list when the describe output has no rpc lines", function()
    assert.equals(0, #grpc_proto.parse_describe_output("some error text\n"))
  end)
end)

describe("grpc_proto.build_list_args / build_describe_args", function()
  it("builds offline list args from proto operators", function()
    local args = grpc_proto.build_list_args({
      plaintext = true,
      import_paths = { "./protos" },
      protos = { "echo.proto" },
      proto_sets = { "bundle.bin" },
    })
    assert.same({ "grpcurl", "-plaintext", "-import-path", "./protos",
      "-proto", "echo.proto", "-proto-set", "bundle.bin", "list" }, args)
  end)

  it("builds reflection list args from the host", function()
    local args = grpc_proto.build_list_args({ host = "localhost:50051" })
    assert.same({ "grpcurl", "localhost:50051", "list" }, args)
  end)

  it("builds offline describe args for a service", function()
    local args = grpc_proto.build_describe_args({
      import_paths = { "./protos" },
      protos = { "echo.proto" },
    }, "pkg.EchoService")
    assert.same({ "grpcurl", "-import-path", "./protos", "-proto", "echo.proto",
      "describe", "pkg.EchoService" }, args)
  end)

  it("builds reflection describe args for a service", function()
    local args = grpc_proto.build_describe_args({ host = "h:1" }, "pkg.Svc")
    assert.same({ "grpcurl", "h:1", "describe", "pkg.Svc" }, args)
  end)
end)

describe("grpc_proto.get_block_info", function()
  it("collects the host and grpc operators from the current block", function()
    local buf = block_buf({
      "### echo",
      "# @grpc-plaintext",
      "# @grpc-import-path ./protos",
      "# @grpc-proto echo.proto",
      "GRPC localhost:50051/grpc.examples.echo.EchoService/Echo",
      "",
      '{"message": "hi"}',
    })
    local info = grpc_proto.get_block_info(buf, 5)
    delete_buf(buf)
    assert.equals("localhost:50051", info.host)
    assert.same({ "echo.proto" }, info.protos)
    assert.same({ "./protos" }, info.import_paths)
    assert.same({}, info.proto_sets)
    assert.is_true(info.plaintext)
    assert.is_false(info.tls)
  end)

  it("returns nil outside a request block", function()
    local buf = block_buf({ "nothing here" })
    local info = grpc_proto.get_block_info(buf, 1)
    delete_buf(buf)
    assert.is_nil(info)
  end)
end)

describe("grpc_proto.index_key", function()
  it("changes when proto file mtimes change", function()
    local stat = function(path)
      if path == "echo.proto" then return { stat = { mtime = { sec = 100, nsec = 0 } } } end
      return nil
    end
    local old_stat = grpc_proto.fs_stat
    grpc_proto.fs_stat = stat
    local info = { host = "h:1", import_paths = {}, protos = { "echo.proto" }, proto_sets = {} }
    local key1 = grpc_proto.index_key(info)
    grpc_proto.fs_stat = function(path)
      if path == "echo.proto" then return { stat = { mtime = { sec = 200, nsec = 0 } } } end
      return nil
    end
    local key2 = grpc_proto.index_key(info)
    grpc_proto.fs_stat = old_stat
    assert.not_equals(key1, key2)
  end)

  it("reads the FLAT uv.fs_stat shape (st.mtime, no .stat wrapper)", function()
    -- regression: real uv.fs_stat returns the stat table directly, so the
    -- old st.stat.mtime check never fired and mtimes were folded as
    -- "missing" — editing a proto file never invalidated the cache key
    local old_stat = grpc_proto.fs_stat
    grpc_proto.fs_stat = function(path)
      if path == "echo.proto" then return { mtime = { sec = 100, nsec = 0 } } end
      return nil
    end
    local info = { host = "h:1", import_paths = {}, protos = { "echo.proto" }, proto_sets = {} }
    local key1 = grpc_proto.index_key(info)
    grpc_proto.fs_stat = function(path)
      if path == "echo.proto" then return { mtime = { sec = 200, nsec = 0 } } end
      return nil
    end
    local key2 = grpc_proto.index_key(info)
    grpc_proto.fs_stat = old_stat
    assert.not_equals(key1, key2)
  end)

  it("folds a real file's mtime (not the missing sentinel)", function()
    local path = vim.fn.tempname() .. ".proto"
    vim.fn.writefile({ "syntax = \"proto3\";" }, path)
    local info = { host = "", import_paths = {}, protos = { path }, proto_sets = {} }
    local key = grpc_proto.index_key(info)
    vim.fn.delete(path)
    assert.matches("@%d+%.%d+", key)
  end)

  it("changes with host and operator values", function()
    local old_stat = grpc_proto.fs_stat
    grpc_proto.fs_stat = function() return nil end
    local key1 = grpc_proto.index_key({ host = "h:1", import_paths = {}, protos = { "a" }, proto_sets = {} })
    local key2 = grpc_proto.index_key({ host = "h:2", import_paths = {}, protos = { "a" }, proto_sets = {} })
    local key3 = grpc_proto.index_key({ host = "h:1", import_paths = {}, protos = { "b" }, proto_sets = {} })
    grpc_proto.fs_stat = old_stat
    assert.not_equals(key1, key2)
    assert.not_equals(key1, key3)
  end)
end)

describe("grpc_proto.get_method_items", function()
  after_each(function()
    grpc_proto._cache = {}
  end)

  it("offers services (with trailing /) when no service prefix typed yet", function()
    local buf = block_buf({ "### echo", "GRPC localhost:50051/" })
    grpc_proto._cache[buf] = {
      key = "k",
      index = { services = {
        ["pkg.EchoService"] = { methods = { { name = "Echo" } } },
        ["pkg.Calc"] = { methods = {} },
      } },
    }
    local old_key = grpc_proto.index_key
    grpc_proto.index_key = function() return "k" end
    local items = grpc_proto.get_method_items(buf, 2, { host = "localhost:50051", service_prefix = "", partial = "" })
    grpc_proto.index_key = old_key
    delete_buf(buf)
    assert.equals(2, #items)
    local by_label = {}
    for _, it in ipairs(items) do by_label[it.label] = it end
    assert.equals("pkg.EchoService/", by_label["pkg.EchoService"].insertText)
    assert.equals("pkg.Calc/", by_label["pkg.Calc"].insertText)
  end)

  it("offers methods of the typed service", function()
    local buf = block_buf({ "### echo", "GRPC localhost:50051/pkg.EchoService/E" })
    grpc_proto._cache[buf] = {
      key = "k",
      index = { services = {
        ["pkg.EchoService"] = { methods = { { name = "Echo", request_type = "pkg.EchoRequest" }, { name = "Ping" } } },
      } },
    }
    local old_key = grpc_proto.index_key
    grpc_proto.index_key = function() return "k" end
    local items = grpc_proto.get_method_items(buf, 2,
      { host = "localhost:50051", service_prefix = "pkg.EchoService", partial = "E" })
    grpc_proto.index_key = old_key
    delete_buf(buf)
    assert.equals(1, #items)
    assert.equals("Echo", items[1].label)
    assert.equals("pkg.EchoRequest", items[1].detail)
  end)

  it("returns no items when the index is not cached yet", function()
    local buf = block_buf({ "### echo", "GRPC localhost:50051/" })
    -- stub vim.fn so prewarm doesn't spawn a real grpcurl process
    local old_fn = grpc_proto.fn
    grpc_proto.fn = { executable = function() return 0 end }
    local items = grpc_proto.get_method_items(buf, 2, { host = "localhost:50051", service_prefix = "", partial = "" })
    grpc_proto.fn = old_fn
    delete_buf(buf)
    assert.equals(0, #items)
  end)
end)

describe("grpc_proto.get_proto_path_items", function()
  local tmp
  before_each(function()
    tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp .. "/protos/sub", "p")
    vim.fn.writefile({ "syntax" }, tmp .. "/protos/echo.proto")
    vim.fn.writefile({ "not a proto" }, tmp .. "/protos/notes.txt")
    vim.fn.writefile({ "syntax" }, tmp .. "/protos/sub/inner.proto")
  end)
  after_each(function()
    vim.fn.delete(tmp, "rf")
  end)

  it("lists proto files and directories under the partial path", function()
    local items = grpc_proto.get_proto_path_items(tmp .. "/protos/")
    local labels = {}
    for _, it in ipairs(items) do labels[it.label] = it.kind end
    assert.equals(17, labels["echo.proto"])
    assert.equals(19, labels["sub/"])
    assert.is_nil(labels["notes.txt"])
    assert.is_nil(labels["inner.proto"])
  end)

  it("filters by the trailing partial name", function()
    local items = grpc_proto.get_proto_path_items(tmp .. "/protos/ec")
    assert.equals(1, #items)
    assert.equals("echo.proto", items[1].label)
    assert.equals("echo.proto", items[1].insertText)
  end)

  it("completes into directories for nested paths", function()
    local items = grpc_proto.get_proto_path_items(tmp .. "/protos/sub/")
    assert.equals(1, #items)
    assert.equals("inner.proto", items[1].label)
  end)
end)

describe("grpc completion contexts", function()
  it("detects grpc_method_path on the request line after the host slash", function()
    local buf = block_buf({ "### echo", "GRPC localhost:50051/" })
    local ctx, extra = context_detector.detect_context("GRPC localhost:50051/", buf, 2, 21)
    delete_buf(buf)
    assert.equals("grpc_method_path", ctx)
    assert.equals("localhost:50051", extra.host)
    assert.equals("", extra.service_prefix)
    assert.equals("", extra.partial)
  end)

  it("detects the service prefix once a second slash is typed", function()
    local buf = block_buf({ "### echo", "GRPC h:1/pkg.EchoService/Ec" })
    local ctx, extra = context_detector.detect_context("GRPC h:1/pkg.EchoService/Ec", buf, 2, 26)
    delete_buf(buf)
    assert.equals("grpc_method_path", ctx)
    assert.equals("pkg.EchoService", extra.service_prefix)
    assert.equals("Ec", extra.partial)
  end)

  it("offers services while typing the fully-qualified service name", function()
    local buf = block_buf({ "### echo", "GRPC h:1/pkg.Ech" })
    local ctx, extra = context_detector.detect_context("GRPC h:1/pkg.Ech", buf, 2, 16)
    delete_buf(buf)
    assert.equals("grpc_method_path", ctx)
    assert.equals("", extra.service_prefix)
    assert.equals("pkg.Ech", extra.partial)
  end)

  it("detects nothing while typing the host (no slash yet)", function()
    local buf = block_buf({ "### echo", "GRPC localhost" })
    local ctx = context_detector.detect_context("GRPC localhost", buf, 2, 14)
    delete_buf(buf)
    assert.is_nil(ctx)
  end)

  it("detects grpc_proto_path on @grpc-proto comment operators", function()
    local buf = block_buf({ "### echo", "# @grpc-proto ./protos/ec" })
    local ctx, extra = context_detector.detect_context("# @grpc-proto ./protos/ec", buf, 2, 25)
    delete_buf(buf)
    assert.equals("grpc_proto_path", ctx)
    assert.equals("./protos/ec", extra)
  end)

  it("detects grpc_proto_path on @grpc-proto-set too", function()
    local buf = block_buf({ "### echo", "# @grpc-proto-set bundle.bin" })
    local ctx, extra = context_detector.detect_context("# @grpc-proto-set bundle.bin", buf, 2, 28)
    delete_buf(buf)
    assert.equals("grpc_proto_path", ctx)
    assert.equals("bundle.bin", extra)
  end)

  it("leaves regular comments alone", function()
    local buf = block_buf({ "### echo", "# just a comment" })
    local ctx = context_detector.detect_context("# just a comment", buf, 2, 16)
    delete_buf(buf)
    assert.is_nil(ctx)
  end)
end)

describe("item_builder grpc wiring", function()
  after_each(function()
    grpc_proto._cache = {}
  end)

  it("serves grpc_method_path items through get_items_for_context", function()
    local buf = block_buf({ "### echo", "GRPC localhost:50051/pkg.EchoService/" })
    grpc_proto._cache[buf] = {
      key = "k",
      index = { services = {
        ["pkg.EchoService"] = { methods = { { name = "Echo", request_type = "pkg.EchoRequest" } } },
      } },
    }
    local old_key = grpc_proto.index_key
    grpc_proto.index_key = function() return "k" end
    local items = item_builder.get_items_for_context("GRPC localhost:50051/pkg.EchoService/", buf, 2, 36)
    grpc_proto.index_key = old_key
    delete_buf(buf)
    assert.equals(1, #items)
    assert.equals("Echo", items[1].label)
  end)
end)

describe("grpc_proto.parse_type_describe", function()
  it("parses message fields: scalars, fully-qualified types, repeated, map", function()
    local text = table.concat({
      "demo.v1.CreateUserRequest is a message:",
      "message CreateUserRequest {",
      "  string name = 1;",
      "  int32 age = 2;",
      "  .demo.v1.Address address = 3;",
      "  .demo.v1.Status status = 4;",
      "  map<string, int64> scores = 5;",
      "  repeated .demo.v1.Address alt_addresses = 6;",
      "}",
    }, "\n")
    local desc = grpc_proto.parse_type_describe(text)
    assert.equals("message", desc.kind)
    local by_name = {}
    for _, f in ipairs(desc.fields) do by_name[f.name] = f end
    assert.equals("string", by_name.name.type)
    assert.equals("demo.v1.Address", by_name.address.type)
    assert.equals("demo.v1.Status", by_name.status.type)
    assert.equals("int64", by_name.scores.type)
    assert.is_true(by_name.scores.is_map)
    assert.is_true(by_name.alt_addresses.repeated)
    assert.equals("demo.v1.Address", by_name.alt_addresses.type)
    assert.is_nil(by_name.name.repeated)
  end)

  it("collects oneof members as ordinary fields", function()
    local text = table.concat({
      "demo.v1.X is a message:",
      "message X {",
      "  oneof contact {",
      "    string email = 8;",
      "    string phone = 9;",
      "  }",
      "}",
    }, "\n")
    local desc = grpc_proto.parse_type_describe(text)
    assert.equals(2, #desc.fields)
    assert.equals("email", desc.fields[1].name)
  end)

  it("skips nested message definitions without stealing their fields", function()
    local text = table.concat({
      "demo.v1.Profile is a message:",
      "message Profile {",
      "  .demo.v1.Profile.Nickname nickname = 1;",
      "  repeated string tags = 2;",
      "  message Nickname {",
      "    string value = 1;",
      "  }",
      "}",
    }, "\n")
    local desc = grpc_proto.parse_type_describe(text)
    assert.equals(2, #desc.fields)
    local by_name = {}
    for _, f in ipairs(desc.fields) do by_name[f.name] = f end
    assert.equals("demo.v1.Profile.Nickname", by_name.nickname.type)
    assert.is_nil(by_name.value)
  end)

  it("parses enum values", function()
    local text = table.concat({
      "demo.v1.Status is an enum:",
      "enum Status {",
      "  STATUS_UNSPECIFIED = 0;",
      "  STATUS_ACTIVE = 1;",
      "  STATUS_BLOCKED = 2;",
      "}",
    }, "\n")
    local desc = grpc_proto.parse_type_describe(text)
    assert.equals("enum", desc.kind)
    assert.same({ "STATUS_UNSPECIFIED", "STATUS_ACTIVE", "STATUS_BLOCKED" }, desc.values)
  end)

  it("returns kind unknown for non-type output", function()
    assert.equals("unknown", grpc_proto.parse_type_describe("connection refused\n").kind)
    assert.equals("unknown", grpc_proto.parse_type_describe("").kind)
  end)
end)

describe("grpc_proto.body_context", function()
  it("is empty at the opening brace", function()
    local bc = grpc_proto.body_context("{")
    assert.equals(0, #bc.path)
    assert.equals("key", bc.position)
    assert.equals("", bc.partial)
  end)

  it("collects the partial key at the top level", function()
    local bc = grpc_proto.body_context('{"nam')
    assert.equals(0, #bc.path)
    assert.equals("key", bc.position)
    assert.equals("nam", bc.partial)
  end)

  it("enters nested objects and keeps the key path", function()
    local bc = grpc_proto.body_context('{"user": {"address": {"ci')
    assert.same({ "user", "address" }, bc.path)
    assert.equals("key", bc.position)
    assert.equals("ci", bc.partial)
  end)

  it("reports value position with the pending key after a colon", function()
    local bc = grpc_proto.body_context('{"status": "STATUS_A')
    assert.same({ "status" }, bc.path)
    assert.equals("value", bc.position)
    assert.equals("STATUS_A", bc.partial)
  end)

  it("returns to key position after a comma", function()
    local bc = grpc_proto.body_context('{"name": "lex", "a')
    assert.equals(0, #bc.path)
    assert.equals("key", bc.position)
    assert.equals("a", bc.partial)
  end)

  it("skips {{var}} placeholders atomically (no brace-depth confusion)", function()
    local bc = grpc_proto.body_context('{"msg": {{name}}, "ot')
    assert.equals(0, #bc.path)
    assert.equals("key", bc.position)
    assert.equals("ot", bc.partial)
  end)

  it("keeps the path through array elements", function()
    local bc = grpc_proto.body_context('{"tags": [{"tit')
    assert.same({ "tags" }, bc.path)
    assert.equals("key", bc.position)
    assert.equals("tit", bc.partial)
  end)

  it("pops out of nested objects", function()
    local bc = grpc_proto.body_context('{"user": {"n": 1}, "ot')
    assert.equals(0, #bc.path)
    assert.equals("key", bc.position)
    assert.equals("ot", bc.partial)
  end)

  it("handles bare (unquoted) enum values", function()
    local bc = grpc_proto.body_context('{"status": STATUS_A')
    assert.same({ "status" }, bc.path)
    assert.equals("value", bc.position)
    assert.equals("STATUS_A", bc.partial)
  end)

  it("closes strings with escapes", function()
    local bc = grpc_proto.body_context('{"quote": "a\\"b", "nex')
    assert.equals(0, #bc.path)
    assert.equals("key", bc.position)
    assert.equals("nex", bc.partial)
  end)
end)

describe("grpc_proto.get_body_items", function()
  after_each(function()
    grpc_proto._cache = {}
  end)

  local function shaped_buf(line)
    local lines = {
      "### shaped",
      "# @grpc-plaintext",
      "GRPC localhost:8891/demo.v1.UserService/CreateUser",
      "",
      '{"name": "lex", "addr',
    }
    return block_buf(lines), line or 5
  end

  local function stub_index(buf)
    grpc_proto._cache[buf] = {
      key = "k",
      index = {
        services = {
          ["demo.v1.UserService"] = {
            methods = { { name = "CreateUser", request_type = "demo.v1.CreateUserRequest" } },
          },
        },
        messages = {
          ["demo.v1.CreateUserRequest"] = {
            kind = "message",
            fields = {
              { name = "name", type = "string" },
              { name = "address", type = "demo.v1.Address" },
              { name = "status", type = "demo.v1.Status" },
            },
          },
          ["demo.v1.Address"] = {
            kind = "message",
            fields = {
              { name = "street", type = "string" },
              { name = "city", type = "string" },
            },
          },
        },
        enums = {
          ["demo.v1.Status"] = { kind = "enum", values = { "STATUS_ACTIVE", "STATUS_BLOCKED" } },
        },
        pending_messages = {},
      },
    }
  end

  it("completes top-level fields at a key position", function()
    local buf = block_buf({
      "### shaped",
      "# @grpc-plaintext",
      "GRPC localhost:8891/demo.v1.UserService/CreateUser",
      "",
      '{"',
    })
    stub_index(buf)
    local old_key = grpc_proto.index_key
    grpc_proto.index_key = function() return "k" end
    local items = grpc_proto.get_body_items(buf, 5, 2)
    grpc_proto.index_key = old_key
    delete_buf(buf)
    local names = {}
    for _, it in ipairs(items) do table.insert(names, it.label) end
    assert.same({ "name", "address", "status" }, names)
  end)

  it("filters fields by the typed partial", function()
    local buf, line = shaped_buf()
    stub_index(buf)
    local old_key = grpc_proto.index_key
    grpc_proto.index_key = function() return "k" end
    local items = grpc_proto.get_body_items(buf, line, #'{"name": "lex", "addr')
    grpc_proto.index_key = old_key
    delete_buf(buf)
    assert.equals(1, #items)
    assert.equals("address", items[1].label)
    assert.equals("demo.v1.Address", items[1].detail)
  end)

  it("resolves the nested message under a completed key", function()
    local buf = block_buf({
      "### shaped",
      "# @grpc-plaintext",
      "GRPC localhost:8891/demo.v1.UserService/CreateUser",
      "",
      '{"address": {"ci',
    })
    stub_index(buf)
    local old_key = grpc_proto.index_key
    grpc_proto.index_key = function() return "k" end
    local items = grpc_proto.get_body_items(buf, 5, 15)
    grpc_proto.index_key = old_key
    delete_buf(buf)
    assert.equals(1, #items)
    assert.equals("city", items[1].label)
    assert.equals("string", items[1].detail)
  end)

  it("offers enum values in a value position", function()
    local buf = block_buf({
      "### shaped",
      "# @grpc-plaintext",
      "GRPC localhost:8891/demo.v1.UserService/CreateUser",
      "",
      '{"status": "STATUS_A',
    })
    stub_index(buf)
    local old_key = grpc_proto.index_key
    grpc_proto.index_key = function() return "k" end
    local items = grpc_proto.get_body_items(buf, 5, #'{"status": "STATUS_A')
    grpc_proto.index_key = old_key
    delete_buf(buf)
    assert.equals(1, #items)
    assert.equals("STATUS_ACTIVE", items[1].label)
  end)

  it("returns no items when the index is not cached yet (prewarm kicks in)", function()
    local buf, line = shaped_buf()
    local old_fn = grpc_proto.fn
    grpc_proto.fn = { executable = function() return 0 end }
    local items = grpc_proto.get_body_items(buf, line, #'{"name": "lex", "addr')
    grpc_proto.fn = old_fn
    delete_buf(buf)
    assert.equals(0, #items)
  end)

  it("spawns a describe job for a missing nested message and returns empty", function()
    local buf = block_buf({
      "### shaped",
      "# @grpc-plaintext",
      "GRPC localhost:8891/demo.v1.UserService/CreateUser",
      "",
      '{"address": {"ci',
    })
    -- index without the nested Address message: the walk hits it and must
    -- request a background describe instead of guessing fields
    grpc_proto._cache[buf] = {
      key = "k",
      index = {
        services = {
          ["demo.v1.UserService"] = {
            methods = { { name = "CreateUser", request_type = "demo.v1.CreateUserRequest" } },
          },
        },
        messages = {
          ["demo.v1.CreateUserRequest"] = {
            kind = "message",
            fields = { { name = "address", type = "demo.v1.Address" } },
          },
        },
        enums = {},
        pending_messages = {},
      },
    }
    local calls = {}
    local old_fn = grpc_proto.fn
    grpc_proto.fn = {
      executable = function() return 1 end,
      jobstart = function(argv)
        table.insert(calls, argv)
        return -1 -- pretend spawn failed; we only assert the argv
      end,
    }
    local old_key = grpc_proto.index_key
    grpc_proto.index_key = function() return "k" end
    local items = grpc_proto.get_body_items(buf, 5, 15)
    grpc_proto.index_key = old_key
    grpc_proto.fn = old_fn
    delete_buf(buf)
    assert.equals(0, #items)
    assert.equals(1, #calls)
    local argv = calls[1]
    assert.equals("describe", argv[#argv - 1])
    assert.equals("demo.v1.Address", argv[#argv])
  end)

  it("returns no items outside a GRPC block or without a method path", function()
    local buf = block_buf({
      "### http",
      "GET http://example.com",
      "",
      '{"address": {"ci',
    })
    assert.equals(0, #grpc_proto.get_body_items(buf, 4, 1))
    delete_buf(buf)
  end)
end)

describe("grpc completion grpc_body context", function()
  it("detects the body of a GRPC block with a method path", function()
    local buf = block_buf({
      "### shaped",
      "# @grpc-plaintext",
      "GRPC localhost:8891/demo.v1.UserService/CreateUser",
      "",
      '{"name": "lex", "addr',
    })
    local ctx, extra = context_detector.detect_context('{"name": "lex", "addr', buf, 5, 21)
    delete_buf(buf)
    assert.equals("grpc_body", ctx)
    assert.is_nil(extra)
  end)

  it("does not fire for HTTP blocks", function()
    local buf = block_buf({
      "### http",
      "POST http://example.com",
      "Content-Type: application/json",
      "",
      '{"name": "lex", "addr',
    })
    local ctx = context_detector.detect_context('{"name": "lex", "addr', buf, 5, 21)
    delete_buf(buf)
    assert.is_nil(ctx)
  end)

  it("does not fire on the GRPC request line", function()
    local buf = block_buf({
      "### shaped",
      "GRPC localhost:8891/demo.v1.UserService/CreateUser",
    })
    local ctx = context_detector.detect_context("GRPC localhost:8891/demo.v1.UserService/CreateUser", buf, 2, 50)
    delete_buf(buf)
    assert.not_equals("grpc_body", ctx)
  end)

  it("keeps {{ variable completion working in a GRPC body", function()
    local buf = block_buf({
      "### shaped",
      "# @grpc-plaintext",
      "GRPC localhost:8891/demo.v1.UserService/CreateUser",
      "",
      '{"msg": "{{va',
    })
    local ctx, extra = context_detector.detect_context('{"msg": "{{va', buf, 5, 13)
    delete_buf(buf)
    assert.equals("variable", ctx)
    assert.equals("va", extra)
  end)
end)
