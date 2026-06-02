" Poste file type detection
" Automatically loaded when .http or .rest files are opened

if exists("g:loaded_poste")
  finish
endif
let g:loaded_poste = 1

" Detect .http and .rest files as poste_http
autocmd BufRead,BufNewFile *.http,*.rest setfiletype poste_http

" Detect .redis files as poste_redis (reserved for future syntax)
autocmd BufRead,BufNewFile *.redis setfiletype poste_redis
