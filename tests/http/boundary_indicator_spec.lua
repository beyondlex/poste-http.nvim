local mock = require("helpers.mock_nvim")

describe("boundary_indicator", function()
  before_each(function()
    mock.setup {
      buf_is_valid = function() return true end,
    }
  end)

  after_each(function()
    mock.teardown()
  end)

  it("sets up CursorMoved autocmd on toggle on and removes on toggle off", function()
    local bi = require("poste-http.http.boundary_indicator")
    mock.reset_calls()

    -- First toggle disables (disabled starts false → true), second enables
    bi.toggle()
    bi.toggle()

    local augroup_created = false
    local autocmd_created = false
    for i = 1, #mock.calls do
      if mock.calls[i] == "nvim_create_augroup" then
        local detail = mock.calls[i + 1]
        if detail and type(detail) == "table" and detail.name == "PosteHttpBoundary" then
          augroup_created = true
        end
      end
      if mock.calls[i] == "nvim_create_autocmd" then
        local detail = mock.calls[i + 1]
        -- the toggle is global: CursorMoved rides in a LIST with
        -- CursorMovedI/BufEnter (2026-09-26), not a bare string
        local events = detail and type(detail) == "table" and detail.events or nil
        if type(events) == "string" then
          events = { events }
        end
        if events and vim.list_contains(events, "CursorMoved") then
          autocmd_created = true
        end
      end
    end

    assert.is_true(augroup_created, "should create augroup on toggle on")
    assert.is_true(autocmd_created, "should create CursorMoved autocmd on toggle on")

    mock.reset_calls()
    bi.toggle()

    local augroup_deleted = false
    for i = 1, #mock.calls do
      if mock.calls[i] == "nvim_del_augroup_by_id" then
        augroup_deleted = true
      end
    end
    assert.is_true(augroup_deleted, "should delete augroup on toggle off")
  end)
end)