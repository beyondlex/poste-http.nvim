--- HTTP completion fixture-driven tests.
--- Loads fixtures from tests/fixtures/http_completion/fixtures.lua
--- and runs each through get_items_for_context.

local completion = require("poste.http.completion")
local cache = require("poste.http.cache")
local state = require("poste.state")
local get_items = completion._test.get_items_for_context

local fixtures = require("tests.fixtures.http_completion.fixtures")

local function create_buf(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

local function find_cursor(lines)
  for i, line in ipairs(lines) do
    local pos = line:find("\226\150\136") -- UTF-8 for █ (U+2588)
    if pos then
      -- Remove cursor marker from the line
      local clean = line:sub(1, pos - 1) .. line:sub(pos + 3)
      local result = {}
      for j, l in ipairs(lines) do
        if j == i then
          table.insert(result, clean)
        else
          table.insert(result, l)
        end
      end
      -- line_before_cursor is everything before █
      local line_before = line:sub(1, pos - 1)
      return result, i, pos - 1, line_before
    end
  end
  return lines, nil, nil, nil
end

--- Create env.json at the given path with the given content.
local function setup_env_json(env_cfg)
  if not env_cfg then return nil end

  local ok = vim.fn.mkdir(env_cfg.path, "p")
  if ok == 0 then return nil end

  local filepath = env_cfg.path .. "/env.json"
  local json_str = vim.fn.json_encode(env_cfg.content)
  local f = io.open(filepath, "w")
  if f then
    f:write(json_str)
    f:close()
  end

  return env_cfg.path
end

--- Clean up env.json and temp dir.
local function teardown_env_json(env_cfg)
  if not env_cfg then return end
  local filepath = env_cfg.path .. "/env.json"
  os.remove(filepath)
  os.remove(env_cfg.path)
end

--- Create helper .http files for import fixture testing.
local function setup_import_fixtures(import_fixtures, base_dir)
  if not import_fixtures then return end
  for _, fixt in ipairs(import_fixtures) do
    local filepath = base_dir .. "/" .. fixt.path
    local f = io.open(filepath, "w")
    if f then
      f:write(table.concat(fixt.lines, "\n"))
      f:close()
    end
  end
end

describe("HTTP completion fixtures", function()
  for _, fixture in ipairs(fixtures) do
    it(fixture.name, function()
      local lines = fixture.lines
      local buf = create_buf(lines)
      local clean_lines, cursor_line, cursor_col, line_before

      clean_lines, cursor_line, cursor_col, line_before = find_cursor(lines)

      if fixture.import_fixtures then
        local import_dir = "/tmp/poste_test_import_" .. math.random(100000)
        vim.fn.mkdir(import_dir, "p")
        -- Set buffer name to import_dir so import resolution finds files there
        vim.api.nvim_buf_set_name(buf, import_dir .. "/test.http")
        setup_import_fixtures(fixture.import_fixtures, import_dir)
        -- Rewrite import directives in clean_lines to absolute paths
        local abs_lines = {}
        for _, l in ipairs(clean_lines) do
          local path = l:match("^import%s+(%S+)")
          if path and not path:match("^/") then
            local abs_path = path:gsub("^%./", "")
            l = l:gsub(path, import_dir .. "/" .. abs_path)
          end
          table.insert(abs_lines, l)
        end
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, abs_lines)
        -- Clear cache so import index is rebuilt
        cache.get_buffer_cache(buf)
      end

      if fixture.env_json then
        local env_dir = setup_env_json(fixture.env_json)
        if env_dir then
          vim.api.nvim_buf_set_name(buf, env_dir .. "/test.http")
          state.current_env = "dev"
        end
      end

      if line_before then
        -- Replace █ lines with cleaned versions (unless import already set them)
        if not fixture.import_fixtures then
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, clean_lines)
        end
      else
        -- No cursor marker: use line_before_cursor directly
        if fixture.full_line then
          line_before = lines[1]
        else
          line_before = lines[1] or ""
        end
      end

      -- Ensure buffer name is set for env var resolution
      if not fixture.env_json and not fixture.import_fixtures then
        local test_dir = "/tmp/poste_test_" .. math.random(100000)
        vim.fn.mkdir(test_dir, "p")
        vim.api.nvim_buf_set_name(buf, test_dir .. "/test.http")
      end

      -- Clear cache between tests
      local ct = vim.api.nvim_buf_get_changedtick(buf)
      cache.get_buffer_cache(buf)

      -- Ensure test buffer is current buffer (collect_env_vars uses buffer 0)
      vim.api.nvim_set_current_buf(buf)

      local items = get_items(line_before, buf, cursor_line or 1, cursor_col or 0)

      -- Collect labels
      local labels = {}
      for _, item in ipairs(items) do
        labels[item.label] = true
      end

      -- Assert expected labels exist
      if fixture.expect then
        for _, label in ipairs(fixture.expect) do
          if not labels[label] then
            local found_labels = {}
            for l, _ in pairs(labels) do table.insert(found_labels, l) end
            table.sort(found_labels)
            error(string.format("Expected label '%s' not found in items. Available: %s",
              label, table.concat(found_labels, ", ")))
          end
        end
      end

      -- Assert unexpected labels do NOT exist
      if fixture.expect_not then
        for _, label in ipairs(fixture.expect_not) do
          if labels[label] then
            error(string.format("Label '%s' found but should not be present", label))
          end
        end
      end
    end)
  end
end)
