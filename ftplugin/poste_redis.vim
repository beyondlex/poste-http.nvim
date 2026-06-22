" Vim ftplugin for Poste Redis request files (.redis)

if exists("b:did_ftplugin")
  finish
endif
let b:did_ftplugin = 1

" Comment settings
setlocal commentstring=#\ %s
setlocal comments=:#

" ─── Kulala.nvim compatibility ──────────────────────────
" Same one-time cleanup as poste_http.vim: if kulala attached during
" the brief filetype=http window, clean up its LSP and diagnostics.
if has('nvim')
  lua << EOF
    local bufnr = vim.api.nvim_get_current_buf()

    local ok, ns = pcall(vim.api.nvim_get_namespaces)
    if ok then
      for name, id in pairs(ns) do
        if name:find("kulala") then
          vim.diagnostic.set(id, bufnr, {})
        end
      end
    end

    pcall(function()
      for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
        if client.name == "kulala" then
          vim.lsp.stop_client(client.id)
        end
      end
    end)
EOF
endif

" Undo ftplugin settings when filetype changes
let b:undo_ftplugin = "setl cms< com<"
