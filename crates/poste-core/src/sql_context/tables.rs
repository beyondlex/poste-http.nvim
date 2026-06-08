//! Table reference extraction from a token stream.
//!
//! Supports schema-qualified tables (`schema.table`), aliases, and
//! paren-depth tracking to skip subquery-internal table references.

use super::tokenizer::{kw_eq, skip_forward, Token, TokenKind};
use super::tokenizer::{is_column_keyword, is_known_keyword, is_predicate_keyword, is_table_keyword};
use super::TableRef;

// ---------------------------------------------------------------------------
// Table extraction (forward scan, paren-aware)
// ---------------------------------------------------------------------------

/// Extract table references from a token stream.
///
/// Tracks paren depth to skip subqueries. Handles:
/// - FROM/JOIN/UPDATE/INTO + identifier
/// - Schema-qualified: schema.table
/// - Aliases: table alias
pub(crate) fn extract_tables(tokens: &[Token], sql: &str) -> Vec<TableRef> {
    let mut tables: Vec<TableRef> = Vec::new();
    let mut i = 0;
    let mut paren_depth = 0i32;

    while i < tokens.len() {
        let t = &tokens[i];
        match t.kind {
            TokenKind::LParen => paren_depth += 1,
            TokenKind::RParen => paren_depth -= 1,
            TokenKind::Keyword if paren_depth == 0 => {
                let kw = t.text(sql);
                if kw_eq(kw, "from") || kw_eq(kw, "join") || kw_eq(kw, "into")
                    || kw_eq(kw, "table") || kw_eq(kw, "update") {
                    if let Some(next) = skip_forward(tokens, i) {
                        let (schema, table_name, alias, consumed) =
                            parse_table_ref(tokens, next, sql);

                        let table = TableRef {
                            name: table_name.to_string(),
                            alias: alias.map(|s| s.to_string()),
                            schema: schema.map(|s| s.to_string()),
                        };

                        if !tables.iter().any(|t| t.name == table.name && t.alias == table.alias && t.schema == table.schema) {
                            tables.push(table);
                        }

                        if consumed > 0 {
                            i += consumed;
                        }
                    }
                }
            }
            _ => {}
        }
        i += 1;
    }

    tables
}

/// Parse a table reference starting at token index `i`.
/// Returns (schema, table_name, alias, tokens_consumed).
pub(crate) fn parse_table_ref<'a>(
    tokens: &[Token], i: usize, sql: &'a str
) -> (Option<&'a str>, &'a str, Option<&'a str>, usize) {
    let first = match tokens.get(i) {
        Some(t) if matches!(t.kind, TokenKind::Ident | TokenKind::QuotedIdent | TokenKind::Keyword) => t,
        _ => return (None, "", None, 0),
    };

    let first_text = first.text(sql);
    let mut consumed = 1;

    // Check for schema qualifier: find '.' after this token using skip_forward
    if let Some(dot_idx) = skip_forward(tokens, i) {
        if tokens[dot_idx].kind == TokenKind::Dot {
            // Find the table name after the dot
            if let Some(table_idx) = skip_forward(tokens, dot_idx) {
                let table_tok = &tokens[table_idx];
                if matches!(table_tok.kind, TokenKind::Ident | TokenKind::QuotedIdent | TokenKind::Keyword) {
                    let table = table_tok.text(sql);

                    // Check for 3-level: database.schema.table
                    if let Some(next_dot_idx) = skip_forward(tokens, table_idx) {
                        if tokens[next_dot_idx].kind == TokenKind::Dot {
                            if let Some(third_idx) = skip_forward(tokens, next_dot_idx) {
                                let third_tok = &tokens[third_idx];
                                if matches!(third_tok.kind, TokenKind::Ident | TokenKind::QuotedIdent | TokenKind::Keyword) {
                                    // 3-level: database.schema.table → schema = middle, table = last
                                    let schema_text = table;
                                    let table_text = third_tok.text(sql);
                                    consumed = third_idx - i + 1;

                                    // Check for alias after 3-level table
                                    if let Some(alias_idx) = skip_forward(tokens, third_idx) {
                                        if let Some((alias, c)) = try_extract_alias(tokens, alias_idx, sql, i) {
                                            return (Some(schema_text), table_text, Some(alias), c);
                                        }
                                    }
                                    return (Some(schema_text), table_text, None, consumed);
                                }
                            }
                        }
                    }

                    // 2-level: schema.table
                    consumed = table_idx - i + 1;

                    // Check for alias after 2-level table
                    if let Some(alias_idx) = skip_forward(tokens, table_idx) {
                        if let Some((alias, c)) = try_extract_alias(tokens, alias_idx, sql, i) {
                            return (Some(first_text), table, Some(alias), c);
                        }
                    }
                    return (Some(first_text), table, None, consumed);
                }
            }

            // Fallback: multi-level edge case (e.g., database..table or qualifiers
            // where the table identifier wasn't directly after the dot)
            let mut j = dot_idx;
            while j < tokens.len() {
                match tokens[j].kind {
                    TokenKind::Dot => { j += 1; }
                    TokenKind::Ident | TokenKind::QuotedIdent | TokenKind::Keyword => {
                        let table = tokens[j].text(sql);
                        consumed = j - i + 2;

                        if let Some(alias_tok) = tokens.get(j + 1) {
                            if matches!(alias_tok.kind, TokenKind::Ident | TokenKind::QuotedIdent) {
                                let alias_text = alias_tok.text(sql);
                                if !is_known_keyword(alias_text) {
                                    consumed = j - i + 3;
                                    return (Some(first_text), table, Some(alias_text), consumed);
                                }
                            }
                        }
                        return (Some(first_text), table, None, consumed);
                    }
                    _ => break,
                }
            }
            return (None, first_text, None, 1);
        }
    }

    // No schema qualifier: check for alias (skip whitespace)
    if let Some(next_idx) = skip_forward(tokens, i) {
        // Handle "AS alias" in non-schema branch too
        if let Some((alias, c)) = try_extract_alias(tokens, next_idx, sql, i) {
            return (None, first_text, Some(alias), c);
        }
        // Fallback: check bare alias with extra exclusions
        let alias_tok = &tokens[next_idx];
        if matches!(alias_tok.kind, TokenKind::Ident | TokenKind::QuotedIdent) {
            let alias_text = alias_tok.text(sql);
            let lower = alias_text.to_ascii_lowercase();
            if !is_table_keyword(&lower) && !is_column_keyword(&lower)
                && !is_predicate_keyword(&lower)
                && !matches!(lower.as_str(), "as" | "on" | "using")
            {
                consumed = next_idx - i + 1;
                return (None, first_text, Some(alias_text), consumed);
            }
        }
    }

    (None, first_text, None, consumed)
}

/// Try to extract an alias at a given token position.
/// Handles both `alias` and `AS alias` forms.
/// Returns `(alias_text, total_consumed_from_start)` or `None`.
fn try_extract_alias<'a>(
    tokens: &[Token], idx: usize, sql: &'a str, start: usize
) -> Option<(&'a str, usize)> {
    let tok = &tokens[idx];
    // Handle "AS alias"
    if tok.kind == TokenKind::Keyword && kw_eq(tok.text(sql), "as") {
        if let Some(after_as) = skip_forward(tokens, idx) {
            let alias_tok = &tokens[after_as];
            if matches!(alias_tok.kind, TokenKind::Ident | TokenKind::QuotedIdent) {
                let alias_text = alias_tok.text(sql);
                if !is_table_keyword(alias_text) && !is_column_keyword(alias_text)
                    && !is_predicate_keyword(alias_text)
                    && !is_known_keyword(alias_text)
                {
                    return Some((alias_text, after_as - start + 1));
                }
            }
        }
    // Handle bare "alias"
    } else if matches!(tok.kind, TokenKind::Ident | TokenKind::QuotedIdent) {
        let alias_text = tok.text(sql);
        if !is_table_keyword(alias_text) && !is_column_keyword(alias_text)
            && !is_predicate_keyword(alias_text)
            && !is_known_keyword(alias_text)
        {
            return Some((alias_text, idx - start + 1));
        }
    }
    None
}
