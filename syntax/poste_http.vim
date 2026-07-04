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
" Prompt directive: <<varname [opts]
syn match PostePrompt '^\s*<<.\{-}\(\[.\{-}\]\)\?\s*$'
  \ contains=PostePromptMarker,PostePromptOpts
syn match PostePromptMarker '<<' contained
syn match PostePromptOpts '\[.\{-}\]' contained
  \ contains=PosteVarRef,PosteMagicVar
" Commented-out prompt: # <<varname [opts]
syn match PosteCommentedPrompt '^\s*#\s*<<.\{-}\(\[.\{-}\]\)\?\s*$'
  \ contains=PosteCommentedPromptMarker,PostePromptOpts
syn match PosteCommentedPromptMarker '#\s*<<' contained
syn match PosteComment '^\s*#\%(\s*<<\)\@!\([^#].*\|$\)'
syn match PosteComment '^\s*--.*$'

" ─── import/run cross-file reference directives ─────
syn match PosteImport '^\s*import' nextgroup=PosteImportPath skipwhite
syn match PosteImportPath '\S\+' contained nextgroup=PosteImportAliasOpt skipwhite
syn match PosteImportAliasOpt '\<as\>' contained nextgroup=PosteImportAlias skipwhite
syn match PosteImportAlias '\S\+' contained

syn match PosteRun '^\s*run' nextgroup=PosteRunTarget skipwhite
syn match PosteRunTarget '\S\+' contained nextgroup=PosteRunVars skipwhite
syn match PosteRunVars '([^)]*)' contained
  \ contains=PosteRunVarDef,PosteRunVarAssign,PosteRunVarValue
syn match PosteRunVarDef '@\w\+' contained
syn match PosteRunVarAssign '=' contained
syn match PosteRunVarValue '[^,)= \t]\+' contained

" ─── Variable definitions: @name = value / @name value ──
syn match PosteVarDef '^\s*@\w\+'
  \ nextgroup=PosteVarAssign,PosteVarValue skipwhite
syn match PosteVarAssign '=' contained nextgroup=PosteVarValue skipwhite
syn match PosteVarValue '[^= \t].*$' contained
  \ contains=PosteVarRef,PosteMagicVar

" ─── Multi-line variable value end marker ──────────
syn match PosteMultiVarEnd '^\s*<<<\s*$'

" ─── Variable references ────────────────────────────
syn match PosteMagicVar '{{\$\w\+}}'
syn match PosteVarRef '{{[^}]\+}}'

" ─── Include Lua syntax for script blocks ─────────────
" syn include redirects all lua.vim definitions into the @PosteLua cluster.
" Must unlet b:current_syntax because lua.vim has a guard that skips if set.
syn include @PosteLua syntax/lua.vim
unlet! b:current_syntax

" ─── External script reference ──────────────────────
syn match PosteExternalScript '<\s\+\./\S*\.lua\s*$'

" ─── File inclusion in body ─────────────────────────
" Defined before PreScript/Assertion so their more specific patterns win.
" Negative lookahead ({%)\@! excludes pre-request script blocks.
syn match PosteFileUpload '<\s\+\({%\)\@!\S\+'

" ─── Post-request script / assertion file references ───
syn match PosteFileRef '>\s\+\({%\)\@!\S\+'

" ─── Pre-request script blocks ──────────────────────
" Multi-line: < {% ... %}
syn region PostePreScript start='<\s*{%$' end='^%}'
  \ contains=PosteScriptMarker,PosteScriptAPI,@PosteLua keepend
" Single-line: < {% ... %}
syn match PostePreScript '<\s*{%.*%}'
  \ contains=PosteScriptMarker,PosteScriptAPI,@PosteLua

" ─── Assertion / post-request script blocks ─────────
" Multi-line: > {% ... %}
syn region PosteAssertion start='>\s*{%$' end='^%}'
  \ contains=PosteScriptMarker,PosteScriptAPI,@PosteLua keepend
" Single-line: > {% ... %}
syn match PosteAssertion '>\s*{%.*%}'
  \ contains=PosteScriptMarker,PosteScriptAPI,@PosteLua

" Script markers (contained in PreScript / Assertion regions)
syn match PosteScriptMarker '{%' contained
syn match PosteScriptMarker '%}' contained

" Script API keywords (contained in script regions)
syn match PosteScriptAPI 'client\.\%(test\|assert\|log\|global\.\%(set\|get\)\)' contained
syn match PosteScriptAPI 'response\.\%(status\|body\|headers\|latency_ms\|content_type\|url\)' contained
syn match PosteScriptAPI 'request\.\%(variables\.\%(set\|get\)\|headers\|body\)' contained
syn match PosteScriptAPI 'variables\.\w\+' contained
syn match PosteScriptAPI 'env\.\w\+' contained

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
syn match PosteMethodScript '^\s*[Ss][Cc][Rr][Ii][Pp][Tt]\ze\%(\s\|$\)'

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

" ─── Request body (payload after blank line) ──────────
" Body starts at a blank line (separating headers from body)
" and ends before the next ### separator, pre/post-script block, or at EOF.
" Manual JSON syntax avoids syn include's syn-clear side effect
" and lets {{var}} refs highlight inside JSON values.
syn region PosteBody start=+^\s*\n+ end=+\n\ze\s*\%(###\|<\s*{%\|>\s*{%\)\|\%$+ keepend
  \ contains=PosteJsonString,PosteJsonNumber,PosteJsonBoolean,PosteJsonNull,
  \PosteJsonBraces,PosteJsonBrackets,PosteJsonColon,PosteJsonComma,
  \PosteVarRef,PosteMagicVar,PosteVarDef,PosteVarAssign,PosteMultiVarEnd,
  \PostePrompt,PosteCommentedPrompt,PosteComment,
  \PosteImport,PosteRun,PosteFileUpload,PosteFileRef

syn match  PosteJsonNumber  '[-]\?\%(\d\+\.\d\+\|\d\+\)' contained
syn match  PosteJsonBoolean '\<\%(true\|false\)\>' contained
syn match  PosteJsonNull    '\<null\>' contained
syn match  PosteJsonBraces  '[{}]' contained
syn match  PosteJsonBrackets '[\[\]]' contained
syn match  PosteJsonColon   ':' contained
syn match  PosteJsonComma   ',' contained
syn region PosteJsonString  start=+"+ skip=+\\\\\|\\"+ end=+"+ contained
  \ contains=PosteJsonEscape,PosteVarRef,PosteMagicVar
syn match  PosteJsonEscape  '\\["\\/bfnrt]' contained
syn match  PosteJsonEscape  '\\u\x\{4}' contained

" ─── Highlight group links ──────────────────────────
hi def link PosteSeparator   Delimiter
hi def link PosteRequestName Title
hi def link PosteComment     Comment
hi def PosteVarDef      ctermfg=214 guifg=#FF8C00
hi def link PosteVarAssign   Operator
hi def link PosteVarValue    String
hi def link PosteMultiVarEnd String
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
hi def link PosteMethodScript Keyword
hi def link PosteUrl         Underlined
hi def link PosteHttpVersion Constant
hi def link PosteHeaderKey   Type
hi def link PosteHeaderSep   Delimiter
hi def link PosteImport       Include
hi def link PosteImportPath   String
hi def link PosteImportAliasOpt Operator
hi def link PosteImportAlias  Identifier
hi def PosteRun gui=bold guifg=#AA66FF cterm=bold ctermfg=141
hi def link PosteRunTarget String
hi def link PosteRunVarDef  PosteVarDef
hi def link PosteRunVarAssign Operator
hi def link PosteRunVarValue String
hi def link PostePrompt           PreProc
hi def link PostePromptMarker      Special
hi def link PostePromptOpts        String
hi def link PosteCommentedPrompt   Comment
hi def link PosteCommentedPromptMarker Comment
hi def link PostePreScript   PreProc
hi def link PosteAssertion   PreProc
hi def link PosteScriptMarker Special
hi def link PosteScriptAPI  Function
hi def link PosteExternalScript Include
hi def link PosteFileUpload Include
hi def link PosteJsonString  String
hi def link PosteJsonNumber  Number
hi def link PosteJsonBoolean Boolean
hi def link PosteJsonNull    Special
hi def link PosteJsonBraces  Delimiter
hi def link PosteJsonBrackets Delimiter
hi def link PosteJsonColon   Delimiter
hi def link PosteJsonComma   Delimiter
hi def link PosteJsonEscape  SpecialChar

let b:current_syntax = "poste_http"
