local state = require("poste.state")
local tree = require("poste.sql.db_browser.tree")
local async = require("poste.sql.db_browser.async")
local actions = require("poste.sql.db_browser.actions")
local HEADER_LINES = require("poste.sql.db_browser.icons").HEADER_LINES

local M = {}

local browser_buf = nil
local browser_win = nil
local root_nodes = {}
local line_to_node = {}
local source_buf = nil

local function make_context()
  local conn_label = state.sql.db_browser.connection or "No connection"
  return {
    browser_buf = browser_buf,
    line_to_node = line_to_node,
    root_nodes = root_nodes,
    source_buf = source_buf,
    conn_label = conn_label,
  }
end

local function render_tree()
  if not browser_buf or not vim.api.nvim_buf_is_valid(browser_buf) then return end
  local conn_label = state.sql.db_browser.connection or "No connection"
  local new_map = tree.render_tree(browser_buf, line_to_node, root_nodes, conn_label)
  line_to_node = new_map
end

local function setup_browser_buffer()
  if browser_buf and vim.api.nvim_buf_is_valid(browser_buf) then return browser_buf end

  browser_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = browser_buf })
  vim.api.nvim_set_option_value("bufhidden", "hide", { buf = browser_buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = browser_buf })
  vim.api.nvim_set_option_value("modifiable", false, { buf = browser_buf })
  vim.api.nvim_buf_set_name(browser_buf, "poste://db_browser")

  local opts = { buffer = browser_buf, noremap = true, silent = true }
  local k = state.get_keymap("sql_db_browser", "toggle_node", "<CR>")
  if k then
    vim.keymap.set("n", k, function()
      actions.toggle_node(vim.fn.line("."), make_context())
    end, opts)
  end
  k = state.get_keymap("sql_db_browser", "move_left", "h")
  if k then
    vim.keymap.set("n", k, function()
      actions.collapse_or_parent(vim.fn.line("."), make_context())
    end, opts)
  end
  k = state.get_keymap("sql_db_browser", "move_right", "l")
  if k then
    vim.keymap.set("n", k, function()
      actions.expand_or_child(vim.fn.line("."), make_context())
    end, opts)
  end
  k = state.get_keymap("sql_db_browser", "refresh_node", "r")
  if k then
    vim.keymap.set("n", k, function()
      actions.refresh_node(vim.fn.line("."), make_context())
    end, opts)
  end
  k = state.get_keymap("sql_db_browser", "search_filter", "/")
  if k then
    vim.keymap.set("n", k, function()
      actions.search_filter(vim.fn.line("."), make_context())
    end, opts)
  end
  k = state.get_keymap("sql_db_browser", "select_query", "s")
  if k then
    vim.keymap.set("n", k, function()
      actions.generate_select_query(vim.fn.line("."), make_context())
    end, opts)
  end
  k = state.get_keymap("sql_db_browser", "describe_query", "d")
  if k then
    vim.keymap.set("n", k, function()
      actions.generate_describe_query(vim.fn.line("."), make_context())
    end, opts)
  end
  k = state.get_keymap("sql_db_browser", "close", "q")
  if k then
    vim.keymap.set("n", k, function() M.close() end, opts)
  end
  k = state.get_keymap("sql_db_browser", "search_next", "n")
  if k then
    vim.keymap.set("n", k, function() actions.search_next() end, opts)
  end
  k = state.get_keymap("sql_db_browser", "search_prev", "N")
  if k then
    vim.keymap.set("n", k, function() actions.search_prev() end, opts)
  end

  k = state.get_keymap("sql_db_browser", "context_menu", "x")
  if k then
    local context_menu = require("poste.sql.db_browser.context_menu")
    vim.keymap.set("n", k, function()
      local node = tree.get_node_at_line(line_to_node, vim.fn.line("."))
      context_menu.open(node, make_context())
    end, opts)
  end

  local table_ops = require("poste.sql.table_ops")
  table_ops.register_keymaps(browser_buf, function()
    local buf_line = vim.fn.line(".")
    local idx = buf_line - HEADER_LINES
    local node = nil
    for i = idx, 1, -1 do
      local n = line_to_node[i]
      if n and n.node_type == "table" then node = n; break end
      if n and (n.node_type == "database" or n.node_type == "schema" or n.node_type == "connection") then break end
    end
    if not node then return nil end
    local dialect = "postgres"
    for _, root in ipairs(root_nodes) do
      if root.name == (node.meta and node.meta.connection) then
        dialect = root.meta and root.meta.dialect or dialect; break end
    end
    return { table_name = node.name, dialect = dialect, source_buf = source_buf }
  end)

  return browser_buf
end

local function open_window()
  if browser_win and vim.api.nvim_win_is_valid(browser_win) then return browser_win end

  vim.cmd("topleft 40vsplit")
  browser_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(browser_win, browser_buf)
  vim.api.nvim_set_option_value("number", false, { win = browser_win })
  vim.api.nvim_set_option_value("relativenumber", false, { win = browser_win })
  vim.api.nvim_set_option_value("signcolumn", "no", { win = browser_win })
  vim.api.nvim_set_option_value("wrap", false, { win = browser_win })
  vim.api.nvim_set_option_value("cursorline", true, { win = browser_win })
  vim.api.nvim_set_option_value("conceallevel", 2, { win = browser_win })
  vim.api.nvim_set_option_value("spell", false, { win = browser_win })

  return browser_win
end

local function get_search_dir()
  if source_buf and vim.api.nvim_buf_is_valid(source_buf) then
    local buf_name = vim.api.nvim_buf_get_name(source_buf)
    if buf_name ~= "" then
      return vim.fn.fnamemodify(buf_name, ":p:h")
    end
  end
  return vim.fn.getcwd()
end

function M.navigate_to(conn_name, db_name)
  source_buf = vim.api.nvim_get_current_buf()
  setup_browser_buffer()
  open_window()

  local search_dir = get_search_dir()
  async.load_connections(function(nodes)
    root_nodes = nodes
    if #root_nodes > 0 then
      state.sql.db_browser.connection = root_nodes[1].name
    end

    local conn_node = nil
    for _, node in ipairs(root_nodes) do
      if node.name == conn_name then conn_node = node; break end
    end
    if not conn_node then
      render_tree()
      vim.notify("Connection '" .. conn_name .. "' not found in connections.json", vim.log.levels.WARN)
      return
    end

    conn_node.loading = true
    render_tree()
    async.fetch_children(conn_node, function()
      conn_node.expanded = true

      local db_node = nil
      for _, child in ipairs(conn_node.children or {}) do
        if child.node_type == "database" and child.name == db_name then
          db_node = child; break
        end
      end
      if not db_node then
        vim.schedule(function()
          render_tree()
          vim.notify("Database '" .. db_name .. "' not found under '" .. conn_name .. "'", vim.log.levels.WARN)
        end)
        return
      end

      db_node.loading = true
      vim.schedule(function() render_tree() end)
      async.fetch_children(db_node, function()
        db_node.expanded = true
        vim.schedule(function()
          render_tree()
          for i, node in ipairs(line_to_node) do
            if node == db_node then
              local target_line = i + HEADER_LINES
              if vim.api.nvim_win_is_valid(browser_win) then
                vim.api.nvim_set_current_win(browser_win)
                vim.api.nvim_win_set_cursor(browser_win, { target_line, 0 })
              end
              break
            end
          end
        end)
      end, search_dir)
    end, search_dir)
  end, search_dir)
end

function M.navigate_to_table(conn_name, db_name, table_name, column_name)
  source_buf = vim.api.nvim_get_current_buf()
  setup_browser_buffer()
  open_window()

  local schema_name = nil
  local bare_table = table_name
  local dot_idx = table_name:find("%.")
  if dot_idx then
    schema_name = table_name:sub(1, dot_idx - 1)
    bare_table = table_name:sub(dot_idx + 1)
  end

  local search_dir = get_search_dir()
  async.load_connections(function(nodes)
    root_nodes = nodes
    if #root_nodes > 0 then
      state.sql.db_browser.connection = root_nodes[1].name
    end

    local conn_node = nil
    for _, node in ipairs(root_nodes) do
      if node.name == conn_name then conn_node = node; break end
    end
    if not conn_node then
      render_tree()
      vim.notify("Connection '" .. conn_name .. "' not found", vim.log.levels.WARN)
      return
    end

    local dialect = conn_node.meta and conn_node.meta.dialect or "postgres"

    local function position_on_table(table_node, col_name)
      vim.schedule(function()
        render_tree()
        local target_node = table_node
        if col_name and table_node.children then
          for _, child in ipairs(table_node.children) do
            if child.node_type == "column" and child.name == col_name then
              target_node = child; break
            end
          end
        end
        for i, n in ipairs(line_to_node) do
          if n == target_node then
            local target_line = i + HEADER_LINES
            if vim.api.nvim_win_is_valid(browser_win) then
              vim.api.nvim_set_current_win(browser_win)
              vim.api.nvim_win_set_cursor(browser_win, { target_line, 0 })
            end
            break
          end
        end
      end)
    end

    if dialect == "sqlite" then
      conn_node.loading = true
      render_tree()
      async.fetch_children(conn_node, function()
        conn_node.expanded = true
        local found = nil
        for _, child in ipairs(conn_node.children or {}) do
          if child.node_type == "table" and child.name == bare_table then
            found = child; break
          end
        end
        if not found then vim.schedule(function() render_tree() end); return end
        found.loading = true
        vim.schedule(function() render_tree() end)
        async.fetch_children(found, function()
          found.expanded = true
          position_on_table(found, column_name)
        end, search_dir)
      end, search_dir)
      return
    end

    conn_node.loading = true
    render_tree()
    async.fetch_children(conn_node, function()
      conn_node.expanded = true
      local db_node = nil
      for _, child in ipairs(conn_node.children or {}) do
        if child.node_type == "database" and child.name == db_name then
          db_node = child; break
        end
      end
      if not db_node then
        vim.schedule(function() render_tree(); vim.notify("Database '" .. (db_name or "?") .. "' not found", vim.log.levels.WARN) end)
        return
      end

      if dialect == "postgres" then
        local target_schema = schema_name or "public"
        db_node.loading = true
        vim.schedule(function() render_tree() end)
        async.fetch_children(db_node, function()
          db_node.expanded = true
          local schema_node = nil
          for _, child in ipairs(db_node.children or {}) do
            if child.node_type == "schema" and child.name == target_schema then
              schema_node = child; break
            end
          end
          if not schema_node then
            vim.schedule(function() render_tree(); vim.notify("Schema '" .. target_schema .. "' not found", vim.log.levels.WARN) end)
            return
          end
          schema_node.loading = true
          vim.schedule(function() render_tree() end)
          async.fetch_children(schema_node, function()
            schema_node.expanded = true
            local table_node = nil
            for _, child in ipairs(schema_node.children or {}) do
              if child.node_type == "table" and child.name == bare_table then
                table_node = child; break
              end
            end
            if not table_node then
              vim.schedule(function() render_tree(); vim.notify("Table '" .. bare_table .. "' not found", vim.log.levels.WARN) end)
              return
            end
            table_node.loading = true
            vim.schedule(function() render_tree() end)
            async.fetch_children(table_node, function()
              table_node.expanded = true
              position_on_table(table_node, column_name)
            end, search_dir)
          end, search_dir)
        end, search_dir)
      else
        db_node.loading = true
        vim.schedule(function() render_tree() end)
        async.fetch_children(db_node, function()
          db_node.expanded = true
          local table_node = nil
          for _, child in ipairs(db_node.children or {}) do
            if child.node_type == "table" and child.name == bare_table then
              table_node = child; break
            end
          end
          if not table_node then
            vim.schedule(function() render_tree(); vim.notify("Table not found", vim.log.levels.WARN) end)
            return
          end
          table_node.loading = true
          vim.schedule(function() render_tree() end)
          async.fetch_children(table_node, function()
            table_node.expanded = true
            position_on_table(table_node, column_name)
          end, search_dir)
        end, search_dir)
      end
    end, search_dir)
  end, search_dir)
end

function M.open()
  source_buf = vim.api.nvim_get_current_buf()
  setup_browser_buffer()
  open_window()

  local search_dir = get_search_dir()
  async.load_connections(function(nodes)
    root_nodes = nodes
    if #root_nodes > 0 then
      state.sql.db_browser.connection = root_nodes[1].name
    end
    render_tree()
    -- Focus cursor on first connection
    for i, node in ipairs(line_to_node) do
      if node.node_type == "connection" then
        local target_line = i + HEADER_LINES
        if vim.api.nvim_win_is_valid(browser_win) then
          vim.api.nvim_set_current_win(browser_win)
          vim.api.nvim_win_set_cursor(browser_win, { target_line, 0 })
        end
        break
      end
    end
  end, search_dir)
end

function M.close()
  if browser_win and vim.api.nvim_win_is_valid(browser_win) then
    vim.api.nvim_win_close(browser_win, true)
    browser_win = nil
  end
end

function M.is_open()
  return browser_win and vim.api.nvim_win_is_valid(browser_win)
end

function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

return M