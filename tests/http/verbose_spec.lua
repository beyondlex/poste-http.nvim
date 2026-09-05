local mock = require("helpers.mock_nvim")
local verbose = require("poste-http.http.format.verbose")

describe("verbose.lua", function()
  local function make_r(opts)
    opts = opts or {}
    return {
      url = opts.url or "http://example.com/foo",
      metadata = { method = opts.method or "GET" },
      status = opts.status or 200,
      status_text = opts.status_text or "200 OK",
      headers = opts.headers or {},
      body = opts.body or "",
      content_type = opts.content_type or "text/plain",
      latency_ms = opts.latency_ms or 42,
      protocol = opts.protocol,
    }
  end

  describe("format_verbose opts.width", function()
    it("defaults to 80", function()
      local r = make_r { body = "x" }
      verbose.format_verbose(r)
      assert.equals(80, r._fmt_width)
    end)

    it("produces lines bounded by the given width", function()
      local r = make_r { body = "x" }
      local lines = verbose.format_verbose(r, nil, { width = 30 })

      local function max_disp_width(ls)
        local m = 0
        for _, l in ipairs(ls) do
          local w = vim.fn.strdisplaywidth(l)
          if w > m then m = w end
        end
        return m
      end

      assert.is_true(max_disp_width(lines) <= 30,
        string.format("max line width %d exceeds 30", max_disp_width(lines)))
    end)

    it("stores fmt_width on response", function()
      local r = make_r { body = "x" }
      verbose.format_verbose(r, nil, { width = 50 })
      assert.equals(50, r._fmt_width)
    end)
  end)

  describe("apply_verbose_highlights precedence", function()
    before_each(function()
      mock.setup { buf_is_valid = function() return true end }
    end)

    after_each(function()
      mock.teardown()
    end)

    it("uses r._fmt_method over stale module M._fmt_method", function()
      local r1 = make_r { method = "GET", url = "http://get.example.com/x" }
      local r2 = make_r { method = "POST", url = "http://post.example.com/x" }

      local lines1 = verbose.format_verbose(r1)
      verbose.format_verbose(r2)
      mock.reset_calls()

      verbose.apply_verbose_highlights(1001, lines1, r1)

      local found = false
      for i = 1, #mock.calls, 2 do
        if mock.calls[i] == "nvim_buf_set_extmark" then
          local detail = mock.calls[i + 1]
          if detail.opts and detail.opts.virt_text then
            for _, vt in ipairs(detail.opts.virt_text) do
              if type(vt[1]) == "string" and vt[1]:match("^GET ") then
                found = true
              end
            end
          end
        end
      end
      assert.is_true(found, "should show GET method, not stale POST from module")
    end)
  end)

  describe("section heuristic fix", function()
    before_each(function()
      mock.setup { buf_is_valid = function() return true end }
    end)

    after_each(function()
      mock.teardown()
    end)

    it("does not treat body line as section boundary", function()
      local body = "Hello World\nplain tail"
      local r = make_r { body = body, content_type = "text/plain" }
      local lines = verbose.format_verbose(r)
      mock.reset_calls()

      verbose.apply_verbose_highlights(1001, lines, r)

      local section_hl_count = 0
      local body_misjudged = false
      for i = 1, #mock.calls, 2 do
        if mock.calls[i] == "nvim_buf_set_extmark" then
          local detail = mock.calls[i + 1]
          if detail.opts and detail.opts.hl_group == "PosteVerboseSection" then
            section_hl_count = section_hl_count + 1
            local line_text = lines[detail.line + 1]
            if line_text and line_text:match("Hello World") then
              body_misjudged = true
            end
          end
        end
      end

      assert.is_false(body_misjudged,
        "body line 'Hello World' should not be highlighted as PosteVerboseSection")
      assert.is_true(section_hl_count >= 4,
        string.format("expected at least 4 real section titles, got %d", section_hl_count))
    end)
  end)

  describe("format_request_payload cache hygiene", function()
    it("does not poison format_verbose's r._cached_verbose on multipart parse failure", function()
      local r = make_r { method = "POST", body = "irrelevant" }
      -- Multipart content-type whose body carries no boundary marker, so the
      -- payload formatter takes its parse-failed fallback path.
      r.metadata.request_headers = "Content-Type: multipart/form-data; boundary=missing"
      r.metadata.request_body = "no boundary marker in here"

      local payload_lines = verbose.format_request_payload(r)
      assert.equals("(multipart form data — parse failed)", payload_lines[1])

      local view_lines = verbose.format_verbose(r)
      assert.is_nil(r._cached_verbose,
        "format_request_payload must not write the verbose-view cache")
      local has_verbose_sections = false
      for _, l in ipairs(view_lines) do
        if l == "  Request Headers" or l == "  Request Body" then
          has_verbose_sections = true
          break
        end
      end
      assert.is_true(has_verbose_sections,
        "format_verbose must render the verbose view, not the request payload lines")
    end)
  end)
end)