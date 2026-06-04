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
