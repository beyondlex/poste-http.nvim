# SQL Completion Fix Plan

## Fix 1: Table handler keyword fallback + async gap

**File:** `lua/poste/sql/completion.lua:289-323`

**Changes:**
1. Remove `if not data.conn_key() then callback(ctx.kw_items(prefix)) else callback({}) end` — always call `callback(ctx.kw_items(prefix))` when `all_items` is empty
2. After both `ensure_*` calls, if `pending > 0` (both async), call `callback(ctx.kw_items(prefix))` immediately to avoid hanging

**Before:**
```lua
  if ctx_type == "table" then
    local pending = 2
    local all_items = {}
    local done = false
    local function flush()
      if done then return end
      done = true
      if #all_items == 0 then
        if not data.conn_key() then
          callback(ctx.kw_items(prefix))
          return
        end
        callback({})
        return
      end
      callback(ctx.filter(all_items, prefix))
    end
    data.ensure_tables(function()
      local key = data.conn_key()
      local cache = data.get_cache()
      for _, t in ipairs(cache[key] and cache[key].tables or {}) do
        table.insert(all_items, { label = t, kind = 7, insertText = t, documentation = "table: " .. t })
      end
      pending = pending - 1
      if pending <= 0 then flush() end
    end)
    data.ensure_databases(function(names)
      for _, db in ipairs(names or {}) do
        table.insert(all_items, { label = db, kind = 1, insertText = db, documentation = "database: " .. db })
      end
      pending = pending - 1
      if pending <= 0 then flush() end
    end)
    return
  end
```

**After:**
```lua
  if ctx_type == "table" then
    local pending = 2
    local all_items = {}
    local done = false
    local function flush()
      if done then return end
      done = true
      if #all_items == 0 then
        callback(ctx.kw_items(prefix))
        return
      end
      callback(ctx.filter(all_items, prefix))
    end
    data.ensure_tables(function()
      local key = data.conn_key()
      local cache = data.get_cache()
      for _, t in ipairs(cache[key] and cache[key].tables or {}) do
        table.insert(all_items, { label = t, kind = 7, insertText = t, documentation = "table: " .. t })
      end
      pending = pending - 1
      if pending <= 0 then flush() end
    end)
    data.ensure_databases(function(names)
      for _, db in ipairs(names or {}) do
        table.insert(all_items, { label = db, kind = 1, insertText = db, documentation = "database: " .. db })
      end
      pending = pending - 1
      if pending <= 0 then flush() end
    end)
    if pending > 0 then
      callback(ctx.kw_items(prefix))
    end
    return
  end
```

## Fix 2: Trigger mechanism

**File:** `lua/poste/init.lua:1150-1181`

**Changes:**
1. Add `InsertEnter` autocmd to show completion when cursor is on an existing identifier
2. Keep existing `CursorMovedI` handler

**New code to add after vim.b.blink_cmp_min_keyword_length = 0 (line 1184):**
```lua
      -- Show completion on InsertEnter if cursor is already on an identifier
      vim.api.nvim_create_autocmd("InsertEnter", {
        group = group,
        buffer = 0,
        callback = function()
          local line = vim.api.nvim_get_current_line()
          local col = vim.api.nvim_win_get_cursor(0)[2]
          local before = line:sub(1, col)
          local prefix = before:match("[%w_]*$") or ""
          if #prefix > 0 then
            vim.schedule(function()
              local ok, t = pcall(require, "blink.cmp.completion.trigger")
              if ok then t.show({ force = true, trigger_kind = "manual" }) end
            end)
          end
        end,
      })
```
