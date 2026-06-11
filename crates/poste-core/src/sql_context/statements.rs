use super::tokenizer::{tokenize, Token, TokenKind};

/// SQL keywords that start a new top-level statement.
///
/// `SET` is intentionally excluded because it appears both as a standalone
/// statement (`SET NAMES utf8`) and as a clause inside `UPDATE t SET col=1`.
fn is_statement_start_keyword(kw: &str) -> bool {
    let w = kw.as_bytes();
    if w.len() < 3 || w.len() > 12 {
        return false;
    }
    let mut buf = [0u8; 12];
    for (i, &b) in w.iter().enumerate() {
        buf[i] = if b.is_ascii_lowercase() { b - 32 } else { b };
    }
    let up = &buf[..w.len()];
    const KWS: &[&[u8]] = &[
        b"ALTER", b"BEGIN", b"CALL", b"COMMIT", b"COPY", b"CREATE",
        b"DECLARE", b"DELETE", b"DROP", b"EXPLAIN", b"GRANT",
        b"INSERT", b"ROLLBACK", b"REVOKE", b"SELECT",
        b"SHOW", b"TRUNCATE", b"UPDATE", b"USE",
        b"VACUUM", b"WITH",
    ];
    KWS.contains(&up)
}

/// Check if a statement-start keyword is "contained by" a preceding one.
/// e.g. `UPDATE` inside `INSERT ... ON CONFLICT DO UPDATE SET` is not a
/// new statement — it's a clause of `INSERT`. Similarly `FOR UPDATE` in
/// `SELECT ...` is a clause, not a standalone `UPDATE`.
fn kw_contains(container: &str, contained: &str) -> bool {
    matches!(
        (container, contained),
        ("insert", "select") | ("insert", "update") | ("select", "update") | ("with", _)
    )
}

fn compute_paren_depths(tokens: &[Token]) -> Vec<i32> {
    let mut depths = Vec::with_capacity(tokens.len());
    let mut depth = 0i32;
    for t in tokens {
        depths.push(depth);
        match t.kind {
            TokenKind::LParen => depth += 1,
            TokenKind::RParen => depth -= 1,
            _ => {}
        }
    }
    depths
}

/// Find the token range `(start, end_exclusive)` of the statement containing `cursor_idx`.
///
/// Uses semantic keyword-based boundary detection at `paren_depth == 0`:
/// - `;` is a hard boundary (always splits)
/// - Statement-start keywords are soft boundaries (e.g. `SELECT`, `CREATE`)
/// - Some keywords "contain" others: `INSERT` contains `UPDATE` (ON CONFLICT DO UPDATE),
///   `SELECT` contains `UPDATE` (FOR UPDATE), `WITH` contains the next stmt-start keyword.
/// - Subqueries inside parens are correctly isolated by paren-depth tracking.
pub(crate) fn find_statement_token_range(
    tokens: &[Token], cursor_idx: usize, sql: &str,
) -> (usize, usize) {
    let depths = compute_paren_depths(tokens);

    // -- backward scan: find statement start and its keyword --
    let mut start = 0;
    let mut stmt_kw = String::new();
    for i in (0..cursor_idx).rev() {
        if depths[i] != 0 {
            continue;
        }
        if tokens[i].kind == TokenKind::Semi {
            start = i + 1;
            break;
        }
        if tokens[i].kind == TokenKind::Keyword {
            let kw = tokens[i].text(sql).to_ascii_lowercase();
            if is_statement_start_keyword(&kw) {
                start = i;
                stmt_kw = kw;
                break;
            }
        }
    }

    // -- expand `start` backward if the found keyword is contained by a preceding one --
    // e.g. `INSERT ... DO UPDATE SET col=1`: backward scan finds `UPDATE`,
    // but we need to extend `start` to `INSERT`.
    loop {
        if stmt_kw.is_empty() {
            break;
        }
        let mut found_container = false;
        for i in (0..start).rev() {
            if depths[i] != 0 { continue; }
            if tokens[i].kind == TokenKind::Semi { break; }
            if tokens[i].kind == TokenKind::Keyword {
                let prev = tokens[i].text(sql).to_ascii_lowercase();
                if is_statement_start_keyword(&prev) {
                    if kw_contains(&prev, &stmt_kw) {
                        start = i;
                        stmt_kw = prev;
                        found_container = true;
                    }
                    break;
                }
            }
        }
        if !found_container { break; }
    }

    // -- determine which keyword started *this* statement at `start` --
    let mut this_kw = String::new();
    for i in start..=cursor_idx.min(tokens.len().saturating_sub(1)) {
        if depths[i] != 0 { continue; }
        if tokens[i].kind == TokenKind::Keyword {
            let kw = tokens[i].text(sql).to_ascii_lowercase();
            if is_statement_start_keyword(&kw) {
                this_kw = kw;
                break;
            }
        }
    }
    if this_kw.is_empty() && !stmt_kw.is_empty() {
        this_kw.clone_from(&stmt_kw);
    }

    // -- forward scan: find statement end --
    let mut end = tokens.len();
    let mut claim_next = this_kw == "with";

    for i in start + 1..tokens.len() {
        if depths[i] != 0 { continue; }
        if tokens[i].kind == TokenKind::Semi {
            end = i;
            break;
        }
        if tokens[i].kind == TokenKind::Keyword {
            let kw = tokens[i].text(sql).to_ascii_lowercase();
            if is_statement_start_keyword(&kw) {
                if claim_next || kw_contains(&this_kw, &kw) {
                    // WITH consumes the next stmt-start keyword.
                    // INSERT/SELECT consume UPDATE (ON CONFLICT DO UPDATE / FOR UPDATE).
                    claim_next = false;
                    continue;
                }
                end = i;
                break;
            }
        }
    }

    (start, end)
}

/// Find the **line range** `(start_line, end_line)` for the statement containing
/// `cursor_line`.
pub fn find_statement_span(lines: &[&str], cursor_line: usize) -> Option<(usize, usize)> {
    if lines.is_empty() || cursor_line >= lines.len() {
        return None;
    }

    let text = lines.join("\n");
    let tokens = tokenize(&text);
    if tokens.is_empty() {
        return None;
    }

    // Build line-offset lookup
    let line_offsets: Vec<usize> = {
        let mut offsets = Vec::with_capacity(lines.len() + 1);
        let mut offset = 0;
        offsets.push(offset);
        for l in lines {
            offset += l.len() + 1;
            offsets.push(offset);
        }
        offsets.pop();
        offsets
    };

    let cursor_byte = line_offsets[cursor_line];
    let cursor_tok = tokens.iter()
        .rposition(|t| t.start <= cursor_byte)
        .unwrap_or(0);
    if cursor_tok >= tokens.len() {
        return Some((0, lines.len() - 1));
    }

    let (mut start_tok, end_tok) = find_statement_token_range(&tokens, cursor_tok, &text);

    // Skip leading whitespace/comments
    while start_tok < end_tok && matches!(
        tokens[start_tok].kind,
        TokenKind::Whitespace | TokenKind::LineComment | TokenKind::BlockComment
    ) {
        start_tok += 1;
    }
    if start_tok >= end_tok {
        return Some((cursor_line, cursor_line));
    }

    let start_line = byte_to_line(&line_offsets, tokens[start_tok].start);
    let last_tok = end_tok.saturating_sub(1);
    let end_byte = tokens[last_tok].end;
    let end_line = byte_to_line(&line_offsets, end_byte);

    Some((start_line, end_line))
}

fn byte_to_line(offsets: &[usize], byte: usize) -> usize {
    for (l, &off) in offsets.iter().enumerate().rev() {
        if off <= byte {
            return l;
        }
    }
    0
}
