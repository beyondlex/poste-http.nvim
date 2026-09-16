-- Tests for history disk persistence (F21).
--
-- Covers: serialization round-trip (save → load), `_jq` transient state not
-- persisted, id counter restored from the loaded max id, cap enforcement on
-- load, and respect for the persist_history toggle.

local history = require("poste-http.http.history")
local state = require("poste-http.state")

local tmp_dir = "/private/tmp/poste-history-test"

local function reset()
  state.http_history = {}
  state.http_history_id_counter = 0
  state.config.persist_history = true
  state.config.history_file = tmp_dir .. "/history.json"
  os.remove(tmp_dir .. "/history.json")
end

describe("history persistence", function()
  before_each(reset)

  it("persists entries to disk on add and restores them via load", function()
    local resp = { status = 200, body = "{\"ok\":true}", headers = {}, metadata = { method = "GET" } }
    history.add_entry("GetUser", resp, nil, nil, "/tmp/user.http")

    state.http_history = {}
    state.http_history_id_counter = 0

    history.load()

    assert.equals(1, #state.http_history)
    assert.equals("GetUser", state.http_history[1].name)
    assert.equals(200, state.http_history[1].response.status)
    assert.equals("{\"ok\":true}", state.http_history[1].response.body)
    assert.equals("/tmp/user.http", state.http_history[1].source_file)
  end)

  it("restores the id counter to the max loaded id", function()
    history.add_entry("A", { status = 200, metadata = {} })
    history.add_entry("B", { status = 201, metadata = {} })

    state.http_history = {}
    state.http_history_id_counter = 0
    history.load()

    assert.equals(2, state.http_history_id_counter)
    history.add_entry("C", { status = 204, metadata = {} })
    assert.equals("C", state.http_history[1].name)
    assert.equals(3, state.http_history[1].id)
  end)

  it("keeps newest-first order after a load/add cycle", function()
    history.add_entry("Old", { status = 200, metadata = {} })
    history.add_entry("New", { status = 201, metadata = {} })

    state.http_history = {}
    history.load()
    assert.equals("New", state.http_history[1].name)
    assert.equals("Old", state.http_history[2].name)
  end)

  it("drops the transient _jq field when persisting", function()
    local entry_payload = { status = 200, body = "{}", metadata = {} }
    history.add_entry("JqEntry", entry_payload)
    state.http_history[1]._jq = { query = ".foo", original_lines = { "x", "y" } }
    local in_memory = state.http_history[1]

    -- The realistic leak: a LATER add re-persists the whole list, so the
    -- earlier entry's _jq (set after its own add) must be stripped then —
    -- not just absent because the file predates it.
    history.add_entry("Later", { status = 201, metadata = {} })

    state.http_history = {}
    history.load()

    assert.is_nil(state.http_history[1]._jq)
    assert.is_nil(state.http_history[2]._jq)
    assert.equals("{}", state.http_history[2].response.body)
    -- the live in-memory entry keeps its filter state
    assert.equals(".foo", in_memory._jq.query)
  end)

  it("respects persist_history=false (no file written)", function()
    state.config.persist_history = false
    history.add_entry("NoPersist", { status = 200, metadata = {} })

    assert.equals(0, vim.fn.filereadable(tmp_dir .. "/history.json"))
    assert.equals(1, #state.http_history)
  end)

  it("applies http_history_max cap after loading a larger file", function()
    for i = 1, 5 do
      history.add_entry("Req" .. i, { status = 200, metadata = {} })
    end

    state.http_history = {}
    state.config.http_history_max = 3
    history.load()

    assert.equals(3, #state.http_history)
    assert.equals("Req5", state.http_history[1].name)
    assert.equals("Req3", state.http_history[3].name)
  end)

  it("delete_entry persists the removal", function()
    history.add_entry("A", { status = 200, metadata = {} })
    history.add_entry("B", { status = 201, metadata = {} })

    state.http_history = {}
    history.load()
    assert.equals(2, #state.http_history)

    history.delete_entry(state.http_history[1].id)
    state.http_history = {}
    history.load()

    assert.equals(1, #state.http_history)
    assert.equals("A", state.http_history[1].name)
  end)

  it("load is a no-op when the file does not exist", function()
    state.http_history = {}
    state.http_history_id_counter = 0
    history.load()
    assert.equals(0, #state.http_history)
    assert.equals(0, state.http_history_id_counter)
  end)

  it("load tolerates corrupt JSON without crashing", function()
    local file = tmp_dir .. "/history.json"
    os.execute("mkdir -p " .. tmp_dir)
    local fd = io.open(file, "w")
    fd:write("{ not valid json !!!")
    fd:close()

    state.http_history = {}
    history.load()

    assert.equals(0, #state.http_history)
  end)
end)
