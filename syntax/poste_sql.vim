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
  \ CALL COPY EXECUTE PREPARE SHOW USE
  \ TABLES DATABASES SCHEMAS COLUMNS FIELDS
  \ FOR UPDATE SHARE OF
  \ NOWAIT SKIP LOCKED
  \ OVER PARTITION WINDOW FILTER
  \ COMMENT AFTER DESC

" ─── SQL Functions ──────────────────────────────────
syn keyword PosteSqlFunction
  \ abs ceil ceiling floor round truncate trunc div
  \ rand random power pow sqrt exp ln log log2 log10
  \ mod sign pi crc32
  \ sin cos tan asin acos atan atan2 radians degrees
  \ length char_length character_length octet_length bit_length
  \ lower upper trim ltrim rtrim
  \ substring replace position
  \ concat concat_ws format instr locate
  \ left right substr mid substring_index
  \ repeat reverse lpad rpad space
  \ field find_in_set elt soundex ascii ord char unicode
  \ unhex hex quote strcmp
  \ regexp_replace regexp_like regexp_substr regexp_instr
  \ greatest least coalesce nullif ifnull if
  \ count sum avg min max
  \ group_concat string_agg array_agg
  \ std stddev stddev_pop stddev_samp
  \ var_pop var_samp variance
  \ bit_and bit_or bit_xor
  \ row_number rank dense_rank ntile lag lead
  \ first_value last_value nth_value
  \ cume_dist percent_rank percentile_cont percentile_disc
  \ now sysdate localtime localtimestamp
  \ utc_date utc_time utc_timestamp
  \ curdate curtime
  \ year month day dayofmonth dayofweek dayofyear
  \ week weekday weekofyear
  \ hour minute second microsecond quarter last_day
  \ date_format time_format
  \ from_unixtime unixt_timestamp str_to_date
  \ to_days from_days
  \ date_add date_sub adddate subdate
  \ addtime subtime timediff timestampdiff timestampadd
  \ datediff extract date_part
  \ makedate maketime make_date make_time make_timestamp
  \ convert_tz date_trunc time_trunc
  \ age isfinite justify_days justify_hours justify_interval
  \ clock_timestamp statement_timestamp transaction_timestamp
  \ json_extract json_unquote json_keys json_contains
  \ json_contains_path json_set json_insert json_replace
  \ json_remove json_array json_object json_array_append
  \ json_merge json_merge_patch
  \ json_type json_valid json_depth json_length
  \ json_quote json_table json_value
  \ json_agg json_object_agg
  \ jsonb_build_object jsonb_agg jsonb_pretty jsonb_extract_path
  \ to_json row_to_json
  \ cast convert try_cast try_convert
  \ to_char to_number to_timestamp
  \ md5 sha1 sha2 aes_encrypt aes_decrypt
  \ random_bytes uuid uuid_short
  \ version database schema user
  \ session_user system_user connection_id
  \ row_count found_rows last_insert_id
  \ charset collation current_schema
  \ current_setting set_config
  \ match against
  \ unnest generate_series array row setseed
  \ any_value benchmark
  \ get_lock release_lock release_all_locks
  \ is_free_lock is_used_lock sleep
  \ total typeof likely unlikely likelihood
  \ changes total_changes
  \ sqlite_version sqlite_source_id zeroblob

" ─── Data Types ─────────────────────────────────────
syn keyword PosteSqlType
  \ integer int bigint smallint tinyint serial bigserial
  \ varchar char text boolean bool
  \ numeric decimal real float double precision
  \ date time datetime timestamp timestamptz interval
  \ bytea uuid json jsonb xml blob
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
