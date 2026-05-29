" Poste file type detection
" Automatically loaded when .http or .rest files are opened

if exists("g:loaded_poste")
  finish
endif
let g:loaded_poste = 1

" Detect .http and .rest files
autocmd BufRead,BufNewFile *.http,*.rest set filetype=http
