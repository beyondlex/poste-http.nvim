" Poste SQL filetype plugin
" Loaded when filetype is set to poste_sql or poste_sqlite

if exists("b:did_poste_sql_ftplugin")
  finish
endif
let b:did_poste_sql_ftplugin = 1

" Use SQL-style comments
setlocal commentstring=--\ %s

" Tab settings for SQL
setlocal shiftwidth=2
setlocal tabstop=2
setlocal expandtab

" Register SQL completion source
lua pcall(function() require("poste.sql.completion").register() end)

" ─── Code formatter support ────────────────────────────
" Auto-detect and set up the best available SQL formatter.
" Supports: sqlfluff, sqlfmt, sql-formatter, pg_format.
" Integrates with:
"   - LazyVim <leader>cf (via LazyFormatter registration)
"   - conform.nvim :ConformFormat (by setting formatters_by_ft)
"   - :PosteFormat or keymap (default <leader>ff) — direct usage
" All integrations handle timing — work regardless of plugin load order.
lua << EOF
local ok, source_format = pcall(require, "poste.sql.source_format")
if ok then
  -- Register with LazyVim's format system (for <leader>cf)
  -- This is the primary path if you use LazyVim
  pcall(source_format.setup_lazyvim)

  -- Register with conform.nvim (for :ConformFormat, conform users)
  -- This also helps if LazyVim's conform formatter takes over
  pcall(source_format.setup_conform)

  -- Set up autocmd to auto-format on save if user opts in via config
  -- (disabled by default; user must set g:poste_sql_autoformat = true)
  if vim.g.poste_sql_autoformat then
    local group = vim.api.nvim_create_augroup("PosteSQLFormatOnSave", { clear = true })
    vim.api.nvim_create_autocmd("BufWritePre", {
      group = group,
      buffer = 0,
      callback = function()
        source_format.auto_format_on_save(vim.api.nvim_get_current_buf())
      end,
    })
  end
end
EOF
