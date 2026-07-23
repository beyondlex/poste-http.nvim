--- Import Swagger 2.0 spec as .http files.
--- Delegates to the same CLI command; the Rust side handles conversion.
local cli = require("poste.cli")
local state = require("poste.state")

local M = {}

local function pick_spec_file(callback)
  local ok, finder = pcall(require, "finder")
  if not ok then
    vim.notify("beyondlex/finder plugin required for file selection", vim.log.levels.ERROR)
    return
  end
  finder.open({
    mode = "file",
    initial_path = vim.fn.getcwd(),
    extensions = { "json", "yaml", "yml" },
    on_confirm = function(path)
      if path then callback(path) end
    end,
    on_cancel = function() end,
  })
end

local function pick_output_dir(default, callback)
  local ok, finder = pcall(require, "finder")
  if not ok then
    vim.notify("beyondlex/finder plugin required for directory selection", vim.log.levels.ERROR)
    return
  end
  finder.open({
    mode = "dir",
    initial_path = default,
    title = " Select output directory ",
    on_confirm = function(path)
      if path then callback(path) end
    end,
    on_cancel = function() end,
  })
end

local function do_import(spec_path, out_dir)
  local cmd = { "import", "swagger", spec_path, "--out", out_dir }

  cli.run_async(cmd, {
    on_stdout = function(data)
      if not data then return end
      for _, line in ipairs(data) do
        if line ~= "" then
          vim.notify(line, vim.log.levels.INFO, { title = "Import Swagger" })
        end
      end
    end,
    on_stderr = function(data)
      if not data then return end
      for _, line in ipairs(data) do
        if line ~= "" then
          vim.notify(line, vim.log.levels.WARN, { title = "Import Swagger" })
        end
      end
    end,
    on_exit = function(code)
      if code == 0 then
        vim.notify(string.format("Swagger import complete → %s", out_dir),
          vim.log.levels.INFO, { title = "Import Swagger" })
      else
        vim.notify("Swagger import failed", vim.log.levels.ERROR, { title = "Import Swagger" })
      end
    end,
  })
end

function M.run()
  pick_spec_file(function(spec_path)
    if not spec_path then return end
    local default_dir = vim.fn.fnamemodify(spec_path, ":h")
    vim.schedule(function()
      pick_output_dir(default_dir, function(out_dir)
        if not out_dir then return end
        do_import(spec_path, out_dir)
      end)
    end)
  end)
end

return M