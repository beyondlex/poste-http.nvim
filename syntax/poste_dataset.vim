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

" ─── Cell text container ─────────────────────────────
" Matches entire cell content between │ separators. Acts as a container
" so that specific sub-patterns (numbers, bools, nulls) can overlay on top.
" WITHOUT contains=, Vim syntax would claim the entire match and prevent
" sub-patterns from matching inside it.
syn match PosteDatasetCellText '\(│\)\@<=[^│]\+\(│\)\@=' contains=PosteDatasetNull,PosteDatasetNumber,PosteDatasetBool

" ─── NULL values (contained within cell text) ───────
syn match PosteDatasetNull '(NULL)' contained

" ─── Numbers (right-aligned in cells, contained) ────
syn match PosteDatasetNumber '-\?\d\+\%(\.\d\+\)\?' contained

" ─── Boolean values (contained within cell text) ────
syn match PosteDatasetBool '\%(true\|false\)' contained

" ─── Meta line (bottom stats) ───────────────────────
syn match PosteDatasetMeta '^\d\+ row.*$'
syn match PosteDatasetMeta '^Page \d\+/\d\+.*$'
syn match PosteDatasetMeta '^Context switched.*$'
syn match PosteDatasetMeta '^\d\+ row.*affected.*$'

" ─── Highlight group links ──────────────────────────
" These link to PosteSql* groups which are set with explicit
" theme-aware colors in sql/highlights.lua setup().
hi def link PosteDatasetSep        PosteSqlSep
hi def link PosteDatasetBorder     PosteSqlBorder
hi def link PosteDatasetHeader     PosteSqlHeader
hi def link PosteDatasetCellText   PosteSqlCellText
hi def link PosteDatasetNull       PosteSqlNull
hi def link PosteDatasetNumber     PosteSqlNumber
hi def link PosteDatasetBool       PosteSqlBool
hi def link PosteDatasetMeta       PosteSqlMeta

let b:current_syntax = "poste_dataset"
