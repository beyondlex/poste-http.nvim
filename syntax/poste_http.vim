" Vim syntax file for Poste HTTP request files (.http, .rest)
" Language: Poste HTTP request format
" Maintainer: Poste contributors
" Latest Revision: 2026-06-02

if exists("b:current_syntax")
  finish
endif

" ─── Request separator + name (MUST be before comments) ─────
syn region PosteRequestName
  \ start='^###' end='$'
  \ contains=PosteSeparator keepend
syn match PosteSeparator '^###' contained

" ─── Comments & Directives ──────────────────────────
syn match PosteDirective
  \ '^\s*[#-]\{-}\s*@\%(prompt\|connection\)\s\+.*$'
syn match PosteComment '^\s*#\s.*$'
syn match PosteComment '^\s*--.*$'

" ─── Variable definitions: @name = value / @name value ──
syn match PosteVarDef '^\s*@\w\+'
  \ nextgroup=PosteVarAssign,PosteVarValue skipwhite
syn match PosteVarAssign '=' contained
  \ nextgroup=PosteVarValue skipwhite
syn match PosteVarValue '.\+$' contained

" ─── Variable references ────────────────────────────
syn match PosteMagicVar '{{\$\w\+}}'
syn match PosteVarRef '{{[^}]\+}}'

" ─── Pre-request script blocks ──────────────────────
syn region PostePreScript start='<\s*{%$' end='^%}'
  \ contains=PosteScriptMarker keepend
syn match PostePreScript '<\s*{%.*%}'
  \ contains=PosteScriptMarker

" ─── Assertion / post-request script blocks ─────────
syn region PosteAssertion start='>\s*{%$' end='^%}'
  \ contains=PosteScriptMarker keepend
syn match PosteAssertion '>\s*{%.*%}'
  \ contains=PosteScriptMarker

" Script markers (contained in PreScript / Assertion regions)
syn match PosteScriptMarker '{%' contained
syn match PosteScriptMarker '%}' contained

" ─── External script reference ──────────────────────
syn match PosteExternalScript '<\s\+\./\S*\.lua\s*$'

" ─── File inclusion in body ─────────────────────────
syn match PosteFileInclude '<\s\+/\S\+'

" ─── HTTP request line ──────────────────────────────
" Methods MUST be defined before PosteHeaderKey to take precedence
" Use \ze (end match) to ensure we match the whole word
syn match PosteMethodGET    '^\s*GET\ze\s'    nextgroup=PosteUrl skipwhite
syn match PosteMethodPOST   '^\s*POST\ze\s'   nextgroup=PosteUrl skipwhite
syn match PosteMethodPUT    '^\s*PUT\ze\s'    nextgroup=PosteUrl skipwhite
syn match PosteMethodDELETE '^\s*DELETE\ze\s' nextgroup=PosteUrl skipwhite
syn match PosteMethodPATCH  '^\s*PATCH\ze\s'  nextgroup=PosteUrl skipwhite
syn match PosteMethodHEAD   '^\s*HEAD\ze\s'   nextgroup=PosteUrl skipwhite
syn match PosteMethodOPTIONS '^\s*OPTIONS\ze\s' nextgroup=PosteUrl skipwhite
syn match PosteMethodOther  '^\s*\%(TRACE\|CONNECT\)\ze\s' nextgroup=PosteUrl skipwhite

" URL: match scheme://... or plain path
" contains=PosteVarRef,PosteMagicVar lets {{...}} highlight inside URLs
syn match PosteUrl '[a-zA-Z][a-zA-Z0-9+.-]*://\S\+' contained
  \ contains=PosteVarRef,PosteMagicVar
  \ nextgroup=PosteHttpVersion skipwhite
syn match PosteUrl '\S\+' contained
  \ contains=PosteVarRef,PosteMagicVar
  \ nextgroup=PosteHttpVersion skipwhite

syn match PosteHttpVersion 'HTTP/\d\+\%(\.\d\+\)\?' contained

" ─── Headers ────────────────────────────────────────
" Only match typical header key characters (letters, digits, hyphens)
" This naturally excludes HTTP methods which are followed by URLs, not colons
syn match PosteHeaderKey '^\s*[A-Za-z][A-Za-z0-9-]*\ze:'
  \ nextgroup=PosteHeaderSep
syn match PosteHeaderSep ':' contained

" ─── Highlight group links ──────────────────────────
hi def link PosteSeparator   Delimiter
hi def link PosteRequestName Title
hi def link PosteComment     Comment
hi def link PosteVarDef      Identifier
hi def link PosteVarAssign   Operator
hi def link PosteVarValue    String
hi def link PosteVarRef      Identifier
hi def link PosteMagicVar    Special
hi def link PosteMethodGET    Keyword
hi def link PosteMethodPOST   Keyword
hi def link PosteMethodPUT    Keyword
hi def link PosteMethodDELETE Keyword
hi def link PosteMethodPATCH  Keyword
hi def link PosteMethodHEAD   Keyword
hi def link PosteMethodOPTIONS Keyword
hi def link PosteMethodOther  Keyword
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
