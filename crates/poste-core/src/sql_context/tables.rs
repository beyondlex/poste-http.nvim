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

    // Check for schema qualifier: next token is '.'
    if let Some(dot) = tokens.get(i + 1) {
        if dot.kind == TokenKind::Dot {
            if let Some(table_tok) = tokens.get(i + 2) {
                if matches!(table_tok.kind, TokenKind::Ident | TokenKind::QuotedIdent | TokenKind::Keyword) {
                    let schema = Some(first_text);
                    let table = table_tok.text(sql);
                    consumed = 3;

                    // Skip whitespace and optional AS to find alias
                    if let Some(next_idx) = skip_forward(tokens, i + 2) {
                        if tokens[next_idx].kind == TokenKind::Keyword && kw_eq(tokens[next_idx].text(sql), "as") {
                            if let Some(after_as) = skip_forward(tokens, next_idx) {
                                let alias_tok = &tokens[after_as];
                                if matches!(alias_tok.kind, TokenKind::Ident | TokenKind::QuotedIdent) {
                                    let alias_text = alias_tok.text(sql);
                                    if !is_table_keyword(alias_text) && !is_column_keyword(alias_text)
                                        && !is_predicate_keyword(alias_text)
                                        && !is_known_keyword(alias_text)
                                    {
                                        consumed = after_as - i + 1;
                                        return (schema, table, Some(alias_text), consumed);
                                    }
                                }
                            }
                        } else if matches!(tokens[next_idx].kind, TokenKind::Ident | TokenKind::QuotedIdent) {
                            let alias_text = tokens[next_idx].text(sql);
                            if !is_table_keyword(alias_text) && !is_column_keyword(alias_text)
                                && !is_predicate_keyword(alias_text)
                                && !is_known_keyword(alias_text)
                            {
                                consumed = next_idx - i + 1;
                                return (schema, table, Some(alias_text), consumed);
                            }
                        }
                    }
                    return (schema, table, None, consumed);
                }
            }
            let mut j = i + 2;
            while j < tokens.len() {
                match tokens[j].kind {
                    TokenKind::Dot => { j += 1; }
                    TokenKind::Ident | TokenKind::QuotedIdent | TokenKind::Keyword => {
                        if j + 1 < tokens.len() && tokens[j + 1].kind == TokenKind::Dot {
                            j += 2;
                            continue;
                        }
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
