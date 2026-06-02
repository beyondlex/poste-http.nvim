" Vim ftplugin for Poste HTTP request files (.http, .rest)

if exists("b:did_ftplugin")
  finish
endif
let b:did_ftplugin = 1

" Comment settings
setlocal commentstring=#\ %s
setlocal comments=:#,s:/*,mb:*,ex:*/

" Undo ftplugin settings when filetype changes
let b:undo_ftplugin = "setl cms< com<"
