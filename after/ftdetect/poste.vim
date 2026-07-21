" Poste filetype override — runs AFTER Neovim's built-in filetype detection.
" Neovim's runtime sets filetype=http for *.http files, which overrides
" ftdetect/poste.vim's setfiletype. Using 'set filetype=' here forces
" our custom filetype regardless of what was set before.

if !exists("g:loaded_poste")
  finish
endif

autocmd BufRead,BufNewFile *.http,*.rest setlocal filetype=poste_http

" Fix current buffer if it was already loaded with wrong filetype
if &filetype == 'http'
  let s:fname = expand('%:t')
  if s:fname =~ '\.http$' || s:fname =~ '\.rest$'
    setlocal filetype=poste_http
  endif
endif
