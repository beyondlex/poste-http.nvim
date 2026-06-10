use super::tokenizer::{tokenize, TokenKind};

pub fn find_statement_span(lines: &[&str], cursor_line: usize) -> Option<(usize, usize)> {
    if lines.is_empty() || cursor_line >= lines.len() { return None; }
    let text = lines.join("\n");
    let tokens = tokenize(&text);
    if tokens.is_empty() { return None; }

    let line_offsets: Vec<usize> = {
        let mut offsets = Vec::with_capacity(lines.len() + 1);
        offsets.push(0);
        for l in lines {
            offsets.push(offsets.last().unwrap() + l.len() + 1);
        }
        offsets.pop();
        offsets.push(text.len());
        offsets
    };

    let cursor_start = line_offsets[cursor_line];

    let semi_positions: Vec<usize> = tokens.iter()
        .filter(|t| t.kind == TokenKind::Semi)
        .map(|t| t.start)
        .collect();

    let stmt_start_byte = semi_positions.iter()
        .rev()
        .find(|&&pos| pos < cursor_start)
        .map(|&pos| {
            for (l, &off) in line_offsets.iter().enumerate() {
                if off > pos + 1 { return l; }
            }
            0
        })
        .unwrap_or(0);

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