local M = {}

-- Configuration
local config = {
  poste_binary = vim.fn.exepath("poste"),
  default_env = "dev",
  split_direction = "vertical", -- "vertical" or "horizontal"
  split_size = 80,
}

-- State
local current_env = config.default_env
local response_buffer = nil
local response_window = nil

-- Find the poste binary (prefer local build, then PATH)
local function find_poste_binary()
  if config.poste_binary ~= "" then
    return config.poste_binary
  end
  
  -- Check for local build
  local local_paths = {
    "./target/debug/poste",
    "./target/release/poste",
  }
  
  for _, path in ipairs(local_paths) do
    if vim.fn.filereadable(path) == 1 then
      return vim.fn.fnamemodify(path, ":p")
    end
  end
  
  return nil
end

-- Create or get response buffer
local function get_response_buffer()
  if response_buffer and vim.api.nvim_buf_is_valid(response_buffer) then
    return response_buffer
  end
  
  response_buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = response_buffer })
  vim.api.nvim_set_option_value("bufhidden", "hide", { buf = response_buffer })
  vim.api.nvim_set_option_value("swapfile", false, { buf = response_buffer })
  vim.api.nvim_set_option_value("modifiable", false, { buf = response_buffer })
  vim.api.nvim_buf_set_name(response_buffer, "poste://response")
  
  -- Set up buffer keymaps
  local opts = { buffer = response_buffer, noremap = true, silent = true }
  vim.keymap.set("n", "q", function()
    if response_window and vim.api.nvim_win_is_valid(response_window) then
      vim.api.nvim_win_close(response_window, true)
      response_window = nil
    end
  end, opts)
  
  return response_buffer
end

-- Show response in a split window
local function show_response(output)
  local buf = get_response_buffer()
  
  -- Make buffer modifiable to write content
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  
  -- Parse output and format it
  local lines = {}
  for line in output:gmatch("[^\r\n]+") do
    table.insert(lines, line)
  end
  
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  
  -- Make buffer read-only again
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  
  -- Open split window if not already open
  if not response_window or not vim.api.nvim_win_is_valid(response_window) then
    local cmd = config.split_direction == "vertical" and "vsplit" or "split"
    vim.cmd(cmd)
    response_window = vim.api.nvim_get_current_win()
    
    -- Set window options
    if config.split_direction == "vertical" then
      vim.api.nvim_win_set_width(response_window, config.split_size)
    else
      vim.api.nvim_win_set_height(response_window, config.split_size)
    end
  end
  
  vim.api.nvim_win_set_buf(response_window, buf)
  vim.api.nvim_set_current_win(response_window)
  
  -- Move cursor to top
  vim.api.nvim_win_set_cursor(response_window, {1, 0})
end

-- Run request at current cursor position
function M.run_request()
  local binary = find_poste_binary()
  if not binary then
    vim.notify("Poste binary not found. Make sure it's in PATH or built locally.", vim.log.levels.ERROR)
    return
  end
  
  local file = vim.fn.expand("%:p")
  local line = vim.fn.line(".")
  
  if file == "" then
    vim.notify("No file open", vim.log.levels.ERROR)
    return
  end
  
  vim.notify(string.format("Running request at line %d (env: %s)...", line, current_env), vim.log.levels.INFO)
  
  local cmd = string.format("%s run %s --line %d --env %s", 
    vim.fn.shellescape(binary),
    vim.fn.shellescape(file),
    line,
    vim.fn.shellescape(current_env)
  )
  
  -- Run async
  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data and #data > 0 then
        local output = table.concat(data, "\n")
        vim.schedule(function()
          show_response(output)
        end)
      end
    end,
    on_stderr = function(_, data)
      if data and #data > 0 then
        local err = table.concat(data, "\n")
        vim.schedule(function()
          vim.notify("Error: " .. err, vim.log.levels.ERROR)
        end)
      end
    end,
    on_exit = function(_, code)
      if code == 0 then
        vim.schedule(function()
          vim.notify("Request completed", vim.log.levels.INFO)
        end)
      else
        vim.schedule(function()
          vim.notify("Request failed with exit code " .. code, vim.log.levels.ERROR)
        end)
      end
    end,
  })
end

-- Jump to next request separator (###)
function M.jump_next()
  local line = vim.fn.line(".")
  local total = vim.fn.line("$")
  
  for i = line + 1, total do
    local text = vim.fn.getline(i)
    if text:match("^###") then
      vim.api.nvim_win_set_cursor(0, {i, 0})
      return
    end
  end
  
  vim.notify("No more requests", vim.log.levels.INFO)
end

-- Jump to previous request separator (###)
function M.jump_prev()
  local line = vim.fn.line(".")
  
  for i = line - 1, 1, -1 do
    local text = vim.fn.getline(i)
    if text:match("^###") then
      vim.api.nvim_win_set_cursor(0, {i, 0})
      return
    end
  end
  
  vim.notify("No previous requests", vim.log.levels.INFO)
end

-- Switch environment
function M.set_env(env_name)
  current_env = env_name
  vim.notify("Environment switched to: " .. env_name, vim.log.levels.INFO)
end

-- Get current environment
function M.get_env()
  return current_env
end

-- Setup function
function M.setup(opts)
  opts = opts or {}
  
  -- Merge config
  config = vim.tbl_deep_extend("force", config, opts)
  
  -- Create commands
  vim.api.nvim_create_user_command("PosteRun", function()
    M.run_request()
  end, { desc = "Run request at cursor" })
  
  vim.api.nvim_create_user_command("PosteEnv", function(args)
    if args.args == "" then
      vim.notify("Current environment: " .. current_env, vim.log.levels.INFO)
    else
      M.set_env(args.args)
    end
  end, { 
    nargs = "?",
    desc = "Switch environment or show current",
    complete = function()
      -- Could read env.json here for completion
      return {}
    end,
  })
  
  -- Create autocommand for .http files
  vim.api.nvim_create_autocmd({"BufRead", "BufNewFile"}, {
    pattern = {"*.http", "*.rest"},
    callback = function()
      -- Set filetype
      vim.bo.filetype = "http"
      
      -- Set up keymaps
      local opts = { buffer = true, noremap = true, silent = true }
      vim.keymap.set("n", "<leader>rr", M.run_request, opts)
      vim.keymap.set("n", "]]", M.jump_next, opts)
      vim.keymap.set("n", "[[", M.jump_prev, opts)
    end,
  })
  
  -- Status line integration
  _G.poste_status = function()
    return string.format("[env: %s]", current_env)
  end
end

return M
