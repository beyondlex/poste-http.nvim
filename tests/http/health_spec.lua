local mock = require("helpers.mock_nvim")
local mock_health = {}

describe("poste-http healthcheck", function()
  local health

  before_each(function()
    mock_health = {
      _reports = {},
      _section = nil,
    }

    function mock_health.start(name)
      table.insert(mock_health._reports, { type = "start", name = name })
    end

    function mock_health.ok(msg)
      table.insert(mock_health._reports, { type = "ok", msg = msg })
    end

    function mock_health.warn(msg)
      table.insert(mock_health._reports, { type = "warn", msg = msg })
    end

    function mock_health.error(msg)
      table.insert(mock_health._reports, { type = "error", msg = msg })
    end

    vim.health = mock_health
    vim.treesitter = vim.treesitter or {}

    mock.setup({
      executable = function(name)
        if name == "curl" then return 1 end
        if name == "cc" then return 1 end
        return 0
      end,
    })

    vim.fn.filereadable = function(path)
      if path:match("parser%.c$") then return 1 end
      if path:match("%.so$") then return 1 end
      return 0
    end

    -- Default: .so is as fresh as the source (not stale).
    vim.fn.getftime = function() return 100 end

    vim.fn.isdirectory = function(path)
      if path:match("tree%-sitter%-poste") then return 1 end
      return 0
    end

    vim.fn.stdpath = function(name)
      return "/tmp/test/nvim-data"
    end

    vim.treesitter.get_parser = function(buf, lang)
      if lang == "poste_http" or lang == "poste_json" then
        return {}
      end
      error("parser not found: " .. lang)
    end

    package.loaded["poste-http.health"] = nil
    health = require("poste-http.health")
  end)

  after_each(function()
    mock.teardown()
    vim.health = nil
    vim.treesitter = nil
    package.loaded["poste-http.health"] = nil
  end)

  it("reports curl as ok when installed", function()
    health.check()
    local has_curl_ok = false
    for _, r in ipairs(mock_health._reports) do
      if r.type == "ok" and r.msg:match("curl") then
        has_curl_ok = true
      end
    end
    assert.is_true(has_curl_ok)
  end)

  it("reports curl error when not installed", function()
    vim.fn.executable = function(name)
      if name == "curl" then return 0 end
      return 1
    end
    package.loaded["poste-http.health"] = nil
    health = require("poste-http.health")
    health.check()
    local has_curl_err = false
    for _, r in ipairs(mock_health._reports) do
      if r.type == "error" and r.msg:match("curl") then
        has_curl_err = true
      end
    end
    assert.is_true(has_curl_err)
  end)

  it("reports C compiler ok when cc is installed", function()
    health.check()
    local has_cc_ok = false
    for _, r in ipairs(mock_health._reports) do
      if r.type == "ok" and r.msg:match("C compiler") then
        has_cc_ok = true
      end
    end
    assert.is_true(has_cc_ok)
  end)

  it("reports C compiler warn when not installed", function()
    vim.fn.executable = function(name)
      if name == "cc" then return 0 end
      if name == "gcc" then return 0 end
      return 1
    end
    package.loaded["poste-http.health"] = nil
    health = require("poste-http.health")
    health.check()
    local has_cc_warn = false
    for _, r in ipairs(mock_health._reports) do
      if r.type == "warn" and r.msg:match("C compiler") then
        has_cc_warn = true
      end
    end
    assert.is_true(has_cc_warn)
  end)

  it("reports poste_http grammar directory ok", function()
    health.check()
    local has_grammar_ok = false
    for _, r in ipairs(mock_health._reports) do
      if r.type == "ok" and r.msg:match("poste_http") and r.msg:match("grammar directory") then
        has_grammar_ok = true
      end
    end
    assert.is_true(has_grammar_ok)
  end)

  it("reports poste_http grammar directory error when missing", function()
    vim.fn.isdirectory = function(path)
      return 0
    end
    package.loaded["poste-http.health"] = nil
    health = require("poste-http.health")
    health.check()
    local has_grammar_err = false
    for _, r in ipairs(mock_health._reports) do
      if r.type == "error" and r.msg:match("poste_http") and r.msg:match("grammar directory") then
        has_grammar_err = true
      end
    end
    assert.is_true(has_grammar_err)
  end)

  it("reports poste_json grammar directory ok", function()
    health.check()
    local has_grammar_ok = false
    for _, r in ipairs(mock_health._reports) do
      if r.type == "ok" and r.msg:match("poste_json") and r.msg:match("grammar directory") then
        has_grammar_ok = true
      end
    end
    assert.is_true(has_grammar_ok)
  end)

  it("reports parser source found for both grammars", function()
    health.check()
    local http_src = false
    local json_src = false
    for _, r in ipairs(mock_health._reports) do
      if r.type == "ok" and r.msg:match("poste_http") and r.msg:match("source found") then
        http_src = true
      end
      if r.type == "ok" and r.msg:match("poste_json") and r.msg:match("source found") then
        json_src = true
      end
    end
    assert.is_true(http_src)
    assert.is_true(json_src)
  end)

  it("reports parser source error when missing", function()
    vim.fn.filereadable = function(path)
      if path:match("%.so$") then return 1 end
      return 0
    end
    package.loaded["poste-http.health"] = nil
    health = require("poste-http.health")
    health.check()
    local has_src_err = false
    for _, r in ipairs(mock_health._reports) do
      if r.type == "error" and r.msg:match("source not found") then
        has_src_err = true
      end
    end
    assert.is_true(has_src_err)
  end)

  it("reports parser compiled when .so exists", function()
    health.check()
    local has_compiled = false
    for _, r in ipairs(mock_health._reports) do
      if r.type == "ok" and r.msg:match("parser compiled") then
        has_compiled = true
      end
    end
    assert.is_true(has_compiled)
  end)

  it("reports parser not compiled warn when .so missing", function()
    vim.fn.filereadable = function(path)
      if path:match("parser%.c$") then return 1 end
      return 0
    end
    package.loaded["poste-http.health"] = nil
    health = require("poste-http.health")
    health.check()
    local has_not_compiled = false
    for _, r in ipairs(mock_health._reports) do
      if r.type == "warn" and r.msg:match("not compiled") then
        has_not_compiled = true
      end
    end
    assert.is_true(has_not_compiled)
  end)

  it("warns when the compiled parser is older than the parser source", function()
    -- Regression: a stale parser silently serves an outdated grammar
    -- (GRAPHQL highlights and bodies vanished until the parser was rebuilt).
    vim.fn.getftime = function(path)
      if path:match("parser%.c$") then return 200 end
      return 100
    end
    package.loaded["poste-http.health"] = nil
    health = require("poste-http.health")
    health.check()
    local has_stale = false
    for _, r in ipairs(mock_health._reports) do
      if r.type == "warn" and r.msg:match("stale") then
        has_stale = true
      end
    end
    assert.is_true(has_stale)
  end)

  it("reports parser compiled when .so is at least as new as the source", function()
    vim.fn.getftime = function(path)
      if path:match("parser%.c$") then return 100 end
      return 200
    end
    package.loaded["poste-http.health"] = nil
    health = require("poste-http.health")
    health.check()
    local has_compiled, has_stale = false, false
    for _, r in ipairs(mock_health._reports) do
      if r.type == "ok" and r.msg:match("parser compiled") then
        has_compiled = true
      end
      if r.msg and r.msg:match("stale") then
        has_stale = true
      end
    end
    assert.is_true(has_compiled)
    assert.is_false(has_stale)
  end)

  it("reports parser active in Neovim for both grammars", function()
    health.check()
    local http_active = false
    local json_active = false
    for _, r in ipairs(mock_health._reports) do
      if r.type == "ok" and r.msg:match("poste_http") and r.msg:match("parser active") then
        http_active = true
      end
      if r.type == "ok" and r.msg:match("poste_json") and r.msg:match("parser active") then
        json_active = true
      end
    end
    assert.is_true(http_active)
    assert.is_true(json_active)
  end)

  it("reports parser error when get_parser fails", function()
    vim.treesitter.get_parser = function(buf, lang)
      error("parser not found: " .. lang)
    end
    package.loaded["poste-http.health"] = nil
    health = require("poste-http.health")
    health.check()
    local has_parser_err = false
    for _, r in ipairs(mock_health._reports) do
      if r.type == "error" and r.msg:match("failed to load") then
        has_parser_err = true
      end
    end
    assert.is_true(has_parser_err)
  end)

  it("starts with a poste-http section", function()
    health.check()
    assert.is_true(#mock_health._reports >= 1)
    assert.equal("start", mock_health._reports[1].type)
    assert.equal("poste-http", mock_health._reports[1].name)
  end)

  it("reports all sections: curl, C compiler, tree-sitter", function()
    health.check()
    local sections = {}
    for _, r in ipairs(mock_health._reports) do
      if r.type == "start" then
        table.insert(sections, r.name)
      end
    end
    assert.is_true(vim.tbl_contains(sections, "curl"))
    assert.is_true(vim.tbl_contains(sections, "C compiler"))
    assert.is_true(vim.tbl_contains(sections, "tree-sitter-poste-http"))
  end)
end)