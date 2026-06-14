" Vim syntax file for Poste SQL request files (.sql, .sqlite)
" Language: Poste SQL request format
" Latest Revision: 2026-06-09

if exists("b:current_syntax")
  finish
endif

syn case ignore

" ─── Request separator + name ────────────────────────
syn region PosteSqlRequestName
  \ start='^###' end='$'
  \ contains=PosteSqlSeparator keepend
syn match PosteSqlSeparator '^###' contained

" ─── Directives (inside comments) ────────────
syn match PosteSqlDirective
  \ '@\%(connection\|database\|protocol\)'
  \ contained
  \ nextgroup=PosteSqlDirectiveValue skipwhite
syn match PosteSqlDirectiveValue '\S.*$' contained

" ─── Variable definitions: @name = value / @name value ──
syn match PosteSqlVarDef '^\s*@\w\+'
  \ nextgroup=PosteSqlVarAssign,PosteSqlVarValue skipwhite
syn match PosteSqlVarAssign '=' contained
  \ nextgroup=PosteSqlVarValue skipwhite
syn match PosteSqlVarValue '.\+$' contained

" ─── Variable references ────────────────────────────
syn match PosteSqlMagicVar '{{\$\w\+}}'
syn match PosteSqlVarRef '{{[^}]\+}}'

" ─── Comments ───────────────────────────────────────
syn match PosteSqlComment '--.*$' contains=PosteSqlDirective

" ─── SQL Keywords, Functions, Types ─────────────────
" NOTE: SQL keyword/function/type highlighting is handled by
" lua/poste/sql/syntax.lua (extmark-based). This ensures a single
" source of truth shared with the log viewer.
" Keep syn keyword lines here for Vim's synID-based motion/iskeyword,
" but they no longer define highlight groups.
syn keyword PosteSqlKeyword NONE_MATCH
syn keyword PosteSqlFunction NONE_MATCH
syn keyword PosteSqlType NONE_MATCH

" ─── Strings ────────────────────────────────────────
syn region PosteSqlString start="'" skip="''" end="'"
  \ contains=PosteSqlVarRef,PosteSqlMagicVar

" ─── Numbers ────────────────────────────────────────
syn match PosteSqlNumber '\<\d\+\%(\.\d\+\)\?\>'

" ─── Operators ──────────────────────────────────────
syn match PosteSqlOperator '[<>!=]=\?'
syn match PosteSqlOperator '[+*/%]'
syn match PosteSqlOperator '||'
syn match PosteSqlOperator '::'
syn match PosteSqlOperator '->>'
syn match PosteSqlOperator '->'
syn match PosteSqlOperator '@>'
syn match PosteSqlOperator '<@'

" ─── Highlight group links ──────────────────────────
hi def link PosteSqlSeparator   Delimiter
hi def link PosteSqlRequestName Title
hi def link PosteSqlComment     Comment
hi def PosteSqlDirective        guifg=#9B59B6 ctermfg=141 gui=bold
hi def PosteSqlDirectiveValue   guifg=#E5C07B ctermfg=180
hi def link PosteSqlVarDef      Identifier
hi def link PosteSqlVarAssign   Operator
hi def link PosteSqlVarValue    String
hi def link PosteSqlVarRef      Identifier
hi def link PosteSqlMagicVar    Special
hi def link PosteSqlKeyword     Keyword
hi def link PosteSqlFunction    Function
hi def link PosteSqlType        Type
hi def link PosteSqlString      String
hi def link PosteSqlNumber      Number
hi def link PosteSqlOperator    Operator

let b:current_syntax = "poste_sql"
