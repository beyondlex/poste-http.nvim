" Vim syntax file for Poste SQL request files (.sql, .sqlite)
" Language: Poste SQL request format
" Latest Revision: 2026-06-04

if exists("b:current_syntax")
  finish
endif

syn case ignore

" ─── Request separator + name ────────────────────────
syn region PosteSqlRequestName
  \ start='^###' end='$'
  \ contains=PosteSqlSeparator keepend
syn match PosteSqlSeparator '^###' contained

" ─── Directives (must be before comments) ────────────
syn match PosteSqlDirective
  \ '^\s*--\s*@\%(connection\|database\|protocol\)\s\+.*$'

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

" ─── SQL Keywords ───────────────────────────────────
syn keyword PosteSqlKeyword SELECT FROM WHERE AND OR NOT IN EXISTS
  \ BETWEEN LIKE ILIKE IS NULL TRUE FALSE AS
  \ JOIN INNER LEFT RIGHT OUTER FULL CROSS ON
  \ GROUP BY ORDER ASC DESC HAVING LIMIT OFFSET
  \ INSERT INTO VALUES UPDATE SET DELETE
  \ CREATE ALTER DROP TABLE INDEX VIEW SCHEMA DATABASE
  \ ADD COLUMN RENAME TO IF PRIMARY KEY FOREIGN REFERENCES
  \ UNIQUE DEFAULT CHECK CONSTRAINT CASCADE RESTRICT
  \ BEGIN COMMIT ROLLBACK TRANSACTION SAVEPOINT
  \ UNION INTERSECT EXCEPT ALL DISTINCT
  \ WITH RECURSIVE CASE WHEN THEN ELSE END
  \ CAST COALESCE NULLIF GREATEST LEAST
  \ COUNT SUM AVG MIN MAX
  \ CURRENT_TIMESTAMP CURRENT_DATE CURRENT_TIME
  \ RETURNING CONFLICT DO NOTHING
  \ EXPLAIN ANALYZE VERBOSE COSTS BUFFERS FORMAT
  \ TRUNCATE VACUUM REINDEX

" ─── SQL Functions ──────────────────────────────────
syn keyword PosteSqlFunction
  \ abs ceil ceiling floor round
  \ length char_length character_length
  \ lower upper trim ltrim rtrim
  \ substring replace position
  \ concat string_agg array_agg
  \ now date_trunc extract date_part
  \ to_char to_date to_timestamp to_number
  \ json_build_object json_build_array json_extract_path_text
  \ jsonb_build_object jsonb_build_array
  \ array_length unnest generate_series
  \ pg_typeof typeof

" ─── Data Types ─────────────────────────────────────
syn keyword PosteSqlType
  \ integer int bigint smallint serial bigserial
  \ varchar char text boolean bool
  \ numeric decimal real float double precision
  \ date time timestamp timestamptz interval
  \ bytea uuid json jsonb xml
  \ inet cidr macaddr
  \ point line polygon circle path box lseg
  \ array int4range int8range numrange tsrange tstzrange daterange

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
hi def link PosteSqlDirective   PreProc
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
