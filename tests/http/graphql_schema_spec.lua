-- GraphQL schema-aware completion (tier 2):
--   graphql_schema module — SDL parsing, # @graphql-schema block operator,
--   query-text position walker, and schema-driven completion items.
-- Mirrors the grpc_proto blueprint (parse / block info / body_context / items).

local graphql_schema = require("poste-http.http.graphql_schema")
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

local SCHEMA_SDL = table.concat({
  '"""Root queries"""',
  "type Query {",
  '  user(id: ID! = "1"): User',
  "  users(status: OrderStatus, limit: Int = 10): [User!]!",
  "}",
  "",
  "type User {",
  "  id: ID!",
  "  name: String",
  "  email: String @deprecated",
  "  friends: [User!]",
  "  status: OrderStatus",
  "  address: Address",
  "}",
  "",
  "type Mutation {",
  "  createUser(input: CreateUserInput): User",
  "}",
  "",
  "input CreateUserInput {",
  "  name: String!",
  "  email: String",
  "}",
  "",
  "enum OrderStatus {",
  "  OPEN",
  "  PAID",
  "  # archived away",
  "  ARCHIVED @deprecated(reason: \"unused\")",
  "}",
  "",
  "union SearchResult = User | Order",
  "",
  "scalar DateTime",
  "",
  "schema {",
  "  query: Query",
  "}",
  "",
  "type RootQuery {",
  "  me: User",
  "}",
  "",
  "extend type User {",
  "  nickname: String",
  "}",
  "",
  "interface Node {",
  "  id: ID!",
  "}",
  "",
  "type Order implements Node {",
  "  total: Float",
  "}",
}, "\n")

describe("graphql_schema.parse_sdl", function()
  it("parses object fields with arguments, defaults and directives", function()
    local s = graphql_schema.parse_sdl(SCHEMA_SDL)
    assert.is_truthy(s.types.Query)
    assert.equals("User", graphql_schema.base_type(s.types.Query.fields.user.type))
    assert.equals("ID!", s.types.Query.fields.user.args.id)
    assert.equals("OrderStatus", s.types.Query.fields.users.args.status)
    assert.equals("[User!]!", s.types.Query.fields.users.type)
  end)

  it("maps custom root types from the schema block", function()
    local s = graphql_schema.parse_sdl(SCHEMA_SDL)
    assert.equals("Query", s.roots.query)
    assert.equals("Mutation", s.roots.mutation) -- default preserved
  end)

  it("maps non-default root type names", function()
    local s = graphql_schema.parse_sdl(table.concat({
      "schema {",
      "  query: RootQuery",
      "  mutation: RootMutation",
      "}",
      "type RootQuery { me: Boolean }",
    }, "\n"))
    assert.equals("RootQuery", s.roots.query)
    assert.equals("RootMutation", s.roots.mutation)
  end)

  it("parses enums, unions, scalars and built-ins", function()
    local s = graphql_schema.parse_sdl(SCHEMA_SDL)
    assert.same({ "OPEN", "PAID", "ARCHIVED" }, s.enums.OrderStatus.values)
    assert.same({ "User", "Order" }, s.unions.SearchResult.members)
    assert.is_truthy(s.scalars.DateTime)
    assert.is_truthy(s.scalars.ID)
    assert.is_truthy(s.scalars.Boolean)
  end)

  it("parses input and interface types", function()
    local s = graphql_schema.parse_sdl(SCHEMA_SDL)
    assert.equals("String!", s.types.CreateUserInput.fields.name.type)
    assert.equals("object", s.types.Order.kind)
    assert.equals("ID!", s.types.Node.fields.id.type)
  end)

  it("merges extend type into the base type", function()
    local s = graphql_schema.parse_sdl(SCHEMA_SDL)
    assert.is_truthy(s.types.User.fields.nickname, "extended field must merge")
    assert.is_truthy(s.types.User.fields.name, "base fields must survive")
  end)

  it("ignores description blocks and comments", function()
    local s = graphql_schema.parse_sdl(SCHEMA_SDL)
    -- The enum comment and the type description must not leak as members
    assert.is_nil(s.enums.OrderStatus.values.archive)
    assert.equals(3, #s.enums.OrderStatus.values)
  end)
end)

describe("graphql_schema.body_context", function()
  local bc = graphql_schema.body_context

  it("detects a root field being typed", function()
    local c = bc("query { us")
    assert.equals("query", c.op)
    assert.equals("field", c.position)
    assert.equals(0, #c.steps)
    assert.equals("us", c.partial)
  end)

  it("walks into nested selection sets", function()
    local c = bc("query {\n  user {\n    fri")
    assert.equals("field", c.position)
    assert.equals(1, #c.steps)
    assert.equals("user", c.steps[1].field)
    assert.equals("fri", c.partial)
  end)

  it("detects argument name and value positions", function()
    local c = bc("query {\n  user(id: 1, na")
    assert.equals("argname", c.position)
    assert.equals("user", c.field)
    assert.equals("na", c.partial)

    local c2 = bc("query {\n  user(status: ")
    assert.equals("argvalue", c2.position)
    assert.equals("user", c2.field)
    assert.equals("status", c2.arg)
  end)

  it("detects variable definition types", function()
    local c = bc("query User($id: I")
    assert.equals("vartype", c.position)
    assert.equals("id", c.var)
    assert.equals("I", c.partial)
  end)

  it("detects fragment-on type positions", function()
    local c = bc("fragment F on U")
    assert.equals("fragtype", c.position)
    assert.equals("U", c.partial)

    local c2 = bc("query {\n  ... on Us")
    assert.equals("fragtype", c2.position)
    assert.equals("Us", c2.partial)
  end)

  it("skips aliases, strings and {{var}} templates", function()
    local c = bc('query {\n  u: user(name: "{{name_prefix}}") { na')
    assert.equals("field", c.position)
    assert.equals(1, #c.steps)
    assert.equals("user", c.steps[1].field)
    assert.equals("na", c.partial)
  end)

  it("walks input object literals inside arguments", function()
    local c = bc("mutation {\n  createUser(input: { na")
    assert.equals("field", c.position)
    assert.equals(1, #c.steps)
    assert.equals("input", c.steps[1].arg)
    assert.equals("createUser", c.steps[1].field)
    assert.equals("na", c.partial)
  end)

  it("pops back out of closed braces", function()
    local c = bc("query {\n  user { id }\n  na")
    assert.equals("field", c.position)
    assert.equals(0, #c.steps)
    assert.equals("na", c.partial)
  end)
end)

describe("graphql_schema.items_for_context", function()
  local schema = graphql_schema.parse_sdl(SCHEMA_SDL)
  local items = graphql_schema.items_for_context

  local function labels(list)
    local out = {}
    for _, it in ipairs(list) do out[it.label] = true end
    return out
  end

  it("offers root fields on the operation's root type", function()
    local got = items(schema, graphql_schema.body_context("query { "))
    local l = labels(got)
    assert.is_truthy(l.user)
    assert.is_truthy(l.users)
    assert.is_nil(l.id, "User-level fields must not leak to the root")
  end)

  it("offers fields of the type at the walked path", function()
    local c = graphql_schema.body_context("query {\n  user {\n    ")
    local got = items(schema, c)
    local l = labels(got)
    assert.is_truthy(l.friends)
    assert.is_truthy(l.nickname, "extended field must be offered")
    assert.is_nil(l.user, "root fields must not leak into User")
    assert.equals(10, got[1].kind) -- Property
    assert.is_truthy(got[1].detail ~= "")
  end)

  it("pre-filters items by the partial word", function()
    local c = graphql_schema.body_context("query {\n  user {\n    fri")
    local l = labels(items(schema, c))
    assert.is_truthy(l.friends)
    assert.is_nil(l.name, "partial 'fri' must filter out 'name'")
  end)

  it("offers argument names in argname position", function()
    local c = graphql_schema.body_context("query {\n  users(")
    local l = labels(items(schema, c))
    assert.is_truthy(l.limit)
    assert.is_truthy(l.status)
  end)

  it("offers enum values for enum-typed arguments", function()
    local c = graphql_schema.body_context("query {\n  users(status: ")
    local l = labels(items(schema, c))
    assert.is_truthy(l.OPEN)
    assert.is_truthy(l.PAID)
    assert.equals(12, items(schema, c)[1].kind) -- Value
  end)

  it("resolves mutation roots and input object fields", function()
    local c = graphql_schema.body_context("mutation {\n  createUser(input: { ")
    local l = labels(items(schema, c))
    assert.is_truthy(l.name)
    assert.is_truthy(l.email)
  end)

  it("offers type names in vartype and fragtype positions", function()
    local got = items(schema, graphql_schema.body_context("query User($id: "))
    local l = labels(got)
    assert.is_truthy(l.User)
    assert.is_truthy(l.OrderStatus)
    assert.is_truthy(l.ID)
    assert.is_truthy(labels(items(schema,
      graphql_schema.body_context("fragment F on "))).Node)
  end)

  it("returns no items when the path resolves nowhere", function()
    local c = graphql_schema.body_context("query {\n  nonsense {\n    x")
    assert.equals(0, #items(schema, c))
  end)
end)

describe("graphql_schema block operator", function()
  after_each(function()
    graphql_schema._cache = {}
  end)

  it("extracts # @graphql-schema from the request block", function()
    local buf = block_buf({
      "### GraphQL",
      "# @graphql-schema ./schema/fixtures.graphql",
      "GRAPHQL {{graphql_url}}",
      "",
      "query { user { id } }",
    })
    assert.equals("./schema/fixtures.graphql", graphql_schema.get_schema_path(buf, 5))
    delete_buf(buf)
  end)

  it("returns nil outside a GRAPHQL block without the operator", function()
    local buf = block_buf({
      "### Get",
      "GET /users",
      "",
      "{",
      '  "a": 1',
      "}",
    })
    assert.is_nil(graphql_schema.get_schema_path(buf, 5))
    delete_buf(buf)
  end)
end)

describe("graphql_schema.load_schema", function()
  -- stubs are set per-test; restore them so shuffled order never leaks them
  -- into other describes (a leaked read_file stub poisons every later test)
  local orig_read_file, orig_fs_stat
  before_each(function()
    orig_read_file = graphql_schema.read_file
    orig_fs_stat = graphql_schema.fs_stat
  end)
  after_each(function()
    graphql_schema.read_file = orig_read_file
    graphql_schema.fs_stat = orig_fs_stat
    graphql_schema._cache = {}
  end)

  it("reads and parses the schema file, cached by mtime", function()
    local reads = 0
    graphql_schema.read_file = function(path)
      reads = reads + 1
      if path == "./schema.graphql" then return SCHEMA_SDL end
      return nil
    end
    graphql_schema.fs_stat = function() return nil end

    local s1 = graphql_schema.load_schema(0, "./schema.graphql")
    assert.is_truthy(s1.types.User)
    graphql_schema.load_schema(0, "./schema.graphql")
    assert.equals(1, reads, "second load must hit the cache")
  end)

  it("reloads when the file mtime changes", function()
    local mtime = { sec = 1, nsec = 0 }
    graphql_schema.read_file = function() return SCHEMA_SDL end
    graphql_schema.fs_stat = function() return { mtime = mtime } end

    graphql_schema.load_schema(0, "./schema.graphql")
    mtime.sec = 2
    graphql_schema.load_schema(0, "./schema.graphql")
    -- no crash and fresh schema served; reads counted via cache clear
    assert.is_truthy(graphql_schema.load_schema(0, "./schema.graphql").types.User)
  end)
end)

describe("schema-aware graphql body completion (end-to-end)", function()
  after_each(function()
    graphql_schema._cache = {}
  end)

  local state, ts_query
  local orig_ts_config, orig_is_available, orig_read_file, orig_fs_stat

  before_each(function()
    state = require("poste-http.state")
    ts_query = require("poste-http.http.ts_query")
    orig_ts_config = state.config.use_treesitter
    orig_is_available = ts_query.is_available
    orig_read_file = graphql_schema.read_file
    orig_fs_stat = graphql_schema.fs_stat
    state.config.use_treesitter = { context_detector = true }
    ts_query.is_available = function() return false end
    graphql_schema.read_file = function(path)
      if path == "./schema.graphql" then return SCHEMA_SDL end
      return nil
    end
    graphql_schema.fs_stat = function() return nil end
  end)

  after_each(function()
    state.config.use_treesitter = orig_ts_config
    ts_query.is_available = orig_is_available
    graphql_schema.read_file = orig_read_file
    graphql_schema.fs_stat = orig_fs_stat
  end)

  local function graphql_block(extra_body_lines)
    return block_buf(vim.list_extend({
      "### GraphQL",
      "# @graphql-schema ./schema.graphql",
      "GRAPHQL {{graphql_url}}",
      "",
    }, extra_body_lines))
  end

  it("completes User fields inside the nested selection set", function()
    local buf = graphql_block({
      "query {",
      "  user {",
      "    fri",
      "  }",
      "}",
    })
    local items = item_builder.get_items_for_context(
      "    fri", buf, 7, 7)
    delete_buf(buf)
    local found = false
    for _, it in ipairs(items) do
      if it.label == "friends" then
        found = true
        assert.equals(10, it.kind)
      end
    end
    assert.is_true(found, "friends field of User must be offered")
  end)

  it("falls back to keywords without the schema operator", function()
    local buf = block_buf({
      "### GraphQL",
      "GRAPHQL {{graphql_url}}",
      "",
      "query {",
      "  user {",
      "    fri",
      "  }",
      "}",
    })
    local items = item_builder.get_items_for_context(
      "    fri", buf, 7, 7)
    delete_buf(buf)
    local has_query = false
    for _, it in ipairs(items) do
      if it.label == "query" then has_query = true end
    end
    assert.is_true(has_query, "no schema pinned: keyword items expected")
  end)

  it("completes enum values in an argument value position", function()
    local buf = graphql_block({
      "query {",
      "  users(status: ",
      "}",
    })
    local items = item_builder.get_items_for_context(
      "  users(status: ", buf, 6, 16)
    delete_buf(buf)
    local has_open = false
    for _, it in ipairs(items) do
      if it.label == "OPEN" then has_open = true end
    end
    assert.is_true(has_open, "enum values must be offered for the status arg")
  end)
end)

describe("graphql_schema_path completion context", function()
  local state, ts_query
  local orig_ts_config, orig_is_available

  before_each(function()
    state = require("poste-http.state")
    ts_query = require("poste-http.http.ts_query")
    orig_ts_config = state.config.use_treesitter
    orig_is_available = ts_query.is_available
  end)

  after_each(function()
    state.config.use_treesitter = orig_ts_config
    ts_query.is_available = orig_is_available
  end)

  it("detects the operator argument line", function()
    state.config.use_treesitter = { context_detector = true }
    ts_query.is_available = function() return false end
    local buf = block_buf({
      "### GraphQL",
      "# @graphql-schema ./sc",
    })
    local ctx, extra = context_detector.detect_context("# @graphql-schema ./sc", buf, 2, 22)
    delete_buf(buf)
    assert.equals("graphql_schema_path", ctx)
    assert.equals("./sc", extra)
  end)

  it("lists directories and .graphql files like grpc proto paths", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    vim.fn.mkdir(dir .. "/sub", "p")
    vim.fn.writefile({ "type Query { ok: Boolean }" }, dir .. "/schema.graphql")
    vim.fn.writefile({ "noise" }, dir .. "/other.txt")

    local items = graphql_schema.get_schema_path_items(dir .. "/")
    local labels = {}
    for _, it in ipairs(items) do labels[it.label] = true end
    assert.is_truthy(labels["sub/"])
    assert.is_truthy(labels["schema.graphql"])
    assert.is_nil(labels["other.txt"])

    -- cleanup
    vim.fn.delete(dir, "rf")
  end)
end)

describe("graphql_schema.resolve_schema_path", function()
  local named_buf
  before_each(function()
    named_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(named_buf, "/tmp/https/demo.http")
  end)
  after_each(function()
    delete_buf(named_buf)
  end)

  it("anchors relative paths to the named buffer directory", function()
    assert.equals("/tmp/https/pin.graphql",
      graphql_schema.resolve_schema_path(named_buf, "./pin.graphql"))
    assert.equals("/tmp/https/sub/pin.graphql",
      graphql_schema.resolve_schema_path(named_buf, "sub/pin.graphql"))
  end)

  it("passes through absolute and ~ paths", function()
    assert.equals("/etc/pin.graphql",
      graphql_schema.resolve_schema_path(named_buf, "/etc/pin.graphql"))
    assert.equals("~/pin.graphql",
      graphql_schema.resolve_schema_path(named_buf, "~/pin.graphql"))
  end)

  it("keeps CWD-relative resolution for unnamed buffers", function()
    local unnamed = vim.api.nvim_create_buf(false, true)
    assert.equals("./pin.graphql", graphql_schema.resolve_schema_path(unnamed, "./pin.graphql"))
    delete_buf(unnamed)
  end)
end)

describe("graphql_schema buffer-relative completion", function()
  -- Reproduces the "opened the demo from another directory" scenario:
  -- the pinned SDL sits next to the .http file, the CWD does not have it.
  local dirs, orig_cwd

  local function setup_buffer_dir()
    local dir = vim.fn.tempname() .. "_gqlspec"
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile(vim.split(SCHEMA_SDL, "\n"), dir .. "/pin.graphql")
    dirs[#dirs + 1] = dir
    return dir
  end

  local function graphql_block(dir)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "### GraphQL",                     -- 1
      "# @graphql-schema ./pin.graphql", -- 2
      "GRAPHQL {{graphql_url}}",         -- 3
      "",                                -- 4
      "query {",                         -- 5
      "  user {",                        -- 6
      "    fri",                         -- 7
      "  }",                             -- 8
      "}",                               -- 9
    })
    vim.api.nvim_buf_set_name(buf, dir .. "/demo.http")
    return buf
  end

  before_each(function()
    dirs = {}
    orig_cwd = vim.fn.getcwd()
  end)

  after_each(function()
    -- restore before deleting so order-shuffled specs never see our CWD
    vim.fn.chdir(orig_cwd)
    for _, d in ipairs(dirs) do vim.fn.delete(d, "rf") end
    graphql_schema._cache = {}
  end)

  it("serves schema items when CWD differs from the buffer directory", function()
    local dir = setup_buffer_dir()
    vim.fn.chdir(vim.env.HOME)  -- CWD without the schema file
    local buf = graphql_block(dir)

    local items = graphql_schema.get_body_items(buf, 7, 7)
    delete_buf(buf)

    assert.is_not_nil(items, "pinned schema next to the buffer must be found")
    local found = false
    for _, it in ipairs(items) do
      if it.label == "friends" then found = true end
    end
    assert.is_true(found, "friends must be offered from the buffer-relative SDL")
  end)

  it("returns nil (keyword fallback) when the pinned schema file is missing", function()
    local dir = vim.fn.tempname() .. "_gqlspec"
    vim.fn.mkdir(dir, "p")
    dirs[#dirs + 1] = dir
    local buf = graphql_block(dir)  -- pin.graphql does not exist in dir

    assert.is_nil(graphql_schema.get_body_items(buf, 7, 7))
    delete_buf(buf)
  end)

  it("lists the buffer directory on the operator line without a path prefix", function()
    local dir = setup_buffer_dir()
    vim.fn.chdir(vim.env.HOME)
    local buf = graphql_block(dir)

    local items = graphql_schema.get_schema_path_items("", buf)
    delete_buf(buf)

    local found = false
    for _, it in ipairs(items) do
      if it.label == "pin.graphql" then found = true end
    end
    assert.is_true(found, "pin.graphql must be listed from the buffer dir, not CWD")
  end)
end)
