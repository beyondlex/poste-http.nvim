//! SQL context detection: tokenizer + cursor-based context analysis.
//!
//! Provides a position-aware SQL tokenizer and context detector for use
//! by the completion system. Unlike heuristic regex matching, this module
//! properly handles string/comment awareness, subquery nesting via paren
//! tracking, and schema-qualified identifiers.
//!
//! # Example
//!
//! ```rust
//! use poste_core::sql_context;
//!
//! let sql = "SELECT * FROM users WHERE users.";
//! // Cursor on the trailing dot (byte offset 31)
//! let result = sql_context::detect_context(sql, 31).unwrap();
//! assert_eq!(result.context_type, sql_context::ContextType::DotColumn {
//!     table: String::from("users"), schema: None
//! });
//! assert_eq!(result.tables[0].name, "users");
//! ```

mod functions;
mod tokenizer;
mod tables;

// Re-export for context detection code in this module and tests
pub(crate) use tokenizer::*;
pub(crate) use tables::extract_tables;

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// SQL dialect for dialect-aware function filtering.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum SqlDialect {
    /// No specific dialect — return all known functions.
    Generic,
    Postgres,
    MySql,
    Sqlite,
}

impl SqlDialect {
    pub fn name(&self) -> &str {
        match self {
            Self::Generic => "generic",
            Self::Postgres => "postgres",
            Self::MySql => "mysql",
            Self::Sqlite => "sqlite",
        }
    }
}

/// The detected completion context at a cursor position.
#[derive(Debug, Clone, PartialEq)]
pub enum ContextType {
    /// Suggest SQL keywords (the default).
    Keyword,
    /// Suggest table names (after FROM, JOIN, UPDATE, INTO, etc.).
    Table,
    /// Suggest column names from referenced tables.
    Column,
    /// After `table.` or `alias.` — suggest columns for that table.
    DotColumn { table: String, schema: Option<String> },
    /// After `schema.` in FROM/JOIN context — suggest tables for that schema.
    SchemaTable { schema: String },
    /// Inside INSERT INTO table(...) — suggest columns for insertion.
    InsertColumn { table: String },
    /// After `@connection` — suggest connection names.
    Connection,
    /// After `USE` — suggest database names.
    Database,
    /// Suggest data types (CREATE TABLE column definitions).
    DataType,
}

impl ContextType {
    /// Return the string name for use in Lua completion.
    pub fn name(&self) -> &str {
        match self {
            Self::Keyword => "keyword",
            Self::Table => "table",
            Self::Column => "column",
            Self::DotColumn { .. } => "dot_column",
            Self::SchemaTable { .. } => "schema_table",
            Self::InsertColumn { .. } => "insert_column",
            Self::Connection => "connection",
            Self::Database => "database",
            Self::DataType => "datatype",
        }
    }

    /// Return extra context data (table name for dot_column/insert_column).
    pub fn data(&self) -> Option<String> {
        match self {
            Self::DotColumn { table, .. } => Some(table.clone()),
            Self::SchemaTable { schema } => Some(schema.clone()),
            Self::InsertColumn { table } => Some(table.clone()),
            _ => None,
        }
    }
}

/// A table referenced in a SQL statement.
#[derive(Debug, Clone, PartialEq)]
pub struct TableRef {
    pub name: String,
    pub alias: Option<String>,
    pub schema: Option<String>,
}

/// Full context result for a cursor position.
#[derive(Debug, Clone, PartialEq)]
pub struct ContextResult {
    pub context_type: ContextType,
    /// The user's typing prefix (text of current identifier or empty string).
    pub prefix: String,
    /// All tables referenced in the current statement scope (deduplicated).
    pub tables: Vec<TableRef>,
    /// Known SQL function names for completion.
    pub functions: Vec<&'static str>,
    /// Whether the cursor is inside a string literal.
    pub in_string: bool,
    /// Whether the cursor is inside a comment.
    pub in_comment: bool,
}

// ---------------------------------------------------------------------------
// Context detection (main entry point)
// ---------------------------------------------------------------------------

/// Detect the completion context at a cursor position in SQL text.
///
/// `sql` — the SQL statement text (content of a `###` block).
/// `offset` — 0-based byte offset of the cursor within `sql`.
///
/// Returns `None` if the cursor is inside a string or comment (no meaningful
/// SQL completion is possible).
pub fn detect_context(sql: &str, offset: usize) -> Option<ContextResult> {
    detect_context_with_dialect(sql, offset, SqlDialect::Generic)
}

pub fn detect_context_with_dialect(sql: &str, offset: usize, dialect: SqlDialect) -> Option<ContextResult> {
    let tokens = tokenize(sql);
    if tokens.is_empty() {
        return Some(ContextResult {
            context_type: ContextType::Keyword,
            tables: vec![],
            prefix: String::new(),
            functions: functions::known_functions_for_dialect(dialect),
            in_string: false,
            in_comment: false,
        });
    }

    let cursor_idx_raw = find_token_at_offset(&tokens, offset).unwrap_or(0);
    // When cursor past found token's end, advance to next token (handles
    // trailing-whitespace cases where find_token_at_offset falls back)
    let cursor_idx = if cursor_idx_raw + 1 < tokens.len() && offset > tokens[cursor_idx_raw].end {
        cursor_idx_raw + 1
    } else {
        cursor_idx_raw
    };
    let cursor_tok = &tokens[cursor_idx];

    // Check for string/comment — return None (no SQL completion)
    let in_string = cursor_tok.kind == TokenKind::StrLit;
    let in_comment = matches!(cursor_tok.kind, TokenKind::LineComment | TokenKind::BlockComment);
    if in_string || in_comment {
        return None;
    }

    let prefix = extract_prefix(sql, offset, &tokens, cursor_idx);

    // Special cases: check for dot-notation at cursor
    if let Some(ctx) = try_dot_column(&tokens, cursor_idx, sql) {
        let tables = extract_tables(&tokens, sql);
        let funcs = functions::known_functions_for_dialect(dialect);
        return Some(ContextResult {
            context_type: ctx,
            tables,
            prefix,
            functions: funcs,
            in_string: false,
            in_comment: false,
        });
    }

    // Special cases: check for INSERT INTO table ( — InsertColumn
    if let Some(ctx) = try_insert_column(&tokens, cursor_idx, sql) {
        let tables = extract_tables(&tokens, sql);
        let funcs = functions::known_functions_for_dialect(dialect);
        return Some(ContextResult {
            context_type: ctx,
            tables,
            prefix,
            functions: funcs,
            in_string: false,
            in_comment: false,
        });
    }

    // Special cases: @connection / USE
    if let Some(ctx) = try_directive(&tokens, cursor_idx, sql) {
        let tables = extract_tables(&tokens, sql);
        let funcs = functions::known_functions_for_dialect(dialect);
        return Some(ContextResult {
            context_type: ctx,
            tables,
            prefix,
            functions: funcs,
            in_string: false,
            in_comment: false,
        });
    }

    // Special case: SHOW statement context
    if let Some(ctx) = try_show_statement(&tokens, cursor_idx, sql) {
        let tables = extract_tables(&tokens, sql);
        let funcs = functions::known_functions_for_dialect(dialect);
        return Some(ContextResult {
            context_type: ctx,
            tables,
            prefix,
            functions: funcs,
            in_string: false,
            in_comment: false,
        });
    }

    // Special case: GRANT/REVOKE ... ON → Table
    if let Some(ctx) = try_grant_revoke(&tokens, cursor_idx, sql) {
        let tables = extract_tables(&tokens, sql);
        let funcs = functions::known_functions_for_dialect(dialect);
        return Some(ContextResult {
            context_type: ctx,
            tables,
            prefix,
            functions: funcs,
            in_string: false,
            in_comment: false,
        });
    }

    // Special case: FOR UPDATE OF / FOR SHARE OF → Table
    if let Some(ctx) = try_for_update_of(&tokens, cursor_idx, sql) {
        let tables = extract_tables(&tokens, sql);
        let funcs = functions::known_functions_for_dialect(dialect);
        return Some(ContextResult {
            context_type: ctx,
            tables,
            prefix,
            functions: funcs,
            in_string: false,
            in_comment: false,
        });
    }

    // General case: scan backward for context keyword
    let cursor_on_ident = matches!(cursor_tok.kind,
        TokenKind::Ident | TokenKind::Keyword | TokenKind::NumLit | TokenKind::At);
    let context_type = detect_scan_backward(&tokens, cursor_idx, sql, cursor_on_ident);

    let tables = extract_tables(&tokens, sql);
    let functions = functions::known_functions_for_dialect(dialect);
    Some(ContextResult {
        context_type,
        tables,
        prefix,
        functions,
        in_string: false,
        in_comment: false,
    })
}

/// Try to detect a dot-column context: `table.` or `alias.` or `schema.table.`
/// Also detects schema-qualified table context: `schema.` after FROM/JOIN.
fn try_dot_column(tokens: &[Token], cursor_idx: usize, sql: &str) -> Option<ContextType> {
    // Check if the cursor is right after a dot
    // Case 1: cursor is on an Ident/Keyword after a dot → table.col
    // Case 2: cursor is after a dot (on whitespace or EOL) → table.
    let check_dot = |dot_idx: usize| -> Option<ContextType> {
        if dot_idx == 0 { return None; }
        let prev = dot_idx - 1;
        // Skip backward for whitespace
        let prev_idx = match tokens[prev].kind {
            TokenKind::Whitespace | TokenKind::LineComment | TokenKind::BlockComment => {
                skip_back(tokens, dot_idx)?
            }
            _ => prev,
        };

        // The token before the dot should be an identifier (table/alias/schema)
        let prev_tok = &tokens[prev_idx];
        match prev_tok.kind {
            TokenKind::Ident | TokenKind::QuotedIdent | TokenKind::Keyword => {
                let ident = prev_tok.text(sql).to_string();
                // Scan backward to check if we're in FROM/JOIN context — if so,
                // this dot is a namespace qualifier, not a column accessor.
                if let Some(ctx_kw_idx) = skip_back(tokens, prev_idx) {
                    if tokens[ctx_kw_idx].kind == TokenKind::Keyword {
                        let kw = tokens[ctx_kw_idx].text(sql).to_ascii_lowercase();
                        if is_table_keyword(&kw) {
                            return Some(ContextType::SchemaTable { schema: ident });
                        }
                    }
                }
                // Check for schema qualifier: schema.table.
                let mut schema = None;
                if let Some(before) = skip_back(tokens, prev_idx) {
                    if tokens[before].kind == TokenKind::Dot {
                        if let Some(schema_tok_idx) = skip_back(tokens, before) {
                            let schema_tok = &tokens[schema_tok_idx];
                            if matches!(schema_tok.kind, TokenKind::Ident | TokenKind::QuotedIdent) {
                                schema = Some(schema_tok.text(sql).to_string());
                            }
                        }
                    }
                }
                Some(ContextType::DotColumn { table: ident, schema })
            }
            _ => None,
        }
    };

    // Case: cursor token is a Dot → we're on the dot itself
    if tokens[cursor_idx].kind == TokenKind::Dot {
        return check_dot(cursor_idx);
    }

    // Case: token before cursor is a Dot
    if let Some(prev) = skip_back(tokens, cursor_idx) {
        if tokens[prev].kind == TokenKind::Dot {
            return check_dot(prev);
        }
    }

    None
}

/// Try to detect INSERT INTO table ( — InsertColumn context.
fn try_insert_column(tokens: &[Token], cursor_idx: usize, sql: &str) -> Option<ContextType> {
    // We need to find: INSERT INTO <table> LParen near the cursor
    // Scan backward from cursor for LParen
    let mut i = cursor_idx;

    // Handle RParen at cursor: cursor is after `()`, find the LParen
    if tokens[i].kind == TokenKind::RParen {
        if let Some(prev) = skip_back(tokens, i) {
            if tokens[prev].kind == TokenKind::LParen {
                i = prev;
            } else {
                // RParen with no immediately preceding LParen — walk backward
                let mut found_lparen = false;
                let mut j = i;
                loop {
                    match skip_back(tokens, j) {
                        Some(idx) => {
                            j = idx;
                            match tokens[idx].kind {
                                TokenKind::LParen => { i = idx; found_lparen = true; break; }
                                TokenKind::RParen => break,
                                _ => continue,
                            }
                        }
                        None => break,
                    }
                }
                if !found_lparen { return None; }
            }
        } else {
            return None;
        }
    }
    // If cursor is inside/after an LParen (or was adjusted from RParen), include it
    else if tokens[i].kind != TokenKind::LParen {
        // Check if previous token is LParen
        if let Some(prev) = skip_back(tokens, i) {
            if tokens[prev].kind == TokenKind::LParen {
                i = prev;
            } else {
                // Walk backward to find LParen or RParen
                let mut found_lparen = false;
                let mut j = i;
                loop {
                    match skip_back(tokens, j) {
                        Some(idx) => {
                            j = idx;
                            match tokens[idx].kind {
                                TokenKind::LParen => { found_lparen = true; i = idx; break; }
                                TokenKind::RParen => break,
                                _ => continue,
                            }
                        }
                        None => break,
                    }
                }
                if !found_lparen { return None; }
            }
        } else {
            return None;
        }
    }

    // Now i is at LParen. Scan backward: skip whitespace, find table name,
    // then INTO, then INSERT.
    // Also handles: COPY <table> ( and COPY table FROM/TO ...

    // Walk backward from LParen for table name
    if let Some(tbl_idx) = skip_back(tokens, i) {
        let tbl_tok = &tokens[tbl_idx];
        if !matches!(tbl_tok.kind, TokenKind::Ident | TokenKind::QuotedIdent | TokenKind::Keyword) {
            return None;
        }
        let table = tbl_tok.text(sql).to_string();

        // Walk back for INTO
        if let Some(into_idx) = skip_back(tokens, tbl_idx) {
            let into_tok = &tokens[into_idx];
            if into_tok.kind == TokenKind::Keyword && kw_eq(into_tok.text(sql), "into") {
                // Walk back for INSERT
                if let Some(insert_idx) = skip_back(tokens, into_idx) {
                    let insert_tok = &tokens[insert_idx];
                    if insert_tok.kind == TokenKind::Keyword && kw_eq(insert_tok.text(sql), "insert") {
                        return Some(ContextType::InsertColumn { table });
                    }
                }
            }
        }

        // Also handle COPY <table> (
        if let Some(prev_idx) = skip_back(tokens, tbl_idx) {
            let prev_tok = &tokens[prev_idx];
            if prev_tok.kind == TokenKind::Keyword && kw_eq(prev_tok.text(sql), "copy") {
                return Some(ContextType::InsertColumn { table });
            }
        }
    }

    None
}

/// Try to detect @connection and USE directive contexts.
fn try_directive(tokens: &[Token], cursor_idx: usize, sql: &str) -> Option<ContextType> {
    // Check for @connection or @database
    if tokens[cursor_idx].kind == TokenKind::At {
        let text = tokens[cursor_idx].text(sql);
        if kw_eq(text, "@connection") || kw_eq(text, "@database") {
            return Some(ContextType::Connection);
        }
    }

    // Also check if previous token is @
    if let Some(prev) = skip_back(tokens, cursor_idx) {
        if tokens[prev].kind == TokenKind::At {
            let text = tokens[prev].text(sql);
            if kw_eq(text, "@connection") || kw_eq(text, "@database") {
                return Some(ContextType::Connection);
            }
        }
    }

    // Check for USE statement
    if tokens[cursor_idx].kind == TokenKind::Keyword {
        if kw_eq(tokens[cursor_idx].text(sql), "use") {
            // Next non-whitespace token would be the database name
            if let Some(next) = skip_forward(tokens, cursor_idx) {
                if matches!(tokens[next].kind, TokenKind::Ident | TokenKind::QuotedIdent) {
                    // Already has a prefix
                    return Some(ContextType::Database);
                }
            } else {
                // At end of SQL text — suggest databases
                return Some(ContextType::Database);
            }
        }
    }

    // Check for USE statement: token after USE
    if let Some(prev) = skip_back(tokens, cursor_idx) {
        if tokens[prev].kind == TokenKind::Keyword {
            if kw_eq(tokens[prev].text(sql), "use") {
                return Some(ContextType::Database);
            }
        }
    }

    None
}

/// Try to detect SHOW statement context.
///
/// Handles:
/// - `SHOW TABLES ` → Table
/// - `SHOW DATABASES ` / `SHOW SCHEMAS ` → Database
/// - `SHOW COLUMNS FROM ` / `SHOW FIELDS FROM ` → Table
fn try_show_statement(tokens: &[Token], cursor_idx: usize, sql: &str) -> Option<ContextType> {
    // Walk backward from cursor to find SHOW keyword.
    // Skip the user's current typing prefix if on ident or keyword.
    let start = if matches!(tokens[cursor_idx].kind, TokenKind::Ident | TokenKind::Keyword) {
        skip_back(tokens, cursor_idx)?
    } else {
        cursor_idx
    };

    // Scan back to find SHOW
    let mut search = start;
    loop {
        if tokens[search].kind == TokenKind::Keyword && kw_eq(tokens[search].text(sql), "show") {
            break;
        }
        search = skip_back(tokens, search)?;
    }

    // Scan forward from SHOW to find what keyword follows
    let mut next = search;
    let mut show_type: Option<String> = None;

    loop {
        match skip_forward(tokens, next) {
            Some(idx) => {
                if idx > cursor_idx {
                    break;
                }
                match tokens[idx].kind {
                    TokenKind::Keyword | TokenKind::Ident => {
                        let text = tokens[idx].text(sql);
                        if let Some(ty) = show_type_keyword(text) {
                            show_type = Some(ty.to_string());
                        }
                    }
                    _ => {}
                }
                next = idx;
            }
            None => break,
        }
    }

    match show_type.as_deref() {
        Some("databases") | Some("schemas") => Some(ContextType::Database),
        Some("tables") => Some(ContextType::Table),
        Some("columns") | Some("fields") => Some(ContextType::Table),
        _ => None,
    }
}

/// Try to detect GRANT/REVOKE ... ON context — return Table for the object name.
fn try_grant_revoke(tokens: &[Token], cursor_idx: usize, sql: &str) -> Option<ContextType> {
    // Walk backward to find ON keyword
    let start = if matches!(tokens[cursor_idx].kind, TokenKind::Ident | TokenKind::Keyword) {
        skip_back(tokens, cursor_idx)?
    } else {
        cursor_idx
    };

    let mut search = start;
    loop {
        if tokens[search].kind == TokenKind::Keyword && kw_eq(tokens[search].text(sql), "on") {
            break;
        }
        if search == 0 {
            return None;
        }
        search = skip_back(tokens, search)?;
    }

    // Check if ON is preceded by GRANT or REVOKE (possibly with intervening tokens)
    // We need to scan further back — skip over privilege keywords (SELECT, INSERT, etc.)
    let mut before_on = search;
    loop {
        match skip_back(tokens, before_on) {
            Some(idx) => {
                let tok = &tokens[idx];
                match tok.kind {
                    TokenKind::Keyword => {
                        let kw = tok.text(sql).to_ascii_lowercase();
                        if kw == "grant" || kw == "revoke" {
                            return Some(ContextType::Table);
                        }
                        // Skip known privilege/grant keywords and identifiers
                        if kw == "on" {
                            return None; // nested ON — not our pattern
                        }
                        // Continue scanning for GRANT/REVOKE
                        before_on = idx;
                    }
                    TokenKind::Ident | TokenKind::Comma => {
                        before_on = idx;
                    }
                    _ => return None,
                }
            }
            None => return None,
        }
    }
}

/// Try to detect FOR UPDATE OF / FOR SHARE OF — return Table for the object name.
fn try_for_update_of(tokens: &[Token], cursor_idx: usize, sql: &str) -> Option<ContextType> {
    // Walk backward to find OF keyword
    let start = if matches!(tokens[cursor_idx].kind, TokenKind::Ident | TokenKind::Keyword) {
        skip_back(tokens, cursor_idx)?
    } else {
        cursor_idx
    };

    let mut search = start;
    loop {
        if tokens[search].kind == TokenKind::Keyword && kw_eq(tokens[search].text(sql), "of") {
            break;
        }
        if search == 0 {
            return None;
        }
        search = skip_back(tokens, search)?;
    }

    // Check if OF is preceded by UPDATE or SHARE
    let update_or_share = skip_back(tokens, search)?;
    if tokens[update_or_share].kind != TokenKind::Keyword {
        return None;
    }
    let kw = tokens[update_or_share].text(sql).to_ascii_lowercase();
    if kw != "update" && kw != "share" {
        return None;
    }

    // Check if UPDATE/SHARE is preceded by FOR
    let for_idx = skip_back(tokens, update_or_share)?;
    if tokens[for_idx].kind == TokenKind::Keyword && kw_eq(tokens[for_idx].text(sql), "for") {
        return Some(ContextType::Table);
    }

    None
}

/// Check if a word is a SHOW type keyword and return its normalized form.
fn show_type_keyword(w: &str) -> Option<&'static str> {
    let w = w.as_bytes();
    if w.len() < 4 || w.len() > 9 {
        return None;
    }
    let up = |b: u8| if b >= b'a' && b <= b'z' { b - 32 } else { b };
    let mut buf = [0u8; 9];
    for (i, &b) in w.iter().enumerate() {
        buf[i] = up(b);
    }
    match &buf[..w.len()] {
        b"TABLES" => Some("tables"),
        b"DATABASES" => Some("databases"),
        b"SCHEMAS" => Some("schemas"),
        b"COLUMNS" => Some("columns"),
        b"FIELDS" => Some("fields"),
        _ => None,
    }
}

/// Generic backward scan for context keyword.
fn detect_scan_backward(tokens: &[Token], cursor_idx: usize, sql: &str, cursor_on_ident: bool) -> ContextType {
    // Start from cursor, scan backward
    let mut i = cursor_idx;
    let mut after_comma = false;
    // Skip the first ident/num literal we encounter — it's the user's typing
    // prefix, not a context-determining token (e.g. "WHERE us" → skip "us" → find WHERE)
    let mut skip_one_ident = true;

    loop {
        let tok = &tokens[i];

        match tok.kind {
            TokenKind::Whitespace | TokenKind::LineComment | TokenKind::BlockComment => {
                // Skip, continue scanning
            }
            TokenKind::Comma => {
                // After a comma: scan further back for clause keyword
                after_comma = true;
            }
            TokenKind::Keyword => {
                let kw = tok.text(sql).to_ascii_lowercase();
                if is_table_keyword(&kw) {
                    // If we already skipped an ident (the table name), the
                    // table has been provided. If the user is still typing
                    // (has_prefix), suggest tables; otherwise keywords.
                    if !skip_one_ident {
                        if cursor_on_ident {
                            return ContextType::Table;
                        }
                        return ContextType::Keyword;
                    }
                    return ContextType::Table;
                }
                if is_column_keyword(&kw) {
                    // If we've already consumed a column expression (the
                    // user's typing prefix), the column has been specified.
                    // If the cursor is on the identifier (cursor_on_ident),
                    // return Column; otherwise Keyword — user needs AND/OR/IN/IS etc.
                    // Applies to clause-heading keywords: SELECT, WHERE, HAVING, RETURNING, AFTER.
                    if !skip_one_ident && (kw == "select" || kw == "where" || kw == "having" || kw == "returning" || kw == "after") {
                        if cursor_on_ident {
                            return ContextType::Column;
                        }
                        return ContextType::Keyword;
                    }
                    // Special handling for NOT: distinguish "WHERE col NOT " (→ Keyword)
                    // from "WHERE status IS NOT " (→ Column) and "WHERE NOT " (→ Column)
                    if kw == "not" {
                        if skip_one_ident {
                            if let Some(prev_idx) = skip_back(tokens, i) {
                                if tokens[prev_idx].kind == TokenKind::Ident {
                                    return ContextType::Keyword;
                                }
                            }
                            return ContextType::Column;
                        }
                        return ContextType::Keyword;
                    }
                    // ALL after SELECT → Column; UNION ALL → keep original Keyword
                    if kw == "all" && skip_one_ident {
                        if let Some(prev_idx) = skip_back(tokens, i) {
                            if tokens[prev_idx].kind == TokenKind::Keyword {
                                let prev_kw = tokens[prev_idx].text(sql).to_ascii_lowercase();
                                if prev_kw == "select" {
                                    return ContextType::Column;
                                }
                            }
                        }
                        return ContextType::Keyword;
                    }
                    return ContextType::Column;
                }
                // After ADD COLUMN column_name → DataType
                if kw == "column" && !skip_one_ident {
                    if let Some(prev) = skip_back(tokens, i) {
                        if tokens[prev].kind == TokenKind::Keyword && kw_eq(tokens[prev].text(sql), "add") {
                            return ContextType::DataType;
                        }
                    }
                }
                if after_comma {
                    // After comma, keep scanning for clause keyword
                    after_comma = false;
                    // Continue scanning
                } else {
                    // Found a keyword that's not a context marker — stop here
                    return ContextType::Keyword;
                }
            }
            TokenKind::Op => {
                // After a comma, an Op is part of a column expression
                // continuation (e.g., `SELECT *, `) — keep scanning
                // for the clause keyword rather than returning Keyword.
                if after_comma {
                    after_comma = false;
                } else if let Some(prev) = skip_back(tokens, i) {
                    if tokens[prev].kind == TokenKind::Keyword {
                        let kw = tokens[prev].text(sql).to_ascii_lowercase();
                        if is_column_keyword(&kw) || is_predicate_keyword(&kw) {
                            // SELECT * → `*` IS the column expression,
                            // user needs FROM/JOIN/WHERE, not more columns.
                            if kw == "select" {
                                return ContextType::Keyword;
                            }
                            return ContextType::Column;
                        }
                    }
                    return ContextType::Keyword;
                } else {
                    return ContextType::Keyword;
                }
            }
            TokenKind::LParen => {
                // Distinguish function-call parens from subquery/expression parens
                if let Some(prev) = skip_back(tokens, i) {
                    let prev_text = tokens[prev].text(sql).to_ascii_lowercase();
                    // IN/EXISTS (subquery) → Keyword
                    if prev_text == "in" || prev_text == "exists" {
                        return ContextType::Keyword;
                    }
                    // FROM/JOIN/UPDATE/INTO/TABLE (subquery start) → Keyword
                    if is_table_keyword(&prev_text) {
                        return ContextType::Keyword;
                    }
                    // Otherwise: function-call args, expression grouping → Column
                    return ContextType::Column;
                }
                return ContextType::Keyword;
            }
            TokenKind::Ident | TokenKind::NumLit => {
                // Skip the first identifier (user's typing prefix) to find the
                // clause keyword. For multiple consecutive identifiers
                // (e.g., "FROM users u" where "u" is the prefix), stop at the second.
                if after_comma {
                    after_comma = false;
                } else if skip_one_ident {
                    skip_one_ident = false;
                } else {
                    return ContextType::Keyword;
                }
            }
            TokenKind::RParen => {
                // Cursor is on a closing paren — structural (closes subquery,
                // function call, or expression). Continue scanning backward
                // to find the real context keyword.
            }
            _ => {
                // Dot, Semi, At, etc.
                if after_comma {
                    after_comma = false;
                } else {
                    return ContextType::Keyword;
                }
            }
        }

        if i == 0 { break; }
        i -= 1;
    }

    ContextType::Keyword
}

// ---------------------------------------------------------------------------
// Statement boundary detection (for indicator placement)
// ---------------------------------------------------------------------------

/// Find the statement boundaries (start line, end line) containing a cursor line.
///
/// Uses the tokenizer to properly handle `;` inside strings and comments.
/// Returns `(start_line, end_line)` as 0-based line indices, or `None` if
/// the cursor is outside any SQL content.
pub fn find_statement_span(lines: &[&str], cursor_line: usize) -> Option<(usize, usize)> {
    if lines.is_empty() || cursor_line >= lines.len() { return None; }
    let text = lines.join("\n");
    let tokens = tokenize(&text);
    if tokens.is_empty() { return None; }

    // Find the statement boundaries around cursor_line by walking the text
    // and noting where statements start and end.
    let line_offsets: Vec<usize> = {
        let mut offsets = Vec::with_capacity(lines.len() + 1);
        offsets.push(0);
        for l in lines {
            offsets.push(offsets.last().unwrap() + l.len() + 1); // +1 for \n
        }
        offsets.pop(); // remove trailing sentinel
        offsets.push(text.len());
        offsets
    };

    let cursor_start = line_offsets[cursor_line];

    // Find semi tokens that are not inside strings or comments
    let semi_positions: Vec<usize> = tokens.iter()
        .filter(|t| t.kind == TokenKind::Semi)
        .map(|t| t.start)
        .collect();

    // Find the start: last semi before cursor, or 0
    let stmt_start_byte = semi_positions.iter()
        .rev()
        .find(|&&pos| pos < cursor_start)
        .map(|&pos| {
            // Find the next non-blank line after the semi
            for (l, &off) in line_offsets.iter().enumerate() {
                if off > pos + 1 { return l; }
            }
            0
        })
        .unwrap_or(0);

    // Find the end: next semi at or after cursor, or last line
    let stmt_end_line = semi_positions.iter()
        .find(|&&pos| pos >= cursor_start)
        .and_then(|&pos| {
            for (l, &off) in line_offsets.iter().enumerate() {
                if off >= pos {
                    return Some(l - 1);
                }
            }
            None
        })
        .unwrap_or(lines.len() - 1);

    Some((stmt_start_byte, stmt_end_line))
}

// ---------------------------------------------------------------------------
// Tests — comprehensive real-world SQL scenarios
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    // ---- Tokenizer ----

    #[test]
    fn test_tokenize_basic() {
        let tokens = tokenize("SELECT * FROM users WHERE id = 1");
        assert!(!tokens.is_empty());
        let src = "SELECT * FROM users WHERE id = 1";
        assert!(tokens.iter().any(|t| t.kind == TokenKind::Keyword && t.text(src) == "SELECT"));
        assert!(tokens.iter().any(|t| t.kind == TokenKind::Keyword && t.text(src) == "FROM"));
        assert!(tokens.iter().any(|t| t.kind == TokenKind::Keyword && t.text(src) == "WHERE"));
        assert!(tokens.iter().any(|t| matches!(t.kind, TokenKind::Ident) && t.text(src) == "users"));
    }

    #[test]
    fn test_tokenize_string_with_semicolon() {
        let tokens = tokenize("SELECT 'hello;world'");
        assert!(!tokens.iter().any(|t| t.kind == TokenKind::Semi));
        assert!(tokens.iter().any(|t| t.kind == TokenKind::StrLit));
    }

    #[test]
    fn test_tokenize_escaped_quotes() {
        let tokens = tokenize("SELECT 'it''s; a test'");
        assert!(!tokens.iter().any(|t| t.kind == TokenKind::Semi));
        assert!(tokens.iter().any(|t| t.kind == TokenKind::StrLit));
    }

    #[test]
    fn test_tokenize_line_comment() {
        let tokens = tokenize("SELECT 1; -- comment with ;\nSELECT 2");
        let semis: Vec<_> = tokens.iter().filter(|t| t.kind == TokenKind::Semi).collect();
        assert_eq!(semis.len(), 1);
        assert!(tokens.iter().any(|t| t.kind == TokenKind::LineComment));
    }

    #[test]
    fn test_tokenize_block_comment() {
        let tokens = tokenize("SELECT /* ; */ 1");
        assert!(!tokens.iter().any(|t| t.kind == TokenKind::Semi));
        assert!(tokens.iter().any(|t| t.kind == TokenKind::BlockComment));
    }

    #[test]
    fn test_tokenize_hyphenated_identifier() {
        let tokens = tokenize("SELECT * FROM posts-web_vitals");
        let src = "SELECT * FROM posts-web_vitals";
        assert!(tokens.iter().any(|t| matches!(t.kind, TokenKind::Ident) && t.text(src) == "posts-web_vitals"));
    }

    #[test]
    fn test_tokenize_subtraction_operator() {
        let tokens = tokenize("x - 1");
        let src = "x - 1";
        assert!(tokens.iter().any(|t| t.kind == TokenKind::Ident && t.text(src) == "x"));
        assert!(tokens.iter().any(|t| t.kind == TokenKind::Op && t.text(src) == "-"));
        assert!(tokens.iter().any(|t| t.kind == TokenKind::NumLit && t.text(src) == "1"));
    }

    #[test]
    fn test_tokenize_inline_block_comment() {
        let tokens = tokenize("SELECT /* inline */ col FROM t");
        assert!(tokens.iter().any(|t| t.kind == TokenKind::BlockComment));
        let src = "SELECT /* inline */ col FROM t";
        assert!(tokens.iter().any(|t| matches!(t.kind, TokenKind::Ident) && t.text(src) == "col"));
    }

    #[test]
    fn test_tokenize_multiple_block_comments() {
        let tokens = tokenize("SELECT /* a */ 1 /* b */ WHERE");
        let src = "SELECT /* a */ 1 /* b */ WHERE";
        assert_eq!(tokens.iter().filter(|t| t.kind == TokenKind::BlockComment).count(), 2);
        assert!(tokens.iter().any(|t| t.kind == TokenKind::Keyword && t.text(src) == "WHERE"));
    }

    #[test]
    fn test_tokenize_adjacent_block_comments() {
        let tokens = tokenize("SELECT /**/1/**/FROM t");
        let src = "SELECT /**/1/**/FROM t";
        assert_eq!(tokens.iter().filter(|t| t.kind == TokenKind::BlockComment).count(), 2);
        assert!(tokens.iter().any(|t| t.kind == TokenKind::Keyword && t.text(src) == "FROM"));
    }

    // ---- Context detection: basic DML ----

    #[test]
    fn test_detect_keyword_by_default() {
        let result = detect_context("", 0).unwrap();
        assert_eq!(result.context_type, ContextType::Keyword);
    }

    #[test]
    fn test_detect_table_after_from() {
        let result = detect_context("SELECT * FROM ", 14).unwrap();
        assert_eq!(result.context_type, ContextType::Table);
    }

    #[test]
    fn test_detect_table_after_join() {
        let result = detect_context("SELECT * FROM users JOIN ", 25).unwrap();
        assert_eq!(result.context_type, ContextType::Table);
    }

    #[test]
    fn test_detect_column_after_where() {
        let result = detect_context("SELECT * FROM users WHERE ", 25).unwrap();
        assert_eq!(result.context_type, ContextType::Column);
    }

    #[test]
    fn test_detect_on_column() {
        let result = detect_context("SELECT * FROM users u JOIN posts p ON ", 39).unwrap();
        assert_eq!(result.context_type, ContextType::Column);
    }

    #[test]
    fn test_detect_and_column() {
        let result = detect_context("SELECT * FROM users WHERE id = 1 AND ", 37).unwrap();
        assert_eq!(result.context_type, ContextType::Column);
    }

    #[test]
    fn test_detect_where_id_completed_keyword() {
        let result = detect_context("SELECT * FROM users WHERE id ", 29).unwrap();
        assert_eq!(result.context_type, ContextType::Keyword);
    }

    #[test]
    fn test_detect_having_col_completed_keyword() {
        let result = detect_context("SELECT id, COUNT(*) FROM users GROUP BY id HAVING cnt ", 56).unwrap();
        assert_eq!(result.context_type, ContextType::Keyword);
    }

    #[test]
    fn test_detect_comma_after_column() {
        let result = detect_context("SELECT id, name, ", 17).unwrap();
        assert_eq!(result.context_type, ContextType::Column);
    }

    #[test]
    fn test_detect_inside_string_returns_none() {
        let result = detect_context("SELECT 'hello world'", 10);
        assert!(result.is_none(), "cursor inside string should return None");
    }

    #[test]
    fn test_detect_comment_where_triggers_none() {
        let result = detect_context("-- WHERE ", 9);
        assert!(result.is_none(), "cursor in line comment should return None");
    }

    #[test]
    fn test_detect_comment_from_triggers_none() {
        let result = detect_context("-- FROM ", 8);
        assert!(result.is_none(), "cursor in line comment should return None");
    }

    #[test]
    fn test_detect_connection_directive() {
        let result = detect_context("@connection ", 12).unwrap();
        assert_eq!(result.context_type, ContextType::Connection);
    }

    #[test]
    fn test_detect_use_database() {
        let result = detect_context("USE ", 4).unwrap();
        assert_eq!(result.context_type, ContextType::Database);
    }

    #[test]
    fn test_edge_use_prefix() {
        let result = detect_context("USE mydb", 8).unwrap();
        assert_eq!(result.context_type, ContextType::Database);
    }

    // ---- Dot-column ----

    #[test]
    fn test_detect_dot_column() {
        let result = detect_context("SELECT users.", 13).unwrap();
        assert_eq!(result.context_type, ContextType::DotColumn { table: "users".into(), schema: None });
    }

    #[test]
    fn test_detect_dot_column_alias() {
        let result = detect_context("SELECT * FROM users u WHERE u.", 29).unwrap();
        assert_eq!(result.context_type, ContextType::DotColumn { table: "u".into(), schema: None });
    }

    #[test]
    fn test_detect_dot_column_alias_in_select() {
        let sql = "SELECT p.*, a. from posts p LEFT JOIN authors a on a.id = p.author_id;";
        let result = detect_context(sql, 14).unwrap();
        assert_eq!(result.context_type, ContextType::DotColumn { table: "a".into(), schema: None });
        assert!(result.tables.iter().any(|t| t.name == "authors" && t.alias == Some("a".into())));
        assert!(result.tables.iter().any(|t| t.name == "posts" && t.alias == Some("p".into())));
    }

    #[test]
    fn test_detect_dot_column_schema_qualified() {
        let result = detect_context("SELECT auth.users.", 18).unwrap();
        assert_eq!(result.context_type, ContextType::DotColumn { table: "users".into(), schema: Some("auth".into()) });
    }

    #[test]
    fn test_detect_dot_column_schema_qualified_alias() {
        let result = detect_context("SELECT * FROM public.users u WHERE u.", 38).unwrap();
        assert_eq!(result.context_type, ContextType::DotColumn { table: "u".into(), schema: None });
        assert!(result.tables.iter().any(|t| {
            t.name == "users" && t.alias == Some("u".into()) && t.schema == Some("public".into())
        }));
    }

    #[test]
    fn test_detect_dot_column_schema_qualified_bare_table() {
        let result = detect_context("SELECT * FROM auth.users WHERE users.", 39).unwrap();
        assert_eq!(result.context_type, ContextType::DotColumn { table: "users".into(), schema: None });
        assert!(result.tables.iter().any(|t| t.name == "users" && t.schema == Some("auth".into())));
    }

    #[test]
    fn test_detect_schema_table_after_from_dot() {
        let result = detect_context("SELECT * FROM inventory.", 24).unwrap();
        assert_eq!(result.context_type, ContextType::SchemaTable { schema: "inventory".into() });
    }

    #[test]
    fn test_detect_schema_table_with_prefix() {
        let result = detect_context("SELECT * FROM inventory.us", 27).unwrap();
        assert_eq!(result.context_type, ContextType::SchemaTable { schema: "inventory".into() });
        assert_eq!(result.prefix, "us");
    }

    #[test]
    fn test_detect_schema_table_after_join_dot() {
        let result = detect_context("SELECT * FROM t JOIN inventory.", 32).unwrap();
        assert_eq!(result.context_type, ContextType::SchemaTable { schema: "inventory".into() });
    }

    #[test]
    fn test_detect_column_with_schema_qualified_table() {
        let result = detect_context("SELECT * FROM auth.users WHERE ", 31).unwrap();
        assert_eq!(result.context_type, ContextType::Column);
        assert!(result.tables.iter().any(|t| {
            t.name == "users" && t.schema == Some("auth".into())
        }));
    }

    #[test]
    fn test_detect_multi_schema_tables() {
        let result = detect_context(
            "SELECT * FROM public.users JOIN auth.users ON public.users.id = auth.users.user_id WHERE ",
            88,
        ).unwrap();
        assert_eq!(result.context_type, ContextType::Column);
        assert!(result.tables.iter().any(|t| t.name == "users" && t.schema == Some("public".into())));
        assert!(result.tables.iter().any(|t| t.name == "users" && t.schema == Some("auth".into())));
    }

    // ---- INSERT column ----

    #[test]
    fn test_detect_insert_column() {
        let result = detect_context("INSERT INTO users (", 19).unwrap();
        assert_eq!(result.context_type, ContextType::InsertColumn { table: "users".into() });
    }

    #[test]
    fn test_detect_insert_column_open_paren() {
        let result = detect_context("INSERT INTO posts ()", 18).unwrap();
        assert_eq!(result.context_type, ContextType::InsertColumn { table: "posts".into() });
    }

    #[test]
    fn test_detect_insert_column_closed_paren() {
        let result = detect_context("INSERT INTO posts ()", 19).unwrap();
        assert_eq!(result.context_type, ContextType::InsertColumn { table: "posts".into() });
    }

    #[test]
    fn test_detect_insert_column_after_paren() {
        let result = detect_context("INSERT INTO posts ()", 20).unwrap();
        assert_eq!(result.context_type, ContextType::InsertColumn { table: "posts".into() });
    }

    // ---- Various clause contexts ----

    #[test]
    fn test_detect_updates_set_column() {
        let result = detect_context("UPDATE users SET ", 17).unwrap();
        assert_eq!(result.context_type, ContextType::Column);
    }

    #[test]
    fn test_edge_delete_from() {
        let result = detect_context("DELETE FROM ", 12).unwrap();
        assert_eq!(result.context_type, ContextType::Table);
    }

    #[test]
    fn test_edge_having() {
        let result = detect_context("SELECT id, COUNT(*) FROM users GROUP BY id HAVING ", 47).unwrap();
        assert_eq!(result.context_type, ContextType::Column);
    }

    #[test]
    fn test_edge_order_by() {
        let result = detect_context("SELECT * FROM users ORDER BY ", 30).unwrap();
        assert_eq!(result.context_type, ContextType::Column);
    }

    #[test]
    fn test_detect_where_in_values() {
        let result = detect_context("SELECT * FROM users WHERE id IN (1, 2, ", 41).unwrap();
        assert_eq!(result.context_type, ContextType::Keyword);
    }

    #[test]
    fn test_detect_where_between() {
        let result = detect_context("SELECT * FROM users WHERE id BETWEEN ", 40).unwrap();
        assert_eq!(result.context_type, ContextType::Keyword);
    }

    #[test]
    fn test_detect_where_not_between() {
        let result = detect_context("SELECT * FROM users WHERE id NOT BETWEEN ", 44).unwrap();
        assert_eq!(result.context_type, ContextType::Keyword);
    }

    #[test]
    fn test_detect_where_between_and() {
        let result = detect_context("SELECT * FROM users WHERE id BETWEEN 1 AND ", 46).unwrap();
        assert_eq!(result.context_type, ContextType::Column,
            "AND after BETWEEN should suggest columns");
    }

    #[test]
    fn test_detect_where_like() {
        let result = detect_context("SELECT * FROM users WHERE name LIKE ", 37).unwrap();
        assert_eq!(result.context_type, ContextType::Keyword);
    }

    #[test]
    fn test_detect_where_not_like() {
        let result = detect_context("SELECT * FROM users WHERE name NOT LIKE ", 41).unwrap();
        assert_eq!(result.context_type, ContextType::Keyword);
    }

    #[test]
    fn test_detect_where_is_null() {
        let result = detect_context("SELECT * FROM users WHERE status IS ", 37).unwrap();
        assert_eq!(result.context_type, ContextType::Keyword);
    }

    #[test]
    fn test_detect_where_not_keyword() {
        let result = detect_context("SELECT * FROM users WHERE id NOT ", 34).unwrap();
        assert_eq!(result.context_type, ContextType::Keyword,
            "NOT after column should suggest IN/LIKE/BETWEEN/IS");
    }

    #[test]
    fn test_detect_where_is_not_null_column() {
        let result = detect_context("SELECT * FROM users WHERE status IS NOT ", 41).unwrap();
        assert_eq!(result.context_type, ContextType::Column,
            "IS NOT should suggest NULL/columns");
    }

#[test]
    fn test_detect_where_not_exists_keyword() {
        let result = detect_context("SELECT * FROM users WHERE NOT ", 30).unwrap();
        assert_eq!(result.context_type, ContextType::Column,
            "WHERE NOT should suggest columns");
    }

    #[test]
    fn test_detect_where_eq_column() {
        // WHERE col = should suggest AND/OR/ORDER BY (keyword), not column
        let result = detect_context("SELECT * FROM users WHERE id = ", 34).unwrap();
        assert_eq!(result.context_type, ContextType::Keyword,
            "WHERE col = should suggest keyword (AND/OR/ORDER BY)");
    }

    #[test]
    fn test_detect_where_gt_column() {
        // WHERE col > should suggest keyword
        let result = detect_context("SELECT * FROM users WHERE age > ", 35).unwrap();
        assert_eq!(result.context_type, ContextType::Keyword,
            "WHERE col > should suggest keyword");
    }

    // ---- DDL ----

    #[test]
    fn test_detect_create_index() {
        let result = detect_context("CREATE INDEX ", 13).unwrap();
        assert_eq!(result.context_type, ContextType::Keyword);
    }

    #[test]
    fn test_detect_drop_index() {
        let result = detect_context("DROP INDEX ", 11).unwrap();
        assert_eq!(result.context_type, ContextType::Keyword);
    }

    #[test]
    fn test_detect_create_view() {
        let result = detect_context("CREATE VIEW ", 12).unwrap();
        assert_eq!(result.context_type, ContextType::Keyword);
    }

    #[test]
    fn test_edge_create_table() {
        let result = detect_context("CREATE TABLE ", 13).unwrap();
        assert_eq!(result.context_type, ContextType::Table);
    }

    #[test]
    fn test_detect_alter_table() {
        let result = detect_context("ALTER TABLE ", 12).unwrap();
        assert_eq!(result.context_type, ContextType::Table);
    }

    #[test]
    fn test_detect_alter_table_add_column_datatype() {
        let result = detect_context("ALTER TABLE users ADD COLUMN age ", 33).unwrap();
        assert_eq!(result.context_type, ContextType::DataType,
            "After ADD COLUMN col_name should suggest data types");
    }

    #[test]
    fn test_detect_drop_table() {
        let result = detect_context("DROP TABLE ", 11).unwrap();
        assert_eq!(result.context_type, ContextType::Table);
    }

    #[test]
    fn test_detect_truncate_table() {
        let result = detect_context("TRUNCATE TABLE ", 15).unwrap();
        assert_eq!(result.context_type, ContextType::Table);
    }

    // ---- Window functions ----

    #[test]
    fn test_detect_over_keyword() {
        let result = detect_context("SELECT RANK() OVER ", 19).unwrap();
        assert_eq!(result.context_type, ContextType::Keyword);
    }

    #[test]
    fn test_detect_window_partition_by() {
        let result = detect_context("SELECT RANK() OVER (PARTITION BY ", 33).unwrap();
        assert_eq!(result.context_type, ContextType::Column);
    }

    #[test]
    fn test_detect_window_partition_by_with_prefix() {
        let result = detect_context(
            "SELECT RANK() OVER (PARTITION BY dep", 34).unwrap();
        assert_eq!(result.context_type, ContextType::Column);
    }

    #[test]
    fn test_detect_window_order_by() {
        let result = detect_context("SELECT RANK() OVER (ORDER BY ", 29).unwrap();
        assert_eq!(result.context_type, ContextType::Column);
    }

    // ---- Set operations ----

    #[test]
    fn test_detect_union() {
        let result = detect_context("SELECT id FROM users UNION ", 27).unwrap();
        assert_eq!(result.context_type, ContextType::Keyword);
    }

    #[test]
    fn test_detect_union_all() {
        let result = detect_context("SELECT id FROM users UNION ALL ", 31).unwrap();
        assert_eq!(result.context_type, ContextType::Keyword);
    }

    #[test]
    fn test_detect_intersect() {
        let result = detect_context("SELECT id FROM users INTERSECT ", 31).unwrap();
        assert_eq!(result.context_type, ContextType::Keyword);
    }

    #[test]
    fn test_detect_except() {
        let result = detect_context("SELECT id FROM users EXCEPT ", 28).unwrap();
        assert_eq!(result.context_type, ContextType::Keyword);
    }

    // ---- CASE / functions ----

    #[test]
    fn test_detect_case_when() {
        // CURRENT: WHEN is not in COLUMN_CTX → Keyword. Ideal: Column.
        let result = detect_context("SELECT CASE WHEN ", 16).unwrap();
        assert_eq!(result.context_type, ContextType::Keyword);
    }

    #[test]
    fn test_detect_case_then() {
        let result = detect_context("SELECT CASE WHEN id = 1 THEN ", 28).unwrap();
        assert_eq!(result.context_type, ContextType::Keyword);
    }

    #[test]
    fn test_detect_case_else() {
        let result = detect_context("SELECT CASE WHEN id = 1 THEN 'a' ELSE ", 38).unwrap();
        assert_eq!(result.context_type, ContextType::Keyword);
    }

    // ---- Function call parens — should suggest Column ----

    #[test]
    fn test_detect_function_paren_coalesce() {
        let result = detect_context("SELECT COALESCE(", 16).unwrap();
        assert_eq!(result.context_type, ContextType::Column,
            "COALESCE( is a function call → Column");
    }

    #[test]
    fn test_detect_function_paren_from_unixtime() {
        let result = detect_context("SELECT FROM_UNIXTIME(", 21).unwrap();
        assert_eq!(result.context_type, ContextType::Column,
            "FROM_UNIXTIME( is a function call → Column");
    }

    #[test]
    fn test_detect_function_paren_concat() {
        let result = detect_context("SELECT CONCAT(", 14).unwrap();
        assert_eq!(result.context_type, ContextType::Column,
            "CONCAT( is a function call → Column");
    }

    #[test]
    fn test_detect_function_paren_nested() {
        let result = detect_context("SELECT ROUND(AVG(", 17).unwrap();
        assert_eq!(result.context_type, ContextType::Column,
            "Nested function call AVG( → Column");
    }

    #[test]
    fn test_detect_function_paren_after_comma() {
        let result = detect_context("SELECT COALESCE(col1, ", 22).unwrap();
        assert_eq!(result.context_type, ContextType::Column,
            "Inside COALESCE( after comma → Column");
    }

    #[test]
    fn test_detect_function_paren_with_tables() {
        let result = detect_context(
            "SELECT COALESCE(col1, col2) FROM users WHERE COALESCE(", 53).unwrap();
        assert_eq!(result.context_type, ContextType::Column,
            "COALESCE( in WHERE should suggest columns");
        assert!(result.tables.iter().any(|t| t.name == "users"),
            "Tables should include 'users' from outer query");
    }

    #[test]
    fn test_detect_where_paren_expression() {
        let result = detect_context("SELECT * FROM users WHERE (", 27).unwrap();
        assert_eq!(result.context_type, ContextType::Column,
            "WHERE ( is expression grouping → Column");
    }

    #[test]
    fn test_detect_and_paren_expression() {
        let result = detect_context("SELECT * FROM users WHERE id = 1 AND (", 38).unwrap();
        assert_eq!(result.context_type, ContextType::Column,
            "AND ( is expression grouping → Column");
    }

    #[test]
    fn test_detect_subquery_paren_after_from() {
        let result = detect_context("SELECT * FROM (", 15).unwrap();
        assert_eq!(result.context_type, ContextType::Keyword,
            "FROM ( is subquery start → Keyword");
    }

    #[test]
    fn test_detect_subquery_paren_after_in() {
        let result = detect_context("SELECT * FROM users WHERE id IN (", 34).unwrap();
        assert_eq!(result.context_type, ContextType::Keyword,
            "IN ( is subquery → Keyword");
    }

    #[test]
    fn test_detect_subquery_paren_after_exists() {
        let result = detect_context("SELECT * FROM users WHERE EXISTS (", 35).unwrap();
        assert_eq!(result.context_type, ContextType::Keyword,
            "EXISTS ( is subquery → Keyword");
    }

    #[test]
    fn test_detect_coalesce() {
        let result = detect_context("SELECT COALESCE(", 16).unwrap();
        assert_eq!(result.context_type, ContextType::Column);
    }

    #[test]
    fn test_detect_nullif() {
        let result = detect_context("SELECT NULLIF(", 14).unwrap();
        assert_eq!(result.context_type, ContextType::Column);
    }

    #[test]
    fn test_detect_count() {
        let result = detect_context("SELECT COUNT(", 13).unwrap();
        assert_eq!(result.context_type, ContextType::Column);
    }

    #[test]
    fn test_detect_avg() {
        let result = detect_context("SELECT AVG(", 11).unwrap();
        assert_eq!(result.context_type, ContextType::Column);
    }

    #[test]
    fn test_detect_sum() {
        let result = detect_context("SELECT SUM(", 11).unwrap();
        assert_eq!(result.context_type, ContextType::Column);
    }

    #[test]
    fn test_detect_extract() {
        let result = detect_context("SELECT EXTRACT(", 15).unwrap();
        assert_eq!(result.context_type, ContextType::Column);
    }

    #[test]
    fn test_detect_concat() {
        let result = detect_context("SELECT CONCAT(", 14).unwrap();
        assert_eq!(result.context_type, ContextType::Column);
    }

    #[test]
    fn test_detect_substring() {
        let result = detect_context("SELECT SUBSTRING(", 17).unwrap();
        assert_eq!(result.context_type, ContextType::Column);
    }

    #[test]
    fn test_detect_cast_as() {
        let result = detect_context("SELECT CAST(", 12).unwrap();
        assert_eq!(result.context_type, ContextType::Column);
    }

    // ---- RETURNING / ON CONFLICT ----

    #[test]
    fn test_detect_returning() {
        let result = detect_context("DELETE FROM users WHERE id = 1 RETURNING ", 42).unwrap();
        assert_eq!(result.context_type, ContextType::Column,
            "RETURNING should suggest columns");
    }

    #[test]
    fn test_detect_on_conflict_do_update_set() {
        let result = detect_context(
            "INSERT INTO users (id) VALUES (1) ON CONFLICT (id) DO UPDATE SET ", 62).unwrap();
        assert_eq!(result.context_type, ContextType::Column,
            "ON CONFLICT DO UPDATE SET should suggest columns");
    }

    #[test]
    fn test_detect_insert_on_conflict() {
        let result = detect_context("INSERT INTO users VALUES (1) ON CONFLICT DO NOTHING", 54).unwrap();
        assert_eq!(result.context_type, ContextType::Keyword);
    }

    // ---- Transaction / Misc ----

    #[test]
    fn test_detect_begin_keyword() {
        let result = detect_context("BEGIN ", 6).unwrap();
        assert_eq!(result.context_type, ContextType::Keyword);
    }

    #[test]
    fn test_detect_dialect_functions_pg() {
        // PG dialect should exclude MySQL-only functions
        let result = detect_context_with_dialect("SELECT * FROM users WHERE ", 26,
            SqlDialect::Postgres).unwrap();
        for f in &result.functions {
            assert_ne!(*f, "CRC32", "PG should not include CRC32");
        }
        assert!(result.functions.contains(&"STRING_AGG"), "PG should include STRING_AGG");
        assert!(result.functions.contains(&"COUNT"), "PG should include COUNT");
    }

    #[test]
    fn test_detect_dialect_functions_mysql() {
        let result = detect_context_with_dialect("SELECT * FROM users WHERE ", 26,
            SqlDialect::MySql).unwrap();
        for f in &result.functions {
            assert_ne!(*f, "STRING_AGG", "MySQL should not include STRING_AGG");
        }
        assert!(result.functions.contains(&"CRC32"), "MySQL should include CRC32");
        assert!(result.functions.contains(&"COUNT"), "MySQL should include COUNT");
    }

    #[test]
    fn test_detect_dialect_functions_unknown_defaults_all() {
        // Default detect_context should use Generic = all
        let result = detect_context("SELECT * FROM users WHERE ", 26).unwrap();
        assert!(result.functions.contains(&"CRC32"), "Default should include all functions");
        assert!(result.functions.contains(&"STRING_AGG"), "Default should include all functions");
    }

    #[test]
    fn test_detect_commit_keyword() {
        let result = detect_context("COMMIT ", 7).unwrap();
        assert_eq!(result.context_type, ContextType::Keyword);
    }

    #[test]
    fn test_detect_rollback_keyword() {
        let result = detect_context("ROLLBACK ", 9).unwrap();
        assert_eq!(result.context_type, ContextType::Keyword);
    }

    #[test]
    fn test_detect_savepoint() {
        let result = detect_context("SAVEPOINT ", 10).unwrap();
        assert_eq!(result.context_type, ContextType::Keyword);
    }

    #[test]
    fn test_detect_explain() {
        let result = detect_context("EXPLAIN ", 8).unwrap();
        assert_eq!(result.context_type, ContextType::Keyword);
    }

    #[test]
    fn test_detect_set_statement() {
        let result = detect_context("SET statement_timeout = ", 24).unwrap();
        assert_eq!(result.context_type, ContextType::Keyword);
    }

    #[test]
    fn test_detect_grant() {
        let result = detect_context("GRANT SELECT ON ", 16).unwrap();
        assert_eq!(result.context_type, ContextType::Table);
    }

    #[test]
    fn test_detect_grant_on_prefix() {
        let result = detect_context("GRANT SELECT ON us", 19).unwrap();
        assert_eq!(result.context_type, ContextType::Table);
    }

    #[test]
    fn test_detect_revoke_on() {
        let result = detect_context("REVOKE ALL ON ", 14).unwrap();
        assert_eq!(result.context_type, ContextType::Table);
    }

    #[test]
    fn test_detect_revoke() {
        let result = detect_context("REVOKE ", 7).unwrap();
        assert_eq!(result.context_type, ContextType::Keyword);
    }

    #[test]
    fn test_detect_copy_from() {
        let result = detect_context("COPY ", 5).unwrap();
        assert_eq!(result.context_type, ContextType::Table);
    }

    #[test]
    fn test_detect_copy_column() {
        let result = detect_context("COPY users (", 12).unwrap();
        assert_eq!(result.context_type, ContextType::InsertColumn { table: "users".to_string() });
    }

    // ---- SHOW statement ----

    #[test]
    fn test_detect_show_tables() {
        let result = detect_context("SHOW TABLES ", 12).unwrap();
        assert_eq!(result.context_type, ContextType::Table);
    }

    #[test]
    fn test_detect_show_tables_prefix() {
        let result = detect_context("SHOW TABLES", 11).unwrap();
        assert_eq!(result.context_type, ContextType::Table);
    }

    #[test]
    fn test_detect_show_databases() {
        let result = detect_context("SHOW DATABASES ", 15).unwrap();
        assert_eq!(result.context_type, ContextType::Database);
    }

    #[test]
    fn test_detect_show_schemas() {
        let result = detect_context("SHOW SCHEMAS ", 13).unwrap();
        assert_eq!(result.context_type, ContextType::Database);
    }

    #[test]
    fn test_detect_show_columns_from() {
        let result = detect_context("SHOW COLUMNS FROM ", 18).unwrap();
        assert_eq!(result.context_type, ContextType::Table);
    }

    #[test]
    fn test_detect_show_fields_from() {
        let result = detect_context("SHOW FIELDS FROM ", 17).unwrap();
        assert_eq!(result.context_type, ContextType::Table);
    }

    #[test]
    fn test_detect_show_columns_from_table_prefix() {
        let result = detect_context("SHOW COLUMNS FROM us", 20).unwrap();
        assert_eq!(result.context_type, ContextType::Table);
    }

    #[test]
    fn test_detect_show_bare_keyword() {
        let result = detect_context("SHOW ", 5).unwrap();
        assert_eq!(result.context_type, ContextType::Keyword);
    }

    #[test]
    fn test_detect_analyze() {
        let result = detect_context("ANALYZE ", 8).unwrap();
        assert_eq!(result.context_type, ContextType::Table);
    }

    #[test]
    fn test_detect_vacuum() {
        let result = detect_context("VACUUM ", 7).unwrap();
        assert_eq!(result.context_type, ContextType::Table);
    }

    #[test]
    fn test_detect_call_keyword() {
        let result = detect_context("CALL ", 5).unwrap();
        assert_eq!(result.context_type, ContextType::Table);
    }

    #[test]
    fn test_detect_do_keyword() {
        let result = detect_context("DO ", 3).unwrap();
        assert_eq!(result.context_type, ContextType::Keyword);
    }

    #[test]
    fn test_detect_prepare_keyword() {
        let result = detect_context("PREPARE ", 8).unwrap();
        assert_eq!(result.context_type, ContextType::Keyword);
    }

    #[test]
    fn test_detect_execute_keyword() {
        let result = detect_context("EXECUTE ", 8).unwrap();
        assert_eq!(result.context_type, ContextType::Keyword);
    }

    #[test]
    fn test_detect_explain_analyze() {
        let result = detect_context("EXPLAIN ANALYZE ", 16).unwrap();
        assert_eq!(result.context_type, ContextType::Table);
    }

    #[test]
    fn test_detect_listen_keyword() {
        let result = detect_context("LISTEN ", 7).unwrap();
        assert_eq!(result.context_type, ContextType::Keyword);
    }

    #[test]
    fn test_detect_notify_keyword() {
        let result = detect_context("NOTIFY ", 7).unwrap();
        assert_eq!(result.context_type, ContextType::Keyword);
    }

    #[test]
    fn test_detect_lock_table() {
        let result = detect_context("LOCK TABLE ", 11).unwrap();
        assert_eq!(result.context_type, ContextType::Table);
    }

    // ---- FOR UPDATE / FOR SHARE ----

    #[test]
    fn test_detect_for_update_of() {
        let result = detect_context("SELECT * FROM users FOR UPDATE OF ", 34).unwrap();
        assert_eq!(result.context_type, ContextType::Table);
    }

    #[test]
    fn test_detect_for_update_of_prefix() {
        let result = detect_context("SELECT * FROM users FOR UPDATE OF ord", 38).unwrap();
        assert_eq!(result.context_type, ContextType::Table);
    }

    #[test]
    fn test_detect_for_share_of() {
        let result = detect_context("SELECT * FROM users FOR SHARE OF ", 33).unwrap();
        assert_eq!(result.context_type, ContextType::Table);
    }

    #[test]
    fn test_detect_for_update_nowait() {
        let result = detect_context("SELECT * FROM users FOR UPDATE NOWAIT", 37).unwrap();
        assert_eq!(result.context_type, ContextType::Keyword);
    }

    #[test]
    fn test_detect_for_update_skip_locked() {
        let result = detect_context("SELECT * FROM users FOR UPDATE SKIP LOCKED", 42).unwrap();
        assert_eq!(result.context_type, ContextType::Keyword);
    }

    // ---- LATERAL / INSERT INTO SELECT ----

    #[test]
    fn test_detect_lateral_join() {
        let result = detect_context(
            "SELECT * FROM users u JOIN LATERAL (SELECT * FROM orders WHERE ", 60).unwrap();
        assert_eq!(result.context_type, ContextType::Column);
    }

    #[test]
    fn test_detect_insert_into_select() {
        let result = detect_context(
            "INSERT INTO users (id, name) SELECT ", 37).unwrap();
        assert_eq!(result.context_type, ContextType::Column);
    }

    // ---- Complex WHERE ----

    #[test]
    fn test_detect_where_parenthesized_and() {
        let result = detect_context(
            "SELECT * FROM users WHERE (id = 1 AND name = 'a') AND ", 52).unwrap();
        assert_eq!(result.context_type, ContextType::Column);
    }

    #[test]
    fn test_detect_where_parenthesized_or() {
        let result = detect_context(
            "SELECT * FROM users WHERE (a = 1 OR b = 2) AND ", 45).unwrap();
        assert_eq!(result.context_type, ContextType::Column,
            "AND after parenthesized condition should suggest columns");
    }

    #[test]
    fn test_detect_where_deeply_parenthesized() {
        let result = detect_context(
            "SELECT * FROM users WHERE ((a = 1) AND (b = 2)) AND ", 49).unwrap();
        assert_eq!(result.context_type, ContextType::Column);
    }

    // ---- subquery contexts ----

    #[test]
    fn test_detect_cursor_after_subquery_where() {
        let result = detect_context(
            "SELECT * FROM (SELECT * FROM items) AS sub WHERE ", 49).unwrap();
        assert_eq!(result.context_type, ContextType::Column);
    }

    #[test]
    fn test_detect_cursor_inside_subquery_exists() {
        let result = detect_context(
            "SELECT * FROM users WHERE EXISTS (SELECT 1 FROM secret WHERE ", 55).unwrap();
        assert_eq!(result.context_type, ContextType::Column);
    }

    #[test]
    fn test_detect_inside_subquery_in_in_clause() {
        let result = detect_context(
            "SELECT * FROM users WHERE id IN (SELECT user_id FROM orders WHERE ", 57).unwrap();
        assert_eq!(result.context_type, ContextType::Table);
    }

    #[test]
    fn test_detect_after_deeply_nested_subquery() {
        let result = detect_context(
            "SELECT * FROM (SELECT * FROM (SELECT * FROM deep) AS mid) AS outer WHERE ", 74).unwrap();
        assert_eq!(result.context_type, ContextType::Column);
    }

    // ---- table from subquery ----

    #[test]
    fn test_detect_table_from_update_in_subquery() {
        let result = detect_context(
            "SELECT * FROM (SELECT * FROM items) AS sub WHERE ", 49).unwrap();
        assert_eq!(result.context_type, ContextType::Column);
    }

    // ---- CTE ----

    #[test]
    fn test_detect_after_cte_select() {
        let result = detect_context(
            "WITH cte AS (SELECT * FROM users) SELECT * FROM cte WHERE ", 57).unwrap();
        assert_eq!(result.context_type, ContextType::Column);
    }

    // ---- SELECT variations ----

    #[test]
    fn test_detect_select_star_returns_keyword() {
        let result = detect_context("SELECT * ", 9).unwrap();
        assert_eq!(result.context_type, ContextType::Keyword);
    }

    #[test]
    fn test_detect_select_expr_returns_keyword() {
        let result = detect_context("SELECT col ", 11).unwrap();
        assert_eq!(result.context_type, ContextType::Keyword);
    }

    #[test]
    fn test_detect_select_star_comma_returns_column() {
        let result = detect_context("SELECT id, *, ", 14).unwrap();
        assert_eq!(result.context_type, ContextType::Column);
    }

    #[test]
    fn test_detect_select_comma_with_prefix() {
        let result = detect_context("SELECT *, col", 13).unwrap();
        assert_eq!(result.context_type, ContextType::Column);
    }

    #[test]
    fn test_detect_select_with_prefix_returns_keyword() {
        let result = detect_context("SELECT col ", 11).unwrap();
        assert_eq!(result.context_type, ContextType::Keyword);
    }

    #[test]
    fn test_detect_select_distinct() {
        let result = detect_context("SELECT DISTINCT ", 16).unwrap();
        assert_eq!(result.context_type, ContextType::Column,
            "DISTINCT after SELECT should suggest columns");
    }

    #[test]
    fn test_detect_select_all() {
        let result = detect_context("SELECT ALL ", 11).unwrap();
        assert_eq!(result.context_type, ContextType::Column,
            "ALL after SELECT should suggest columns");
    }

    // ---- Comments ----

    #[test]
    fn test_detect_inline_comment_does_not_leak() {
        let result = detect_context(
            "SELECT * FROM users /* find all users */ WHERE ", 49).unwrap();
        assert_eq!(result.context_type, ContextType::Column);
    }

    #[test]
    fn test_detect_block_comment_no_leak_to_where() {
        let result = detect_context(
            "SELECT * FROM users /* comment */ WHERE ", 41).unwrap();
        assert_eq!(result.context_type, ContextType::Column);
    }

    // ---- Extract tables ----

    #[test]
    fn test_extract_tables_simple() {
        let result = detect_context("SELECT * FROM users WHERE ", 25).unwrap();
        assert!(result.tables.iter().any(|t| t.name == "users"));
    }

    #[test]
    fn test_extract_tables_with_alias() {
        let result = detect_context(
            "SELECT * FROM users u WHERE ", 27).unwrap();
        assert!(result.tables.iter().any(|t| t.name == "users" && t.alias == Some("u".into())));
    }

    #[test]
    fn test_extract_tables_join_with_aliases() {
        let result = detect_context(
            "SELECT * FROM users u JOIN posts p ON u.id = p.id WHERE ",
            50,
        ).unwrap();
        assert!(result.tables.iter().any(|t| t.name == "users" && t.alias == Some("u".into())));
        assert!(result.tables.iter().any(|t| t.name == "posts" && t.alias == Some("p".into())));
    }

    #[test]
    fn test_extract_tables_no_leak_from_subquery() {
        let result = detect_context(
            "SELECT * FROM users WHERE id IN (SELECT user_id FROM orders) AND ",
            62,
        ).unwrap();
        assert!(result.tables.iter().any(|t| t.name == "users"));
        assert!(!result.tables.iter().any(|t| t.name == "orders"),
            "orders is inside a subquery and should not leak");
    }

    #[test]
    fn test_extract_tables_cross_join() {
        let result = detect_context(
            "SELECT * FROM users CROSS JOIN posts WHERE ",
            39,
        ).unwrap();
        assert!(result.tables.iter().any(|t| t.name == "users"));
        assert!(result.tables.iter().any(|t| t.name == "posts"));
    }

    #[test]
    fn test_extract_schema_qualified_table() {
        let result = detect_context(
            "SELECT * FROM public.users WHERE ",
            30,
        ).unwrap();
        assert!(result.tables.iter().any(|t| t.name == "users" && t.schema == Some("public".into())));
    }

    #[test]
    fn test_extract_schema_alias() {
        let result = detect_context(
            "SELECT * FROM public.users u WHERE ",
            29,
        ).unwrap();
        assert!(result.tables.iter().any(|t| {
            t.name == "users" && t.schema == Some("public".into()) && t.alias == Some("u".into())
        }), "users with schema public and alias u should be found");
    }

    #[test]
    fn test_extract_schema_join() {
        let result = detect_context(
            "SELECT * FROM public.users u JOIN blog.posts p ON u.id = p.user_id WHERE ",
            60,
        ).unwrap();
        assert!(result.tables.iter().any(|t| t.name == "users" && t.schema == Some("public".into())));
        assert!(result.tables.iter().any(|t| t.name == "posts" && t.schema == Some("blog".into())));
    }

    #[test]
    fn test_extract_multi_join_with_schema() {
        let result = detect_context(
            "SELECT * FROM public.users u JOIN posts p ON u.id = p.author_id JOIN comments c ON p.id = c.post_id WHERE ",
            98,
        ).unwrap();
        assert!(result.tables.iter().any(|t| t.name == "users"));
        assert!(result.tables.iter().any(|t| t.name == "posts"));
        assert!(result.tables.iter().any(|t| t.name == "comments"));
    }

    #[test]
    fn test_extract_three_level_name() {
        let result = detect_context(
            "SELECT * FROM mydb.public.users WHERE ",
            34,
        ).unwrap();
        assert!(result.tables.iter().any(|t| {
            t.name == "users" && t.schema == Some("public".into())
        }), "three-level name should extract schema=public, table=users");
    }

    #[test]
    fn test_extract_three_level_name_with_alias() {
        let result = detect_context(
            "SELECT * FROM mydb.public.users u WHERE ",
            33,
        ).unwrap();
        assert!(result.tables.iter().any(|t| {
            t.name == "users" && t.schema == Some("public".into()) && t.alias == Some("u".into())
        }), "three-level name with alias should extract name, schema, and alias");
    }

    #[test]
    fn test_extract_three_level_name_with_as_alias() {
        let result = detect_context(
            "SELECT * FROM mydb.public.users AS u WHERE ",
            36,
        ).unwrap();
        assert!(result.tables.iter().any(|t| {
            t.name == "users" && t.schema == Some("public".into()) && t.alias == Some("u".into())
        }), "three-level name with AS alias should work");
    }

    #[test]
    fn test_extract_table_with_as_alias_no_schema() {
        let result = detect_context(
            "SELECT * FROM users AS u WHERE ",
            28,
        ).unwrap();
        assert!(result.tables.iter().any(|t| {
            t.name == "users" && t.alias == Some("u".into())
        }), "table with AS alias and no schema should extract alias");
    }

    #[test]
    fn test_extract_join_with_schema_and_alias() {
        let result = detect_context(
            "SELECT * FROM public.users AS u JOIN public.posts AS p ON u.id = p.user_id WHERE ",
            68,
        ).unwrap();
        assert!(result.tables.iter().any(|t| {
            t.name == "users" && t.schema == Some("public".into()) && t.alias == Some("u".into())
        }));
        assert!(result.tables.iter().any(|t| {
            t.name == "posts" && t.schema == Some("public".into()) && t.alias == Some("p".into())
        }));
    }

    #[test]
    fn test_extract_natural_join() {
        let result = detect_context(
            "SELECT * FROM users NATURAL JOIN posts WHERE ",
            40,
        ).unwrap();
        assert!(result.tables.iter().any(|t| t.name == "users"));
        assert!(result.tables.iter().any(|t| t.name == "posts"));
    }

    #[test]
    fn test_extract_table_with_dash() {
        let result = detect_context(
            "SELECT * FROM posts-web_vitals WHERE ",
            31,
        ).unwrap();
        assert!(result.tables.iter().any(|t| t.name == "posts-web_vitals"));
    }

    // ---- Statement span ----

    #[test]
    fn test_find_statement_span_simple() {
        let lines = vec!["SELECT 1;", "SELECT 2;"];
        let span = find_statement_span(&lines, 0);
        assert_eq!(span, Some((0, 0)));
        let span2 = find_statement_span(&lines, 1);
        assert_eq!(span2, Some((1, 1)));
    }

    #[test]
    fn test_find_statement_span_with_semicolon_in_string() {
        let lines = vec!["SELECT 'hello;world'"];
        let span = find_statement_span(&lines, 0);
        assert_eq!(span, Some((0, 0)));
    }

    #[test]
    fn test_find_statement_span_semicolon_in_dollar_string() {
        let lines = vec!["SELECT $$abc;def$$;", "SELECT 2"];
        let span = find_statement_span(&lines, 1);
        assert_ne!(span, None);
    }

    #[test]
    fn test_find_statement_span_multi_statement_on_same_line() {
        let lines = vec!["SELECT 1; SELECT 2;"];
        let span = find_statement_span(&lines, 0);
        assert_eq!(span, Some((0, 0)));
    }
}
