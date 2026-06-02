" Vim syntax file for Poste HTTP request files (.http, .rest)
" Language: Poste HTTP request format
" Maintainer: Poste contributors
" Latest Revision: 2026-06-02

if exists("b:current_syntax")
  finish
endif

" ─── Comments & Directives ──────────────────────────
" Directives must be checked before plain comments since both start with # or --
syn match PosteDirective display
  \ '^\s*[#-]\{-}\s*@\%(prompt\|connection\)\s\+.*$'
syn match PosteComment display '^\s*#.*$'
syn match PosteComment display '^\s*--.*$'

" ─── Request separator ──────────────────────────────
syn match PosteSeparator display '^###'
syn match PosteRequestName display '^###\s\+\zs.*$'

" ─── Variable definitions: @name = value / @name value ──
syn match PosteVarDef display '^\s*@\w\+'
  \ nextgroup=PosteVarAssign,PosteVarValue skipwhite
syn match PosteVarAssign display '=' contained
  \ nextgroup=PosteVarValue skipwhite
syn match PosteVarValue display '.\+$' contained

" ─── Variable references ────────────────────────────
syn match PosteMagicVar display '{{\$\w\+}}'
syn match PosteVarRef display '{{[^}]\+}}'

" ─── Pre-request script blocks ──────────────────────
syn region PostePreScript start='<\s*{%$' end='^%}'
  \ contains=PosteScriptMarker keepend
syn match PostePreScript display '<\s*{%.*%}'
  \ contains=PosteScriptMarker

" ─── Assertion / post-request script blocks ─────────
syn region PosteAssertion start='>\s*{%$' end='^%}'
  \ contains=PosteScriptMarker keepend
syn match PosteAssertion display '>\s*{%.*%}'
  \ contains=PosteScriptMarker

" Script markers (contained in PreScript / Assertion regions)
syn match PosteScriptMarker display '{%' contained
syn match PosteScriptMarker display '%}' contained

" ─── External script reference ──────────────────────
syn match PosteExternalScript display '<\s\+\./\S*\.lua\s*$'

" ─── File inclusion in body ─────────────────────────
syn match PosteFileInclude display '<\s\+/\S\+'

" ─── HTTP request line ──────────────────────────────
syn keyword PosteMethod
  \ GET POST PUT DELETE PATCH HEAD OPTIONS TRACE CONNECT
  \ nextgroup=PosteUrl skipwhite
syn match PosteUrl display '\S\+' contained
  \ nextgroup=PosteHttpVersion skipwhite
syn match PosteHttpVersion display 'HTTP/\d\+\%(\.\d\+\)\?' contained

" ─── Headers ────────────────────────────────────────
syn match PosteHeaderKey display '^\s*[^:<>{}@#]\{-}\ze:'
  \ nextgroup=PosteHeaderSep
syn match PosteHeaderSep display ':' contained

" ─── Highlight group links ──────────────────────────
hi def link PosteSeparator   Delimiter
hi def link PosteRequestName Title
hi def link PosteComment     Comment
hi def link PosteVarDef      Identifier
hi def link PosteVarAssign   Operator
hi def link PosteVarValue    String
hi def link PosteVarRef      Identifier
hi def link PosteMagicVar    Special
hi def link PosteMethod      Keyword
hi def link PosteUrl         Underlined
hi def link PosteHttpVersion Constant
hi def link PosteHeaderKey   Type
hi def link PosteHeaderSep   Delimiter
hi def link PosteDirective   PreProc
hi def link PostePreScript   PreProc
hi def link PosteAssertion   PreProc
hi def link PosteScriptMarker Special
hi def link PosteExternalScript Include
hi def link PosteFileInclude Include

let b:current_syntax = "poste_http"
