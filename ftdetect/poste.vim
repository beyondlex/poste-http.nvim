" Poste file type detection
" Automatically loaded when .http or .rest files are opened

if exists("g:loaded_poste")
  finish
endif
let g:loaded_poste = 1

" Try to set filetype early; Neovim's built-in detection may override this.
" The after/ftdetect/poste.vim ensures our filetype wins regardless.
autocmd BufRead,BufNewFile *.http,*.rest setfiletype poste_http
autocmd BufRead,BufNewFile *.redis setfiletype poste_redis
