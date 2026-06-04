" Vim syntax file for Poste Dataset buffer (SQL result panel)
" Language: Poste Dataset (rendered table)
" Latest Revision: 2026-06-04

if exists("b:current_syntax")
  finish
endif

" ─── Table borders ───────────────────────────────────
" │ separator is shown with subtle highlighting (conceal breaks alignment).
syn match PosteDatasetSep '│'

" Box-drawing characters for borders
syn match PosteDatasetBorder '[┌┐└┘├┤┬┴┼─╞╡╤╧╪═║╔╗╚╝╠╣╦╩╬]'

" ─── Header row (first content row) ─────────────────
" Header is detected by the buffer module and highlighted via extmarks.
" This provides fallback syntax highlighting.
syn match PosteDatasetHeader '^\s*│[^│]*│[^│]*│.*$' contained

" ─── NULL values ────────────────────────────────────
syn match PosteDatasetNull '(NULL)'

" ─── Numbers (right-aligned in cells) ───────────────
syn match PosteDatasetNumber '\(│\s*\)\@<=-\?\d\+\%(\.\d\+\)\?\(\s*│\)\@='

" ─── Boolean values ─────────────────────────────────
syn match PosteDatasetBool '\(│\s*\)\@<=\%(true\|false\)\(\s*│\)\@='

" ─── Meta line (bottom stats) ───────────────────────
syn match PosteDatasetMeta '^\d\+ row.*$'
syn match PosteDatasetMeta '^Page \d\+/\d\+.*$'
syn match PosteDatasetMeta '^Context switched.*$'
syn match PosteDatasetMeta '^\d\+ row.*affected.*$'

" ─── Highlight group links ──────────────────────────
hi def link PosteDatasetSep     NonText
hi def link PosteDatasetBorder  Delimiter
hi def link PosteDatasetHeader  Title
hi def link PosteDatasetNull    Comment
hi def link PosteDatasetNumber  Number
hi def link PosteDatasetBool    Boolean
hi def link PosteDatasetMeta    Comment

let b:current_syntax = "poste_dataset"
