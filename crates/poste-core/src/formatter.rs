use std::fmt;

#[derive(Debug, Clone, PartialEq)]
pub enum Region {
    Separator(String),
    Comment(String),
    VarDef {
        name: String,
        value: String,
        raw: String,
        style: VarStyle,
    },
    RequestLine {
        method: String,
        url: String,
        version: Option<String>,
        raw: String,
    },
    Header {
        key: String,
        value: String,
        raw: String,
    },
    BlankLine,
    Body {
        content: String,
        content_type: Option<String>,
    },
    PreScript {
        code: String,
        style: ScriptStyle,
    },
    PostScript {
        code: String,
        style: ScriptStyle,
    },
    ExternalScript {
        path: String,
        script_type: ScriptType,
    },
    /// `< path` — file content include (JSON) or upload (form), resolved at runtime
    FileUpload(String),
    Prompt(String),
    Import {
        path: String,
        alias: Option<String>,
        raw: String,
    },
    Run {
        target: String,
        raw: String,
    },
    Raw(String),
}

impl Region {
    pub fn raw_text(&self) -> String {
        match self {
            Region::Separator(s) => s.clone(),
            Region::Comment(s) => format!("#{}\n", s),
            Region::VarDef { raw, .. } => raw.clone(),
            Region::RequestLine { raw, .. } => raw.clone(),
            Region::Header { raw, .. } => raw.clone(),
            Region::BlankLine => String::new(),
            Region::Body { content, .. } => content.clone(),
            Region::PreScript { code: _, style } => match style {
                ScriptStyle::Inline(s) => s.clone(),
                ScriptStyle::Multiline(lines) => {
                    let mut s = String::from("< {%\n");
                    let indented = Formatter::reindent_code(lines);
                    for l in &indented {
                        s.push_str(l);
                        s.push('\n');
                    }
                    s.push_str("%}");
                    s
                }
            },
            Region::PostScript { code: _, style } => match style {
                ScriptStyle::Inline(s) => s.clone(),
                ScriptStyle::Multiline(lines) => {
                    let mut s = String::from("> {%\n");
                    let indented = Formatter::reindent_code(lines);
                    for l in &indented {
                        s.push_str(l);
                        s.push('\n');
                    }
                    s.push_str("%}");
                    s
                }
            },
            Region::ExternalScript { path, script_type } => {
                let prefix = match script_type {
                    ScriptType::Pre => "< ",
                    ScriptType::Post => "> ",
                };
                format!("{}{}", prefix, path)
            }
            Region::FileUpload(s) => format!("< {}", s),
            Region::Prompt(s) => format!("# @prompt {}", s),
            Region::Import { raw, .. } => raw.clone(),
            Region::Run { raw, .. } => raw.clone(),
            Region::Raw(s) => s.clone(),
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum VarStyle {
    Simple,
    Multiline { terminator: String },
}

#[derive(Debug, Clone, PartialEq)]
pub enum ScriptStyle {
    Inline(String),
    Multiline(Vec<String>),
}

#[derive(Debug, Clone, PartialEq)]
pub enum ScriptType {
    Pre,
    Post,
}

impl fmt::Display for Region {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.raw_text())
    }
}

pub struct Tokenizer;

impl Tokenizer {
    pub fn tokenize(content: &str) -> Vec<Region> {
        let mut regions = Vec::new();
        let lines: Vec<&str> = content.lines().collect();
        let mut i = 0;
        let mut in_body = false;
        let mut found_method_line = false;

        while i < lines.len() {
            let line = lines[i];
            let trimmed = line.trim();

            // Multi-line pre-script: < {% ... no %}
            if (trimmed.starts_with("< {%") || trimmed.starts_with("<{%")) && !trimmed.contains("%}") {
                let mut code_lines = Vec::new();
                i += 1;
                while i < lines.len() {
                    let l = lines[i];
                    if l.trim() == "%}" {
                        i += 1;
                        break;
                    }
                    code_lines.push(l.to_string());
                    i += 1;
                }
                regions.push(Region::PreScript {
                    code: code_lines.join("\n"),
                    style: ScriptStyle::Multiline(code_lines),
                });
                continue;
            }

            // Multi-line post-script: > {% ... no %}
            if (trimmed.starts_with("> {%") || trimmed.starts_with(">{%")) && !trimmed.contains("%}") {
                let mut code_lines = Vec::new();
                i += 1;
                while i < lines.len() {
                    let l = lines[i];
                    if l.trim() == "%}" {
                        i += 1;
                        break;
                    }
                    code_lines.push(l.to_string());
                    i += 1;
                }
                regions.push(Region::PostScript {
                    code: code_lines.join("\n"),
                    style: ScriptStyle::Multiline(code_lines),
                });
                continue;
            }

            // Multi-line var: @xxx >>> ... <<<
            if let Some(name) = Self::parse_multiline_var_start(line) {
                let mut value_lines = Vec::new();
                i += 1;
                while i < lines.len() {
                    let l = lines[i];
                    if l.trim() == "<<<" {
                        i += 1;
                        break;
                    }
                    value_lines.push(l.to_string());
                    i += 1;
                }
                let raw_value = value_lines.join("\n");
                regions.push(Region::VarDef {
                    name: name.clone(),
                    value: raw_value.clone(),
                    raw: format!("@{} =>>>\n{}\n<<<", name, raw_value),
                    style: VarStyle::Multiline { terminator: "<<<".to_string() },
                });
                continue;
            }

            // Blank line resets body detection
            if trimmed.is_empty() {
                if found_method_line && !in_body {
                    in_body = true;
                }
                regions.push(Region::BlankLine);
                i += 1;
                continue;
            }

            // Import directive
            if trimmed.starts_with("import ") {
                let rest = trimmed.strip_prefix("import ").unwrap_or("");
                let (path, alias) = if let Some(idx) = rest.find(" as ") {
                    let p = rest[..idx].trim().to_string();
                    let a = rest[idx + 4..].trim().to_string();
                    (p, Some(a))
                } else {
                    (rest.trim().to_string(), None)
                };
                regions.push(Region::Import { path, alias, raw: line.to_string() });
                i += 1;
                continue;
            }

            // Run directive
            if trimmed.starts_with("run ") {
                let target = trimmed.strip_prefix("run ").unwrap_or("").trim().to_string();
                regions.push(Region::Run { target, raw: line.to_string() });
                i += 1;
                continue;
            }

            // ### separator
            if trimmed.starts_with("###") {
                regions.push(Region::Separator(line.to_string()));
                i += 1;
                found_method_line = false;
                in_body = false;
                continue;
            }

            // Inline pre-script: < {% ... %}
            if (trimmed.starts_with("< {%") || trimmed.starts_with("<{%")) && trimmed.contains("%}") {
                let code_start = trimmed.find("{%").map(|p| p + 2).unwrap_or(2);
                let code_end = trimmed.rfind("%}").unwrap_or(trimmed.len());
                let code = trimmed[code_start..code_end].trim().to_string();
                regions.push(Region::PreScript { code, style: ScriptStyle::Inline(line.to_string()) });
                i += 1;
                continue;
            }

            // External pre-script: < ./path.lua (must end with .lua)
            if trimmed.starts_with("< ") && (trimmed.contains("./") || trimmed.contains("../")) && trimmed.ends_with(".lua") {
                let path = trimmed.strip_prefix("< ").unwrap_or("").trim().to_string();
                regions.push(Region::ExternalScript { path, script_type: ScriptType::Pre });
                i += 1;
                continue;
            }

            // File include/upload: < path (space after <)
            // At runtime: JSON Content-Type → include file content, form Content-Type → upload
            if trimmed.starts_with("< ") && !trimmed.contains("{%") {
                let path = trimmed.strip_prefix("< ").unwrap_or("").trim().to_string();
                regions.push(Region::FileUpload(path));
                i += 1;
                continue;
            }

            // Inline post-script: > {% ... %}
            if (trimmed.starts_with("> {%") || trimmed.starts_with(">{%")) && trimmed.contains("%}") {
                let code_start = trimmed.find("{%").map(|p| p + 2).unwrap_or(2);
                let code_end = trimmed.rfind("%}").unwrap_or(trimmed.len());
                let code = trimmed[code_start..code_end].trim().to_string();
                regions.push(Region::PostScript { code, style: ScriptStyle::Inline(line.to_string()) });
                i += 1;
                continue;
            }

            // External post-script: > ./path.lua (must end with .lua)
            if trimmed.starts_with("> ") && (trimmed.contains("./") || trimmed.contains("../")) && trimmed.ends_with(".lua") {
                let path = trimmed.strip_prefix("> ").unwrap_or("").trim().to_string();
                regions.push(Region::ExternalScript { path, script_type: ScriptType::Post });
                i += 1;
                continue;
            }

            // @prompt
            if trimmed.starts_with("# @prompt") {
                let rest = trimmed.strip_prefix("# @prompt").unwrap_or("").trim().to_string();
                regions.push(Region::Prompt(rest));
                i += 1;
                continue;
            }

            // Comment
            if trimmed.starts_with('#') {
                let text = trimmed.strip_prefix('#').unwrap_or("").to_string();
                regions.push(Region::Comment(text));
                i += 1;
                continue;
            }

            // Variable definition
            if trimmed.starts_with('@') {
                if let Some((name, value)) = Self::parse_var_line(trimmed) {
                    regions.push(Region::VarDef { name, value: value.clone(), raw: line.to_string(), style: VarStyle::Simple });
                    i += 1;
                    continue;
                }
            }

            // Request line: METHOD URL (check first word only)
            if !in_body && !found_method_line {
                if let Some(method) = trimmed.split_whitespace().next() {
                    if Self::is_http_method(method) {
                        let parts: Vec<&str> = trimmed.splitn(3, char::is_whitespace).collect();
                        let method = parts[0].to_string();
                        let url = parts.get(1).unwrap_or(&"").to_string();
                        let version = parts.get(2).map(|s| s.to_string());
                        regions.push(Region::RequestLine { method, url, version, raw: line.to_string() });
                        found_method_line = true;
                        i += 1;
                        continue;
                    }
                }
            }

            // Header line: Key: Value (before body, key must be valid header name)
            if !in_body {
                if let Some((key, value)) = trimmed.split_once(':') {
                    let key_trimmed = key.trim();
                    if !key_trimmed.is_empty()
                        && key_trimmed.chars().all(|c| c.is_alphanumeric() || c == '-' || c == '_')
                        && !key_trimmed.starts_with('@')
                    {
                        regions.push(Region::Header { key: key_trimmed.to_string(), value: value.trim().to_string(), raw: line.to_string() });
                        i += 1;
                        continue;
                    }
                }
            }

            // Fallback: raw line (body content or unrecognized preamble)
            regions.push(Region::Raw(line.to_string()));
            i += 1;
        }

        regions
    }

    fn parse_multiline_var_start(line: &str) -> Option<String> {
        let trimmed = line.trim();
        if !trimmed.starts_with('@') {
            return None;
        }
        let content = &trimmed[1..];
        if let Some((name, marker)) = content.split_once('=') {
            if marker.trim() == ">>>" && name.trim().chars().all(|c| c.is_alphanumeric() || c == '_') {
                return Some(name.trim().to_string());
            }
        }
        if let Some((name, marker)) = content.split_once(char::is_whitespace) {
            if marker.trim() == ">>>" && name.trim().chars().all(|c| c.is_alphanumeric() || c == '_') {
                return Some(name.trim().to_string());
            }
        }
        None
    }

    fn parse_var_line(line: &str) -> Option<(String, String)> {
        let trimmed = line.trim();
        if !trimmed.starts_with('@') {
            return None;
        }
        let content = &trimmed[1..];
        if let Some((name, value)) = content.split_once('=') {
            let name = name.trim().to_string();
            let value = value.trim().to_string();
            if !name.is_empty() && name.chars().all(|c| c.is_alphanumeric() || c == '_') {
                return Some((name, value));
            }
        }
        if let Some((name, value)) = content.split_once(char::is_whitespace) {
            let name = name.trim().to_string();
            let value = value.trim().to_string();
            if !name.is_empty() && name.chars().all(|c| c.is_alphanumeric() || c == '_') {
                return Some((name, value));
            }
        }
        None
    }

    fn is_http_method(s: &str) -> bool {
        matches!(
            s,
            "GET" | "POST" | "PUT" | "DELETE" | "PATCH" | "HEAD" | "OPTIONS" | "TRACE" | "CONNECT"
        )
    }
}

pub struct Formatter;

impl Formatter {
    pub fn format(content: &str) -> String {
        let regions = Tokenizer::tokenize(content);
        Self::apply_rules(&regions)
    }

    fn apply_rules(regions: &[Region]) -> String {
        // Split regions into blocks at Separator boundaries
        let mut blocks: Vec<Vec<&Region>> = Vec::new();
        let mut current: Vec<&Region> = Vec::new();
        for r in regions {
            match r {
                Region::Separator(_) => {
                    if !current.is_empty() {
                        blocks.push(std::mem::take(&mut current));
                    }
                    current.push(r);
                }
                _ => {
                    current.push(r);
                }
            }
        }
        if !current.is_empty() {
            blocks.push(current);
        }

        let mut out = String::new();

        for (block_idx, block) in blocks.iter().enumerate() {
            // Check if this is a file-header block (no Separator)
            if !block.iter().any(|r| matches!(r, Region::Separator(_))) {
                Self::format_file_header(block, &mut out);
                continue;
            }

            // Block with a Separator at position 0
            if block_idx > 0 {
                out.push('\n');
            }

            // Emit ### line
            if let Some(Region::Separator(s)) = block.first() {
                let name = s.trim_start_matches("###").trim();
                if name.is_empty() {
                    out.push_str("###\n");
                } else {
                    out.push_str(&format!("### {}\n", name));
                }
            }

            Self::format_request_block(&block[1..], &mut out);
        }

        // Rule 8: trailing newline
        let trimmed = out.trim_end().to_string();
        if trimmed.is_empty() { String::new() } else { format!("{}\n", trimmed) }
    }

    fn format_file_header(regions: &[&Region], out: &mut String) {
        let mut import_lines: Vec<String> = Vec::new();
        let mut var_lines: Vec<String> = Vec::new();
        let mut has_imports = false;
        let mut has_vars = false;

        for r in regions {
            match r {
                Region::Import { .. } | Region::Run { .. } => {
                    import_lines.push(r.raw_text());
                    has_imports = true;
                }
                Region::VarDef { name, value, style, .. } => {
                    match style {
                        VarStyle::Simple => var_lines.push(format!("@{} = {}", name, value)),
                        VarStyle::Multiline { .. } => {
                            var_lines.push(format!("@{} =>>>\n{}\n<<<", name, value));
                        }
                    }
                    has_vars = true;
                }
                Region::Comment(text) => {
                    var_lines.push(if text.is_empty() { "#".into() } else { format!("#{}", text) });
                    has_vars = true;
                }
                Region::Prompt(rest) => {
                    var_lines.push(format!("# @prompt {}", rest));
                    has_vars = true;
                }
                _ => {}
            }
        }

        if !has_imports && !has_vars {
            return;
        }

        if has_imports {
            for line in &import_lines { out.push_str(line); out.push('\n'); }
        }
        if has_imports && has_vars { out.push('\n'); }
        if has_vars {
            for line in &var_lines { out.push_str(line); out.push('\n'); }
        }
    }

fn format_request_block(regions: &[&Region], out: &mut String) {
        let mut preamble: Vec<String> = Vec::new(); // pre-scripts + vars + comments in order
        let mut request_line: Option<(String, String, Option<String>)> = None;
        let mut headers: Vec<(String, String)> = Vec::new();
        let mut body_content: Vec<String> = Vec::new();
        let mut post_scripts: Vec<String> = Vec::new();
        let mut after_post: Vec<String> = Vec::new();
        let mut trailing: Vec<String> = Vec::new();
        let mut found_req = false;
        let mut touched_body = false;
        let mut body_separator = false;
        let mut has_post = false;

        for r in regions {
            match r {
                Region::PreScript { .. } => {
                    if !found_req { preamble.push(r.raw_text()); }
                }
                Region::VarDef { name, value, style, .. } => {
                    if !found_req {
                        let text = match style {
                            VarStyle::Simple => format!("@{} = {}", name, value),
                            VarStyle::Multiline { .. } => format!("@{} =>>>\n{}\n<<<", name, value),
                        };
                        preamble.push(text);
                    }
                }
                Region::RequestLine { method, url, version, .. } => {
                    request_line = Some((method.clone(), url.clone(), version.clone()));
                    found_req = true;
                }
                Region::Header { key, value, .. } => {
                    if found_req && !touched_body {
                        let cap = Self::capitalize_header_key(key);
                        headers.push((cap, value.clone()));
                    }
                }
                Region::PostScript { .. } => {
                    has_post = true;
                    post_scripts.push(r.raw_text());
                }
                Region::ExternalScript { script_type, .. } => {
                    let text = r.raw_text();
                    match script_type {
                        ScriptType::Pre => {
                            if !found_req { preamble.push(text); }
                        }
                        ScriptType::Post => {
                            has_post = true;
                            post_scripts.push(text);
                        }
                    }
                }
                Region::BlankLine => {
                    if has_post {
                        after_post.push(String::new());
                    } else if found_req && !touched_body {
                        body_separator = true;
                    } else if touched_body {
                        body_content.push(String::new());
                    }
                }
                Region::Comment(text) => {
                    let line = if text.is_empty() { "#".into() } else { format!("#{}", text) };
                    if has_post {
                        after_post.push(line);
                    } else if !found_req {
                        preamble.push(line);
                    } else {
                        touched_body = true;
                        body_content.push(line);
                    }
                }
                Region::Raw(s) => {
                    if has_post {
                        after_post.push(s.clone());
                    } else if found_req {
                        touched_body = true;
                        body_content.push(s.clone());
                    }
                }
                Region::FileUpload(_) => {
                    let text = r.raw_text();
                    if has_post {
                        after_post.push(text);
                    } else if found_req {
                        touched_body = true;
                        body_content.push(text);
                    }
                }
                Region::Import { .. } | Region::Run { .. } => {
                    trailing.push(r.raw_text());
                }
                Region::Prompt(_) => {
                    let text = r.raw_text();
                    if !found_req {
                        preamble.push(text);
                    } else if has_post {
                        after_post.push(text);
                    } else {
                        touched_body = true;
                        body_content.push(text);
                    }
                }
                _ => {}
            }
        }

        for s in &preamble { out.push_str(s); out.push('\n'); }

        if let Some((method, url, version)) = &request_line {
            out.push_str(method);
            out.push(' ');
            out.push_str(url);
            if let Some(v) = version {
                out.push(' ');
                out.push_str(v);
            }
            out.push('\n');
        }

        for (key, value) in &headers {
            out.push_str(&format!("{}: {}\n", key, value));
        }

        if touched_body || (body_separator && !post_scripts.is_empty()) {
            if !headers.is_empty() || request_line.is_some() || !preamble.is_empty() {
                out.push('\n');
            }
            // Compress consecutive blank lines in body to at most one
            let mut prev_empty = false;
            for part in &body_content {
                let is_empty = part.is_empty();
                if is_empty && prev_empty { continue; }
                prev_empty = is_empty;
                out.push_str(part);
                out.push('\n');
            }
        } else if !post_scripts.is_empty() && (request_line.is_some() || !headers.is_empty()) {
            out.push('\n');
        }

        for s in &post_scripts { out.push_str(s); out.push('\n'); }

        // Compress consecutive blank lines in after_post; strip trailing blank lines
        let mut prev_empty = false;
        let mut last_non_empty = after_post.len();
        for (idx, s) in after_post.iter().enumerate().rev() {
            if s.is_empty() { last_non_empty = idx; } else { break; }
        }
        for (idx, s) in after_post.iter().enumerate() {
            if idx >= last_non_empty { break; }
            let is_empty = s.is_empty();
            if is_empty && prev_empty { continue; }
            prev_empty = is_empty;
            out.push_str(s);
            out.push('\n');
        }

        if !trailing.is_empty() && body_separator {
            out.push('\n');
        }
        for s in &trailing { out.push_str(s); out.push('\n'); }
    }

    fn capitalize_header_key(key: &str) -> String {
        key.split('-')
            .map(|part| {
                let mut chars = part.chars();
                match chars.next() {
                    None => String::new(),
                    Some(c) => c.to_uppercase().to_string() + chars.as_str(),
                }
            })
            .collect::<Vec<_>>()
            .join("-")
    }

    /// Re-indent script code lines with 2-space nesting.
    /// Strips original indent, then applies structural indent based on Lua/JS keywords.
    fn reindent_code(lines: &[String]) -> Vec<String> {
        let stripped: Vec<&str> = lines.iter().map(|l| l.trim()).collect();
        let mut result: Vec<String> = Vec::with_capacity(lines.len());
        let mut indent: usize = 0;

        for line in &stripped {
            if line.is_empty() {
                result.push(String::new());
                continue;
            }

            let first_word = line.split_whitespace().next().unwrap_or("");
            let dedent = first_word.starts_with("end")
                || first_word == "else"
                || first_word == "elseif"
                || first_word == "until"
                || first_word.starts_with('}')
                || first_word.starts_with("})");

            if dedent && indent > 0 {
                indent -= 1;
            }

            result.push(format!("{:indent$}{}", "", line, indent = indent * 2));

            let trimmed = line.trim_end();
            let indent_next = trimmed.contains("function(")
                || trimmed.ends_with('{')
                || trimmed.ends_with("then")
                || trimmed.ends_with("do")
                || trimmed.ends_with("else")
                || trimmed.ends_with("elseif")
                || trimmed == "repeat";

            if indent_next {
                indent += 1;
            }
        }

        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // ─── Tokenizer tests ───

    #[test]
    fn test_tokenize_import() {
        let regions = Tokenizer::tokenize("import ./auth.http\nimport ./orders.http as orders\n");
        assert_eq!(regions.len(), 2);
        assert_eq!(regions[0], Region::Import {
            path: "./auth.http".to_string(),
            alias: None,
            raw: "import ./auth.http".to_string(),
        });
        assert_eq!(regions[1], Region::Import {
            path: "./orders.http".to_string(),
            alias: Some("orders".to_string()),
            raw: "import ./orders.http as orders".to_string(),
        });
    }

    #[test]
    fn test_tokenize_run() {
        let regions = Tokenizer::tokenize("run #Login\nrun #orders.ListOrders (@token=xyz)\n");
        assert_eq!(regions.len(), 2);
        assert_eq!(regions[0], Region::Run {
            target: "#Login".to_string(),
            raw: "run #Login".to_string(),
        });
    }

    #[test]
    fn test_tokenize_separator() {
        let regions = Tokenizer::tokenize("### Get users\n");
        assert_eq!(regions.len(), 1);
        assert_eq!(regions[0], Region::Separator("### Get users".to_string()));
    }

    #[test]
    fn test_tokenize_vardef_simple() {
        let regions = Tokenizer::tokenize("@base_url = https://api.example.com\n");
        assert_eq!(regions.len(), 1);
        match &regions[0] {
            Region::VarDef { name, value, style, .. } => {
                assert_eq!(name, "base_url");
                assert_eq!(value, "https://api.example.com");
                assert_eq!(*style, VarStyle::Simple);
            }
            _ => panic!("Expected VarDef"),
        }
    }

    #[test]
    fn test_tokenize_vardef_multiline() {
        let content = "@payload =>>>\n{\n  \"name\": \"test\"\n}\n<<<\n";
        let regions = Tokenizer::tokenize(content);
        assert_eq!(regions.len(), 1);
        match &regions[0] {
            Region::VarDef { name, value, style, .. } => {
                assert_eq!(name, "payload");
                assert_eq!(value, "{\n  \"name\": \"test\"\n}");
                assert_eq!(*style, VarStyle::Multiline { terminator: "<<<".to_string() });
            }
            _ => panic!("Expected VarDef"),
        }
    }

    #[test]
    fn test_tokenize_request_line() {
        let regions = Tokenizer::tokenize("GET https://api.example.com/users\n");
        assert_eq!(regions.len(), 1);
        match &regions[0] {
            Region::RequestLine { method, url, version, .. } => {
                assert_eq!(method, "GET");
                assert_eq!(url, "https://api.example.com/users");
                assert_eq!(*version, None);
            }
            _ => panic!("Expected RequestLine"),
        }
    }

    #[test]
    fn test_tokenize_request_line_with_version() {
        let regions = Tokenizer::tokenize("POST https://api.example.com/data HTTP/1.1\n");
        assert_eq!(regions.len(), 1);
        match &regions[0] {
            Region::RequestLine { method, url, version, .. } => {
                assert_eq!(method, "POST");
                assert_eq!(url, "https://api.example.com/data");
                assert_eq!(*version, Some("HTTP/1.1".to_string()));
            }
            _ => panic!("Expected RequestLine"),
        }
    }

    #[test]
    fn test_tokenize_header() {
        let regions = Tokenizer::tokenize("Content-Type: application/json\nAuthorization: Bearer token\n");
        assert_eq!(regions.len(), 2);
        match &regions[0] {
            Region::Header { key, value, .. } => {
                assert_eq!(key, "Content-Type");
                assert_eq!(value, "application/json");
            }
            _ => panic!("Expected Header"),
        }
    }

    #[test]
    fn test_tokenize_comment() {
        let regions = Tokenizer::tokenize("# This is a comment\n");
        assert_eq!(regions.len(), 1);
        match &regions[0] {
            Region::Comment(text) => assert_eq!(text, " This is a comment"),
            _ => panic!("Expected Comment"),
        }
    }

    #[test]
    fn test_tokenize_prescript_inline() {
        let regions = Tokenizer::tokenize("< {% client.log(\"pre\"); %}\n");
        assert_eq!(regions.len(), 1);
        match &regions[0] {
            Region::PreScript { code, style } => {
                assert_eq!(code, "client.log(\"pre\");");
                assert!(matches!(style, ScriptStyle::Inline(_)));
            }
            _ => panic!("Expected PreScript"),
        }
    }

    #[test]
    fn test_tokenize_prescript_multiline() {
        let content = "< {%\n  local x = 1\n  client.log(x)\n%}\n";
        let regions = Tokenizer::tokenize(content);
        assert_eq!(regions.len(), 1);
        match &regions[0] {
            Region::PreScript { code, style } => {
                assert_eq!(code, "  local x = 1\n  client.log(x)");
                assert!(matches!(style, ScriptStyle::Multiline(_)));
            }
            _ => panic!("Expected PreScript"),
        }
    }

    #[test]
    fn test_tokenize_postscript_inline() {
        let regions = Tokenizer::tokenize("> {% client.assert(response.status == 200); %}\n");
        assert_eq!(regions.len(), 1);
        match &regions[0] {
            Region::PostScript { code, .. } => {
                assert_eq!(code, "client.assert(response.status == 200);");
            }
            _ => panic!("Expected PostScript"),
        }
    }

    #[test]
    fn test_tokenize_postscript_multiline() {
        let content = "> {%\n  client.test(\"ok\", function()\n    client.assert(true)\n  end)\n%}\n";
        let regions = Tokenizer::tokenize(content);
        assert_eq!(regions.len(), 1);
        match &regions[0] {
            Region::PostScript { code, style } => {
                assert!(code.contains("client.test"));
                assert!(matches!(style, ScriptStyle::Multiline(_)));
            }
            _ => panic!("Expected PostScript"),
        }
    }

    #[test]
    fn test_tokenize_external_script_pre() {
        let regions = Tokenizer::tokenize("< ./scripts/gen.lua\n");
        assert_eq!(regions.len(), 1);
        match &regions[0] {
            Region::ExternalScript { path, script_type } => {
                assert_eq!(path, "./scripts/gen.lua");
                assert_eq!(*script_type, ScriptType::Pre);
            }
            _ => panic!("Expected ExternalScript"),
        }
    }

    #[test]
    fn test_tokenize_external_script_post() {
        let regions = Tokenizer::tokenize("> ./scripts/check.lua\n");
        assert_eq!(regions.len(), 1);
        match &regions[0] {
            Region::ExternalScript { path, script_type } => {
                assert_eq!(path, "./scripts/check.lua");
                assert_eq!(*script_type, ScriptType::Post);
            }
            _ => panic!("Expected ExternalScript"),
        }
    }

    #[test]
    fn test_tokenize_blank_line() {
        let regions = Tokenizer::tokenize("\n");
        assert_eq!(regions.len(), 1);
        assert_eq!(regions[0], Region::BlankLine);
    }

    #[test]
    fn test_tokenize_prompt() {
        let regions = Tokenizer::tokenize("# @prompt username\n# @prompt role [admin, user]\n");
        assert_eq!(regions.len(), 2);
        match &regions[0] {
            Region::Prompt(rest) => assert_eq!(rest, "username"),
            _ => panic!("Expected Prompt"),
        }
    }

    #[test]
    fn test_tokenize_full_http_file() {
        let content = "import ./auth.http\n\n@base_url = https://api.example.com\n\n### Get users\n@page_size = 20\nGET {{base_url}}/users?limit={{page_size}}\nAccept: application/json\n\n{\n  \"name\": \"test\"\n}\n\n> {%\n  client.test(\"ok\", function() end)\n%}\n";
        let regions = Tokenizer::tokenize(content);
        assert!(regions.len() > 10);
    }

    // ─── Formatter tests ───

    #[test]
    fn test_format_var_spacing() {
        let input = "@base_url=https://api.example.com\n@token=abc123\n\n### Test\nGET /api\n";
        let output = Formatter::format(input);
        assert!(output.contains("@base_url = https://api.example.com"));
        assert!(output.contains("@token = abc123"));
    }

    #[test]
    fn test_format_header_capitalization() {
        let input = "### Test\nGET /api\ncontent-type: application/json\n\n";
        let output = Formatter::format(input);
        assert!(output.contains("Content-Type: application/json"));
        assert!(!output.contains("content-type:"));
    }

    #[test]
    fn test_format_separator_blank_line() {
        let input = "### First\nGET /api/1\n### Second\nGET /api/2\n";
        let output = Formatter::format(input);
        assert!(output.contains("### First\nGET /api/1\n\n### Second"));
    }

    #[test]
    fn test_format_trailing_whitespace_removed() {
        let input = "### Test\nGET /api\ncontent-type: application/json    \n\n";
        let output = Formatter::format(input);
        assert!(!output.contains("    \n"));
    }

    #[test]
    fn test_format_trailing_newline() {
        let input = "### Test\nGET /api\n";
        let output = Formatter::format(input);
        assert!(output.ends_with('\n'));
        let count = output.chars().filter(|&c| c == '\n').count();
        // Should have exactly: "### Test\nGET /api\n" = 2 newlines
        assert_eq!(count, 2);
    }

    #[test]
    fn test_format_import_preserved() {
        let input = "import ./auth.http\n\n### Test\nGET /api\n";
        let output = Formatter::format(input);
        assert!(output.contains("import ./auth.http"));
    }

    #[test]
    fn test_format_run_preserved() {
        let input = "import ./auth.http\n\n@base_url = x\n\n### Test\nGET /api\n\nrun #Login\n";
        let output = Formatter::format(input);
        assert!(output.contains("run #Login"));
    }

    #[test]
    fn test_format_multiline_var_preserved() {
        let input = "@headers =>>>\nAuthorization: token\nX-Custom: yes\n<<<\n\n### Test\nGET /api\n{{headers}}\n";
        let output = Formatter::format(input);
        assert!(output.contains("@headers =>>>"));
        assert!(output.contains("Authorization: token"));
        assert!(output.contains("<<<"));
    }

    #[test]
    fn test_format_prescript_preserved() {
        let input = "### Test\n< {%\n  local x = 1\n%}\nGET /api\n";
        let output = Formatter::format(input);
        assert!(output.contains("< {%"));
        assert!(output.contains("local x = 1"));
        assert!(output.contains("%}"));
    }

    #[test]
    fn test_format_postscript_preserved() {
        let input = "### Test\nGET /api\n\n> {%\n  client.test(\"ok\", function() end)\n%}\n";
        let output = Formatter::format(input);
        assert!(output.contains("> {%"));
        assert!(output.contains("client.test"));
        assert!(output.contains("%}"));
    }

    #[test]
    fn test_format_roundtrip_identity() {
        let input = "### Get users\nGET /api/users\nAccept: application/json\n\n{\"name\":\"test\"}\n";
        // Format should not lose information
        let output = Formatter::format(input);
        assert!(output.contains("GET /api/users"));
        assert!(output.contains("Accept: application/json"));
        assert!(output.contains("{\"name\":\"test\"}"));
    }

    #[test]
    fn test_format_consecutive_blank_lines_compressed() {
        let input = "### First\nGET /api/1\n\n\n\n### Second\nGET /api/2\n";
        let output = Formatter::format(input);
        // Should have exactly one blank line between blocks
        assert!(output.contains("GET /api/1\n\n### Second"));
        assert!(!output.contains("GET /api/1\n\n\n### Second"));
    }

    #[test]
    fn test_format_prompt_preserved() {
        let input = "# @prompt username\n\n### Test\nGET /api\n";
        let output = Formatter::format(input);
        assert!(output.contains("# @prompt username"));
    }

    #[test]
    fn test_format_external_script_preserved() {
        let input = "### Test\n< ./scripts/gen.lua\nGET /api\n> ./scripts/check.lua\n";
        let output = Formatter::format(input);
        assert!(output.contains("< ./scripts/gen.lua"));
        assert!(output.contains("> ./scripts/check.lua"));
    }

    #[test]
    fn test_reindent_empty() {
        let result = Formatter::reindent_code(&[]);
        assert!(result.is_empty());
    }

    #[test]
    fn test_reindent_no_nesting() {
        let lines = vec!["    client.log(1)".to_string(), "  client.log(2)".to_string()];
        let result = Formatter::reindent_code(&lines);
        assert_eq!(result, vec!["client.log(1)", "client.log(2)"]);

        let output = Formatter::format("### Test\n< {%\n    client.log(1)\n  client.log(2)\n%}\nGET /api\n");
        assert!(output.contains("client.log(1)\nclient.log(2)"));
    }

    #[test]
    fn test_reindent_function_body() {
        let lines = vec![
            "client.test(\"ok\", function()".to_string(),
            "client.assert(true)".to_string(),
            "end)".to_string(),
        ];
        let result = Formatter::reindent_code(&lines);
        assert_eq!(result[0], "client.test(\"ok\", function()");
        assert_eq!(result[1], "  client.assert(true)");
        assert_eq!(result[2], "end)");
    }

    #[test]
    fn test_reindent_nested_functions() {
        let lines = vec![
            "fn_a(function()".to_string(),
            "fn_b(function()".to_string(),
            "inner()".to_string(),
            "end)".to_string(),
            "end)".to_string(),
        ];
        let result = Formatter::reindent_code(&lines);
        assert_eq!(result[0], "fn_a(function()");
        assert_eq!(result[1], "  fn_b(function()");
        assert_eq!(result[2], "    inner()");
        assert_eq!(result[3], "  end)");
        assert_eq!(result[4], "end)");
    }

    #[test]
    fn test_reindent_if_then_end() {
        let lines = vec![
            "if x then".to_string(),
            "do_it()".to_string(),
            "end".to_string(),
        ];
        let result = Formatter::reindent_code(&lines);
        assert_eq!(result[0], "if x then");
        assert_eq!(result[1], "  do_it()");
        assert_eq!(result[2], "end");
    }

    #[test]
    fn test_reindent_if_else_end() {
        let lines = vec![
            "if x then".to_string(),
            "a()".to_string(),
            "else".to_string(),
            "b()".to_string(),
            "end".to_string(),
        ];
        let result = Formatter::reindent_code(&lines);
        assert_eq!(result[0], "if x then");
        assert_eq!(result[1], "  a()");
        assert_eq!(result[2], "else");
        assert_eq!(result[3], "  b()");
        assert_eq!(result[4], "end");
    }

    #[test]
    fn test_reindent_braces() {
        let lines = vec![
            "client.test(\"ok\", function() {".to_string(),
            "client.assert(true);".to_string(),
            "});".to_string(),
        ];
        let result = Formatter::reindent_code(&lines);
        assert_eq!(result[0], "client.test(\"ok\", function() {");
        assert_eq!(result[1], "  client.assert(true);");
        assert_eq!(result[2], "});");
    }

    #[test]
    fn test_reindent_for_do_end() {
        let lines = vec![
            "for i=1,10 do".to_string(),
            "process(i)".to_string(),
            "end".to_string(),
        ];
        let result = Formatter::reindent_code(&lines);
        assert_eq!(result[0], "for i=1,10 do");
        assert_eq!(result[1], "  process(i)");
        assert_eq!(result[2], "end");
    }

    #[test]
    fn test_reindent_blank_lines_preserved() {
        let lines = vec![
            "if x then".to_string(),
            "".to_string(),
            "do_it()".to_string(),
            "end".to_string(),
        ];
        let result = Formatter::reindent_code(&lines);
        assert_eq!(result[0], "if x then");
        assert_eq!(result[1], "");
        assert_eq!(result[2], "  do_it()");
        assert_eq!(result[3], "end");
    }

    #[test]
    fn test_reindent_multiline_comment_no_false_positive() {
        let lines = vec![
            "do_it()".to_string(),
            "-- this is not an end".to_string(),
        ];
        let result = Formatter::reindent_code(&lines);
        assert_eq!(result[0], "do_it()");
        assert_eq!(result[1], "-- this is not an end");
    }

    #[test]
    fn test_format_prescript_reindented() {
        let input = "### Test\n< {%\n  client.test(\"ok\", function()\n    client.assert(true)\n  end)\n%}\nGET /api\n";
        let output = Formatter::format(input);
        let expected = "### Test\n< {%\nclient.test(\"ok\", function()\n  client.assert(true)\nend)\n%}\nGET /api\n";
        assert_eq!(output, expected);
    }

    #[test]
    fn test_format_prescript_fixes_bad_indent() {
        let input = "### Test\n< {%\n        client.test(\"ok\", function()\n                client.assert(true)\n        end)\n%}\nGET /api\n";
        let output = Formatter::format(input);
        let expected = "### Test\n< {%\nclient.test(\"ok\", function()\n  client.assert(true)\nend)\n%}\nGET /api\n";
        assert_eq!(output, expected);
    }
}
