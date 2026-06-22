" Vim ftplugin for Poste HTTP request files (.http, .rest)

if exists("b:did_ftplugin")
  finish
endif
let b:did_ftplugin = 1

" Comment settings
setlocal commentstring=#\ %s
setlocal comments=:#,s:/*,mb:*,ex:*/

" Disable auto-continuing comments on o/O
setlocal formatoptions-=o

" ─── Kulala.nvim compatibility ──────────────────────────
" When a .http file is opened, Neovim's built-in detection briefly sets
" filetype=http before Poste's after/ftdetect overrides it to poste_http.
" During that window, kulala.nvim may attach LSP/diagnostics.
" This one-time cleanup removes stale kulala state from the buffer.
if has('nvim')
  lua << EOF
    local bufnr = vim.api.nvim_get_current_buf()

    -- Clear any kulala diagnostics that may have attached during the
    -- brief filetype=http window before Poste overrode it
    local ok, ns = pcall(vim.api.nvim_get_namespaces)
    if ok then
      for name, id in pairs(ns) do
        if name:find("kulala") then
          vim.diagnostic.set(id, bufnr, {})
        end
      end
    end

    -- Detach any kulala LSP clients that attached to this buffer
    pcall(function()
      for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
        if client.name == "kulala" then
          vim.lsp.stop_client(client.id)
        end
      end
    end)

    -- Remove kulala's TextChanged autocmd that re-adds diagnostics
    pcall(function()
      vim.api.nvim_clear_autocmds({
        group = "KulalaDiagnostics",
        buffer = bufnr
      })
    end)
EOF
endif

" ─── Completion source setup ──────────────────────
" Supports both blink.cmp (LazyVim default) and nvim-cmp.
" blink.cmp: sources are config-based, no buffer setup needed.
" nvim-cmp: requires buffer-level source registration.
lua << EOF
-- Check if blink.cmp is available (LazyVim default)
local blink_ok = pcall(require, "blink.cmp")
if blink_ok then
  -- blink.cmp uses sources.providers config, not buffer-level registration.
  -- Users add the poste provider in their blink.cmp config.
  -- See README.md for configuration example.
  return
end

-- Fall back to nvim-cmp buffer setup
local function setup_buffer_cmp()
  local ok, cmp = pcall(require, "cmp")
  if not ok then return end
  cmp.setup.buffer({
    enabled = true,
    sources = cmp.config.sources({
      { name = "poste", priority = 100 },
    }, {
      { name = "buffer" },
    }),
  })
end

-- Try immediately
pcall(setup_buffer_cmp)

-- If cmp not loaded yet, set up InsertEnter autocmd
if not pcall(require, "cmp") then
  local buf = vim.api.nvim_get_current_buf()
  local group = vim.api.nvim_create_augroup("PosteHttpCmpBuffer", { clear = true })
  vim.api.nvim_create_autocmd("InsertEnter", {
    group = group,
    buffer = buf,
    callback = function()
      pcall(setup_buffer_cmp)
      -- Clean up autocmd after successful setup
      vim.api.nvim_del_augroup_by_name("PosteHttpCmpBuffer")
    end,
  })
end
EOF

endif

" Undo ftplugin settings when filetype changes
let b:undo_ftplugin = "setl cms< com<"
