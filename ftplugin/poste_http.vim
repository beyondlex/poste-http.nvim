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

" ─── Kulala.nvim conflict cleanup ──────────────────────
" When a .http file is opened, Neovim's built-in detection first sets
" filetype=http, which causes kulala.nvim to attach its LSP client and
" tree-sitter diagnostics.  Poste's after/ftdetect then overrides the
" filetype to poste_http, but by that point kulala is already attached.
" Clean up kulala's state so we don't get spurious "Parsing error" diagnostics.
if has('nvim')
  lua << EOF
    local function cleanup_kulala()
      local bufnr = vim.api.nvim_get_current_buf()

      -- Clear kulala's diagnostics for this buffer only
      local ok, ns = pcall(vim.api.nvim_get_namespaces)
      if ok then
        for name, id in pairs(ns) do
          if name:find("kulala") then
            vim.diagnostic.set(id, bufnr, {})
          end
        end
      end

      -- Detach any kulala LSP clients attached to this buffer
      pcall(function()
        for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
          if client.name == "kulala" then
            vim.lsp.stop_client(client.id)
          end
        end
      end)
    end

    -- Remove kulala's TextChanged autocmd that keeps re-adding diagnostics
    pcall(function()
      vim.api.nvim_clear_autocmds({
        group = "KulalaDiagnostics",
        buffer = vim.api.nvim_get_current_buf()
      })
    end)

    -- Set up our own autocmd to clear kulala diagnostics on every text change
    local poste_group = vim.api.nvim_create_augroup("PosteKulalaCleanup", { clear = true })
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
      group = poste_group,
      buffer = vim.api.nvim_get_current_buf(),
      callback = function()
        local bufnr = vim.api.nvim_get_current_buf()
        pcall(function()
          local ns = vim.api.nvim_get_namespaces()
          for name, id in pairs(ns) do
            if name:find("kulala") then
              vim.diagnostic.set(id, bufnr, {})
            end
          end
        end)
      end,
    })

    -- Run cleanup now and also defer it to catch late-attaching LSP
    cleanup_kulala()
    vim.schedule(cleanup_kulala)
EOF

" ─── nvim-cmp buffer source ──────────────────────
" Register the poste completion source for this buffer (if nvim-cmp is loaded)
lua << EOF
pcall(function()
  local cmp = require("cmp")
  cmp.setup.buffer({
    sources = cmp.config.sources({
      { name = "poste" },
    }, {
      { name = "buffer" },
    }),
  })
end)
EOF

endif

" Undo ftplugin settings when filetype changes
let b:undo_ftplugin = "setl cms< com< | lua local b=vim.api.nvim_get_current_buf(); pcall(function() for _,c in ipairs(vim.lsp.get_clients({bufnr=b})) do if c.name=='kulala' then vim.lsp.stop_client(c.id) end end end)"
