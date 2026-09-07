local mock = require("helpers.mock_nvim")
local state = require("poste-http.state")

describe("content-disposition download handling", function()
  local fmt_util

  before_each(function()
    mock.setup()
    state.last_response = nil
    state.current_view = "body"
    package.loaded["poste-http.http.format.util"] = nil
    package.loaded["poste-http.http.format.body"] = nil
    package.loaded["poste-http.http.format"] = nil
    fmt_util = require("poste-http.http.format.util")
  end)

  after_each(function()
    mock.teardown()
    package.loaded["poste-http.http.format.util"] = nil
    package.loaded["poste-http.http.format.body"] = nil
    package.loaded["poste-http.http.format"] = nil
  end)

  ---------------------------------------------------------------------------
  -- extract_disposition_filename
  ---------------------------------------------------------------------------

  describe("extract_disposition_filename", function()
    it("returns nil for nil headers", function()
      assert.is_nil(fmt_util.extract_disposition_filename(nil))
    end)

    it("returns nil for empty headers", function()
      assert.is_nil(fmt_util.extract_disposition_filename({}))
    end)

    it("returns nil when no content-disposition header", function()
      local headers = { { "Content-Type", "text/plain" } }
      assert.is_nil(fmt_util.extract_disposition_filename(headers))
    end)

    it("returns nil for inline disposition", function()
      local headers = { { "Content-Disposition", "inline" } }
      assert.is_nil(fmt_util.extract_disposition_filename(headers))
    end)

    it("extracts filename from quoted attachment", function()
      local headers = { { "Content-Disposition", 'attachment; filename="report.xls"' } }
      assert.equals("report.xls", fmt_util.extract_disposition_filename(headers))
    end)

    it("extracts filename from unquoted attachment", function()
      local headers = { { "Content-Disposition", "attachment; filename=report.xls" } }
      assert.equals("report.xls", fmt_util.extract_disposition_filename(headers))
    end)

    it("extracts filename with Chinese characters", function()
      local headers = { { "Content-Disposition", 'attachment; filename="签到数据_2026-07-29.xls"' } }
      assert.equals("签到数据_2026-07-29.xls", fmt_util.extract_disposition_filename(headers))
    end)

    it("sanitizes path separators in filename", function()
      local headers = { { "Content-Disposition", 'attachment; filename="../../etc/passwd"' } }
      local result = fmt_util.extract_disposition_filename(headers)
      assert.is_not_nil(result)
      assert.is_nil(result:find("/"))
      assert.is_nil(result:find("\\"))
      assert.equals(".._.._etc_passwd", result)
    end)

    it("is case-insensitive for header name", function()
      local headers = { { "content-disposition", 'attachment; filename="data.xls"' } }
      assert.equals("data.xls", fmt_util.extract_disposition_filename(headers))
    end)

    it("is case-insensitive for disposition type", function()
      local headers = { { "Content-Disposition", 'ATTACHMENT; filename="data.xls"' } }
      assert.equals("data.xls", fmt_util.extract_disposition_filename(headers))
    end)

    it("returns nil when disposition type is form-data", function()
      local headers = { { "Content-Disposition", 'form-data; name="file"; filename="data.xls"' } }
      assert.is_nil(fmt_util.extract_disposition_filename(headers))
    end)
  end)

  ---------------------------------------------------------------------------
  -- save_binary_body
  ---------------------------------------------------------------------------

  describe("save_binary_body", function()
    it("saves body to file and sets metadata", function()
      local r = { body = "BINARYDATA", content_type = "application/vnd.ms-excel", metadata = {} }
      local path = fmt_util.save_binary_body("BINARYDATA", "test.xls", "application/vnd.ms-excel", r)
      assert.is_not_nil(path)
      assert.is_true(path:find("test%.xls$") ~= nil)
      assert.equals("test.xls", path:match("([^/]+)$"))
      assert.equals("BINARYDATA", r.metadata.file_path and io.open(r.metadata.file_path):read("*a"))
      assert.equals(10, r.metadata.file_size)
      assert.equals("application/vnd.ms-excel", r.metadata.file_content_type)
      assert.is_true(r.metadata.content_disposition_attachment)
      io.open(r.metadata.file_path):close()
      os.remove(r.metadata.file_path)
    end)

    it("handles empty body", function()
      local r = { body = "", content_type = "application/octet-stream", metadata = {} }
      local path = fmt_util.save_binary_body("", "empty.bin", "application/octet-stream", r)
      assert.is_not_nil(path)
      assert.equals(0, r.metadata.file_size)
      os.remove(path)
    end)
  end)

  ---------------------------------------------------------------------------
  -- save_body_to_file
  ---------------------------------------------------------------------------

  describe("save_body_to_file", function()
    it("writes the body, stamps metadata, and previews the first lines", function()
      local r = { metadata = {} }
      local lines = fmt_util.save_body_to_file("line1\nline2\nline3", "text/plain", r)
      assert.is_not_nil(lines)
      assert.equals("line1", lines[1])
      assert.equals("line2", lines[2])
      assert.is_not_nil(r.metadata.file_path)
      assert.equals(17, r.metadata.file_size)
      assert.equals("text/plain", r.metadata.file_content_type)
      local fd = io.open(r.metadata.file_path, "rb")
      local content = fd and fd:read("*a")
      if fd then fd:close() end
      assert.equals("line1\nline2\nline3", content)
      os.remove(r.metadata.file_path)
    end)

    it("builds collision-safe filenames even where strftime %N is unsupported", function()
      -- macOS strftime has no %6N and renders a literal "6N", collapsing the
      -- timestamp to second precision: two dumps in one second overwrote
      -- each other. The millisecond suffix must come from hrtime instead.
      local r = { metadata = {} }
      local _ = fmt_util.save_body_to_file("x", "text/plain", r)
      local name = r.metadata.file_path:match("([^/]+)$")
      assert.is_not_nil(name:match("^res_%d%d%d%d%d%d%d%d_%d%d%d%d%d%d_%d%d%d%.txt$"),
        "filename should carry a 3-digit millisecond suffix, got: " .. name)
      assert.is_nil(name:find("6N", 1, true), "literal strftime fallback must not leak into the name")
      os.remove(r.metadata.file_path)
    end)
  end)

  ---------------------------------------------------------------------------
  -- has_attachment_disposition
  ---------------------------------------------------------------------------

  describe("has_attachment_disposition", function()
    it("returns false for nil headers", function()
      assert.is_false(fmt_util.has_attachment_disposition(nil))
    end)

    it("returns false for empty headers", function()
      assert.is_false(fmt_util.has_attachment_disposition({}))
    end)

    it("returns false when no content-disposition header", function()
      local headers = { { "Content-Type", "text/plain" } }
      assert.is_false(fmt_util.has_attachment_disposition(headers))
    end)

    it("returns true for attachment with filename", function()
      local headers = { { "Content-Disposition", 'attachment; filename="data.xls"' } }
      assert.is_true(fmt_util.has_attachment_disposition(headers))
    end)

    it("returns true for attachment without filename", function()
      local headers = { { "Content-Disposition", "attachment" } }
      assert.is_true(fmt_util.has_attachment_disposition(headers))
    end)

    it("returns false for inline disposition", function()
      local headers = { { "Content-Disposition", "inline" } }
      assert.is_false(fmt_util.has_attachment_disposition(headers))
    end)

    it("returns false for form-data disposition", function()
      local headers = { { "Content-Disposition", 'form-data; name="file"' } }
      assert.is_false(fmt_util.has_attachment_disposition(headers))
    end)
  end)

  ---------------------------------------------------------------------------
  -- content_type_extension
  ---------------------------------------------------------------------------

  describe("content_type_extension", function()
    it("returns .bin for nil", function()
      assert.equals(".bin", fmt_util.content_type_extension(nil))
    end)

    it("returns .xls for application/vnd.ms-excel", function()
      assert.equals(".xls", fmt_util.content_type_extension("application/vnd.ms-excel"))
    end)

    it("returns .bin for unknown types", function()
      assert.equals(".bin", fmt_util.content_type_extension("application/x-unknown"))
    end)

    it("strips parameters from content type", function()
      assert.equals(".xls", fmt_util.content_type_extension("application/vnd.ms-excel; charset=utf-8"))
    end)
  end)

  ---------------------------------------------------------------------------
  -- attachment_filename
  ---------------------------------------------------------------------------

  describe("attachment_filename", function()
    it("uses filename from Content-Disposition when present", function()
      local r = {
        headers = { { "Content-Disposition", 'attachment; filename="report.xls"' } },
        content_type = "application/vnd.ms-excel",
      }
      assert.equals("report.xls", fmt_util.attachment_filename(r))
    end)

    it("generates filename from content type when no Content-Disposition filename", function()
      local r = {
        headers = { { "Content-Disposition", "attachment" } },
        content_type = "application/vnd.ms-excel",
      }
      local fn = fmt_util.attachment_filename(r)
      assert.is_not_nil(fn:match("^download_%d+_%d+_%d+%.xls$"))
    end)

    it("generates filename with .bin for unknown content types", function()
      local r = {
        headers = { { "Content-Disposition", "attachment" } },
        content_type = "application/x-unknown",
      }
      local fn = fmt_util.attachment_filename(r)
      assert.is_not_nil(fn:match("^download_%d+_%d+_%d+%.bin$"))
    end)
  end)

  ---------------------------------------------------------------------------
  -- format_body with Content-Disposition
  ---------------------------------------------------------------------------

  describe("format_body with Content-Disposition: attachment", function()
    it("saves binary body to file and shows file info", function()
      local body_mod = require("poste-http.http.format.body")
      local r = {
        body = "\x01\x02\x03\x04",
        content_type = "application/vnd.ms-excel",
        headers = { { "Content-Disposition", 'attachment; filename="data.xls"' } },
        metadata = {},
      }
      local lines = body_mod.format_body(r)
      assert.is_not_nil(lines)
      assert.is_true(#lines > 0)
      local found_path = false
      local found_open = false
      for _, l in ipairs(lines) do
        if l:match("^  Path:") then found_path = true end
        if l:match("^  Open file:") then found_open = true end
      end
      assert.is_true(found_path, "should show Path line")
      assert.is_true(found_open, "should show Open file line")
      assert.is_not_nil(r.metadata.file_path)
      assert.is_true(r.metadata.file_path:match("data%.xls$") ~= nil)
      assert.equals(4, r.metadata.file_size)
      os.remove(r.metadata.file_path)
    end)

    it("shows Download Response header for disposition", function()
      local body_mod = require("poste-http.http.format.body")
      local r = {
        body = "SOMEDATA",
        content_type = "text/plain",
        headers = { { "Content-Disposition", 'attachment; filename="notes.txt"' } },
        metadata = {},
      }
      local lines = body_mod.format_body(r)
      assert.is_not_nil(lines)
      local has_header = false
      for _, l in ipairs(lines) do
        if l:match("▸ Binary File Response") then has_header = true end
      end
      assert.is_true(has_header, "should show Binary File Response header for disposition with text/plain")
      os.remove(r.metadata.file_path)
    end)

    it("handles attachment without filename by generating one", function()
      local body_mod = require("poste-http.http.format.body")
      local r = {
        body = "\x01\x02\x03\x04",
        content_type = "application/vnd.ms-excel",
        headers = { { "Content-Disposition", "attachment" } },
        metadata = {},
      }
      local lines = body_mod.format_body(r)
      assert.is_not_nil(lines)
      local found_path = false
      local found_open = false
      for _, l in ipairs(lines) do
        if l:match("^  Path:") then found_path = true end
        if l:match("^  Open file:") then found_open = true end
      end
      assert.is_true(found_path, "should show Path line")
      assert.is_true(found_open, "should show Open file line")
      assert.is_not_nil(r.metadata.file_path)
      assert.is_true(r.metadata.file_path:match("%.xls$") ~= nil, "should have .xls extension")
      os.remove(r.metadata.file_path)
    end)

    it("shows file path in verbose view", function()
      local verbose_mod = require("poste-http.http.format.verbose")
      local r = {
        body = "\x01\x02\x03",
        content_type = "application/vnd.ms-excel",
        headers = { { "Content-Disposition", 'attachment; filename="data.xls"' } },
        metadata = { method = "GET" },
        status = 200,
        status_text = "200 OK",
        url = "http://example.com/download",
        latency_ms = 42,
      }
      local lines = verbose_mod.format_verbose(r)
      assert.is_not_nil(lines)
      local found_path = false
      for _, l in ipairs(lines) do
        if l:match("^  Path:") then found_path = true end
      end
      assert.is_true(found_path, "verbose view should show Path line")
      assert.is_not_nil(r.metadata.file_path)
      os.remove(r.metadata.file_path)
    end)
  end)
end)