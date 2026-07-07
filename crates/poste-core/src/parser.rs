use crate::request::{Protocol, Request};
use anyhow::Result;
use regex::Regex;
use std::collections::HashMap;
use std::sync::OnceLock;

/// Unified variable resolver with a clearly defined priority chain.
///
/// Priority (higher wins):
///   1. import_params  — caller-specified overrides (e.g. `run #Login (@env=staging)`)
///   2. request_vars   — `@var` definitions inside a request block + pre-script injected vars
///   3. file_vars      — `@var` definitions in file header (before the first `###`)
///   4. session_vars   — `client.global` variables (from Lua → CLI)
///   5. script_vars    — `script_variables` table (from Lua → CLI)
///   6. env            — `env.json` environment variables
///   7. magic          — built-in functions ($timestamp, $uuid, $date, $randomInt)
#[derive(Debug, Clone)]
pub struct VarResolver {
    import_params: HashMap<String, String>,
    request_vars: HashMap<String, String>,
    file_vars: HashMap<String, String>,
    session_vars: HashMap<String, String>,
    script_vars: HashMap<String, String>,
    env: HashMap<String, String>,
}

impl Default for VarResolver {
    fn default() -> Self {
        Self::new()
    }
}

impl VarResolver {
    /// Create an empty resolver.
    pub fn new() -> Self {
        Self {
            import_params: HashMap::new(),
            request_vars: HashMap::new(),
            file_vars: HashMap::new(),
            session_vars: HashMap::new(),
            script_vars: HashMap::new(),
            env: HashMap::new(),
        }
    }

    // -- Builder-style setters --

    pub fn with_import_params(mut self, vars: HashMap<String, String>) -> Self {
        self.import_params = vars;
        self
    }

    pub fn with_request_vars(mut self, vars: HashMap<String, String>) -> Self {
        self.request_vars = vars;
        self
    }

    pub fn with_file_vars(mut self, vars: HashMap<String, String>) -> Self {
        self.file_vars = vars;
        self
    }

    pub fn with_session_vars(mut self, vars: HashMap<String, String>) -> Self {
        self.session_vars = vars;
        self
    }

    pub fn with_script_vars(mut self, vars: HashMap<String, String>) -> Self {
        self.script_vars = vars;
        self
    }

    pub fn with_env(mut self, vars: HashMap<String, String>) -> Self {
        self.env = vars;
        self
    }

    /// Resolve a single variable by name, following the priority chain.
    /// Returns `None` if the variable is not found in any layer (including magic).
    pub fn resolve(&self, name: &str) -> Option<String> {
        if let Some(val) = self
            .import_params
            .get(name)
            .or_else(|| self.request_vars.get(name))
            .or_else(|| self.file_vars.get(name))
            .or_else(|| self.session_vars.get(name))
            .or_else(|| self.script_vars.get(name))
            .or_else(|| self.env.get(name))
        {
            return Some(val.clone());
        }
        Self::resolve_magic_var(name)
    }

    /// Resolve all `{{var}}` placeholders in the input string using the priority chain.
    /// Iteratively resolves: if `{{token}}` → `{{admin_token}}`, another pass resolves the inner ref.
    /// Caps at 20 iterations to prevent infinite loops from circular references.
    pub fn substitute(&self, input: &str) -> String {
        static VAR_RE: OnceLock<Regex> = OnceLock::new();
        let re = VAR_RE.get_or_init(|| {
            Regex::new(r"\{\{([^}]+)\}\}").expect("valid literal regex: {{var}}")
        });
        let mut result = input.to_string();
        for _ in 0..20 {
            let next = re
                .replace_all(&result, |caps: &regex::Captures| {
                    let var_name = &caps[1];
                    self.resolve(var_name)
                        .unwrap_or_else(|| caps[0].to_string())
                })
                .to_string();
            if next == result {
                break;
            }
            result = next;
        }
        result
    }

    /// Resolve magic variables ($timestamp, $uuid, $date, $randomInt).
    fn resolve_magic_var(name: &str) -> Option<String> {
        use std::time::{SystemTime, UNIX_EPOCH};
        match name {
            "$timestamp" => {
                let ts = SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_secs();
                let rnd: u64 = rand::random::<u64>() % 900000 + 100000;
                Some(format!("{}{}", ts, rnd))
            }
            "$uuid" => {
                let uuid = uuid::Uuid::new_v4();
                Some(uuid.to_string())
            }
            "$date" => {
                let now = chrono::Local::now();
                Some(now.format("%Y-%m-%d").to_string())
            }
            "$randomInt" => {
                let val: u64 = rand::random::<u64>() % 10000000;
                Some(val.to_string())
            }
            _ => None,
        }
    }
}

pub struct Parser {
    env: HashMap<String, String>,
}

impl Parser {
    pub fn new(env_vars: HashMap<String, String>) -> Self {
        Self { env: env_vars }
    }

    /// Detect protocol from file extension (without the leading dot).
    pub fn detect_protocol(file_ext: &str) -> Protocol {
        match file_ext.to_lowercase().as_str() {
            "redis" => Protocol::Redis,
            "sql" => Protocol::Postgres, // default .sql to Postgres; can be overridden via @protocol directive
            "sqlite" => Protocol::Sqlite,
            "mysql" => Protocol::Mysql,
            _ => Protocol::Http, // .http, .rest, and anything else
        }
    }

    /// Parse a request file and extract the request at the given line.
    /// `file_ext` is the file extension (without dot), used for protocol detection.
    pub fn parse_at_line(&self, content: &str, line_num: usize, file_ext: &str) -> Result<Request> {
        let protocol = Self::detect_protocol(file_ext);

        // Extract file-level variables (before first ###)
        let file_vars = self.extract_file_variables(content);

        // Split content into request blocks by ### markers
        let mut blocks = Vec::new();
        let mut current_block = String::new();

        for line in content.lines() {
            if line.trim().starts_with("###") && !current_block.is_empty() {
                blocks.push(current_block.clone());
                current_block.clear();
            }
            current_block.push_str(line);
            current_block.push('\n');
        }
        if !current_block.is_empty() {
            blocks.push(current_block);
        }

        // Find the block containing the cursor line
        let mut current_line = 0;
        for block in &blocks {
            let block_lines = block.lines().count();
            if current_line + block_lines >= line_num {
                return self.parse_block(block, protocol, &file_vars);
            }
            current_line += block_lines;
        }

        anyhow::bail!("No request found at line {}", line_num);
    }

    fn parse_block(
        &self,
        block: &str,
        protocol: Protocol,
        file_vars: &HashMap<String, String>,
    ) -> Result<Request> {
        let lines: Vec<&str> = block.lines().collect();

        // First line should be ### Request Name
        let mut name = None;
        let mut request_lines = Vec::new();
        let mut request_vars = HashMap::new();
        let mut found_request_line = false;

        let mut in_assertion_block = false;
        let mut in_prescript_block = false;

        let mut i = 0;
        while i < lines.len() {
            let line = lines[i];
            let trimmed = line.trim();
            i += 1;

            // Check for pre-request script block start: < {%
            if trimmed.starts_with("<") && trimmed.contains("{%") && !trimmed.contains("%}") {
                in_prescript_block = true;
                continue;
            }

            // Check for pre-request script block end: %}
            if in_prescript_block && trimmed == "%}" {
                in_prescript_block = false;
                continue;
            }

            // Skip lines inside pre-request script blocks
            if in_prescript_block {
                continue;
            }

            // Single-line pre-request script: < {% ... %}
            if trimmed.starts_with("<") && trimmed.contains("{%") && trimmed.contains("%}") {
                continue;
            }

            // External pre-request script: < ./path.lua
            if trimmed.starts_with("<")
                && (trimmed.contains("./") || trimmed.contains("../"))
                && trimmed.ends_with(".lua")
            {
                continue;
            }

            // Check for assertion block start: > {%
            if trimmed.starts_with(">") && trimmed.contains("{%") && !trimmed.contains("%}") {
                in_assertion_block = true;
                continue;
            }

            // Check for assertion block end: %}
            if in_assertion_block && trimmed == "%}" {
                in_assertion_block = false;
                continue;
            }

            // Skip lines inside assertion blocks
            if in_assertion_block {
                continue;
            }

            // Single-line assertion: > {% ... %}
            if trimmed.starts_with(">") && trimmed.contains("{%") && trimmed.contains("%}") {
                continue;
            }

            // External assertion script: > ./path.lua
            if trimmed.starts_with(">")
                && (trimmed.contains("./") || trimmed.contains("../"))
                && trimmed.ends_with(".lua")
            {
                continue;
            }

            if trimmed.starts_with("###") {
                // Extract name after ###
                name = Some(trimmed.trim_start_matches("###").trim().to_string());
            } else if !found_request_line {
                // Multi-line request-level var: @name=>>> ... <<<
                if let Some(var_name) = self.parse_multiline_var_start(line) {
                    let mut value_lines = Vec::new();
                    loop {
                        if i >= lines.len() {
                            break;
                        }
                        let next = lines[i];
                        i += 1;
                        if next.trim() == "<<<" {
                            break;
                        }
                        value_lines.push(next);
                    }
                    let raw_value = value_lines.join("\n");
                    let resolved = self.substitute_vars(&raw_value, file_vars, &request_vars);
                    request_vars.insert(var_name, resolved);
                    continue;
                }

                // Check if this is a variable definition before the request line
                if let Some((key, value)) = self.parse_variable_line(line) {
                    // Resolve {{var}} references using file-level and earlier request-level vars
                    let resolved = self.substitute_vars(&value, file_vars, &request_vars);
                    request_vars.insert(key, resolved);
                } else if !trimmed.is_empty()
                    && !trimmed.starts_with('#')
                    && !trimmed.starts_with('>')
                {
                    // This is the actual request line, mark it and add to request_lines
                    found_request_line = true;
                    request_lines.push(line);
                }
            } else {
                // After request line, add to request body (skip assertion markers and comments)
                if !trimmed.starts_with(">") && !trimmed.starts_with('#') {
                    request_lines.push(line);
                }
            }
        }

        // For HTTP, connection is embedded in the request line (URL)
        // For other protocols, we need @connection directive (block-level, then file-level fallback)
        let connection = match protocol {
            Protocol::Http => String::new(), // Will be extracted from request line
            _ => self
                .extract_connection(block, file_vars, &request_vars)
                .or_else(|_| {
                    // Fallback: look for @connection in file-level variables
                    file_vars.get("connection").cloned().ok_or_else(|| {
                        anyhow::anyhow!(
                            "No @connection directive found in request block or file header"
                        )
                    })
                })?,
        };

        // Reconstruct body without the ### line
        let body = self.substitute_vars(&request_lines.join("\n"), file_vars, &request_vars);

        Ok(Request {
            name,
            protocol,
            connection,
            body: body.into_bytes(),
            raw_body: String::new(), // filled by CLI after resolve_file_includes
        })
    }

    fn extract_connection(
        &self,
        block: &str,
        file_vars: &HashMap<String, String>,
        request_vars: &HashMap<String, String>,
    ) -> Result<String> {
        let re = Regex::new(r"(?:--|#)\s*@connection\s+(.+)")?;
        for line in block.lines() {
            if let Some(caps) = re.captures(line) {
                return Ok(self.substitute_vars(caps[1].trim(), file_vars, request_vars));
            }
        }
        anyhow::bail!("No @connection directive found in request block");
    }

    /// Parse a variable definition line in format `@name = value` or `@name value`
    fn parse_variable_line(&self, line: &str) -> Option<(String, String)> {
        let trimmed = line.trim();
        if !trimmed.starts_with('@') {
            return None;
        }

        let content = &trimmed[1..]; // Remove @

        // Try format: @name = value
        if let Some((name, value)) = content.split_once('=') {
            let name = name.trim().to_string();
            let mut value = value.trim().to_string();
            Self::strip_quotes(&mut value);
            if !name.is_empty() {
                return Some((name, value));
            }
        }

        // Try format: @name value
        if let Some((name, value)) = content.split_once(char::is_whitespace) {
            let name = name.trim().to_string();
            let mut value = value.trim().to_string();
            Self::strip_quotes(&mut value);
            if !name.is_empty() {
                return Some((name, value));
            }
        }

        None
    }

    /// Strip surrounding double or single quotes from a string value.
    fn strip_quotes(value: &mut String) {
        if (value.starts_with('"') && value.ends_with('"'))
            || (value.starts_with('\'') && value.ends_with('\''))
        {
            *value = value[1..value.len() - 1].to_string();
        }
    }

    /// Check if a line starts a multi-line variable definition (@name=>>> or @name >>>).
    /// Returns the variable name if a multi-line block starts here, None otherwise.
    fn parse_multiline_var_start(&self, line: &str) -> Option<String> {
        let trimmed = line.trim();
        if !trimmed.starts_with('@') {
            return None;
        }

        let content = &trimmed[1..]; // Remove @

        // Format: @name=>>>  or  @name = >>>
        if let Some((name, marker)) = content.split_once('=') {
            if marker.trim() == ">>>" {
                let name = name.trim().to_string();
                if !name.is_empty() {
                    return Some(name);
                }
            }
        }

        // Format: @name >>>  (without equals sign)
        if let Some((name, marker)) = content.split_once(char::is_whitespace) {
            if marker.trim() == ">>>" {
                let name = name.trim().to_string();
                if !name.is_empty() {
                    return Some(name);
                }
            }
        }

        None
    }

    /// Extract file-level variables from content (before first ###).
    /// Supports:
    ///   - @name = value           — single-line, quoted values stripped
    ///   - @name value             — space-delimited
    ///   - @name=>>> ... <<<       — multi-line block value
    ///   - {{var}} references in values are resolved using earlier-defined vars.
    pub fn extract_file_variables(&self, content: &str) -> HashMap<String, String> {
        let mut vars = HashMap::new();
        let lines: Vec<&str> = content.lines().collect();
        let mut i = 0;

        static CONNECTION_RE: OnceLock<Regex> = OnceLock::new();
        let connection_re = CONNECTION_RE.get_or_init(|| {
            Regex::new(r"(?:--|#)\s*@connection\s+(.+)").expect("valid literal regex: @connection")
        });

        while i < lines.len() {
            let line = lines[i];
            if line.trim().starts_with("###") {
                break; // Stop at first request
            }

            i += 1;

            // Multi-line var: @name=>>> ... <<<
            if let Some(name) = self.parse_multiline_var_start(line) {
                let mut value_lines = Vec::new();
                loop {
                    if i >= lines.len() {
                        break;
                    }
                    let next = lines[i];
                    i += 1;
                    if next.trim() == "<<<" {
                        break;
                    }
                    if next.trim().starts_with("###") {
                        i -= 1; // back up so outer loop sees ###
                        break;
                    }
                    value_lines.push(next);
                }
                let raw_value = value_lines.join("\n");
                let resolved = self.substitute_vars(&raw_value, &vars, &HashMap::new());
                vars.insert(name, resolved);
                continue;
            }

            if let Some((key, value)) = self.parse_variable_line(line) {
                // Resolve {{var}} references within the value using already-extracted vars
                let resolved = self.substitute_vars(&value, &vars, &HashMap::new());
                vars.insert(key, resolved);
            }

            // Also parse @connection directives in comments (# @connection ... or -- @connection ...)
            if let Some(caps) = connection_re.captures(line) {
                vars.insert("connection".to_string(), caps[1].trim().to_string());
            }
        }

        vars
    }

    fn substitute_vars(
        &self,
        input: &str,
        file_vars: &HashMap<String, String>,
        request_vars: &HashMap<String, String>,
    ) -> String {
        let resolver = VarResolver::new()
            .with_request_vars(request_vars.clone())
            .with_file_vars(file_vars.clone())
            .with_env(self.env.clone());
        resolver.substitute(input)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // ---- VarResolver unit tests ----

    #[test]
    fn test_var_resolver_empty() {
        let r = VarResolver::new();
        assert_eq!(r.resolve("anything"), None);
    }

    #[test]
    fn test_var_resolver_import_params_highest_priority() {
        let r = VarResolver::new()
            .with_import_params(HashMap::from([("key".into(), "import".into())]))
            .with_request_vars(HashMap::from([("key".into(), "request".into())]))
            .with_file_vars(HashMap::from([("key".into(), "file".into())]))
            .with_session_vars(HashMap::from([("key".into(), "session".into())]))
            .with_env(HashMap::from([("key".into(), "env".into())]));
        assert_eq!(r.resolve("key"), Some("import".to_string()));
    }

    #[test]
    fn test_var_resolver_request_vars_second_priority() {
        let r = VarResolver::new()
            .with_request_vars(HashMap::from([("key".into(), "request".into())]))
            .with_file_vars(HashMap::from([("key".into(), "file".into())]))
            .with_session_vars(HashMap::from([("key".into(), "session".into())]))
            .with_env(HashMap::from([("key".into(), "env".into())]));
        assert_eq!(r.resolve("key"), Some("request".to_string()));
    }

    #[test]
    fn test_var_resolver_file_vars_third_priority() {
        let r = VarResolver::new()
            .with_file_vars(HashMap::from([("key".into(), "file".into())]))
            .with_session_vars(HashMap::from([("key".into(), "session".into())]))
            .with_env(HashMap::from([("key".into(), "env".into())]));
        assert_eq!(r.resolve("key"), Some("file".to_string()));
    }

    #[test]
    fn test_var_resolver_session_vars_fourth_priority() {
        let r = VarResolver::new()
            .with_session_vars(HashMap::from([("key".into(), "session".into())]))
            .with_env(HashMap::from([("key".into(), "env".into())]));
        assert_eq!(r.resolve("key"), Some("session".to_string()));
    }

    #[test]
    fn test_var_resolver_script_vars_same_level_as_session() {
        // script_vars and session_vars are same priority; session_vars checked first
        let r = VarResolver::new()
            .with_session_vars(HashMap::from([("key".into(), "session".into())]))
            .with_script_vars(HashMap::from([("key".into(), "script".into())]));
        assert_eq!(r.resolve("key"), Some("session".to_string()));
    }

    #[test]
    fn test_var_resolver_env_vars_fifth_priority() {
        let r = VarResolver::new()
            .with_env(HashMap::from([("key".into(), "env".into())]));
        assert_eq!(r.resolve("key"), Some("env".to_string()));
    }

    #[test]
    fn test_var_resolver_magic_var_fallback() {
        let r = VarResolver::new();
        let ts = r.resolve("$timestamp");
        assert!(ts.is_some());
        let val = ts.unwrap();
        assert!(val.chars().all(|c| c.is_ascii_digit()));
        assert!(val.len() > 10);

        let uuid_val = r.resolve("$uuid").unwrap();
        assert_eq!(uuid_val.len(), 36);
    }

    #[test]
    fn test_var_resolver_fallback_to_next_layer_when_missing() {
        let r = VarResolver::new()
            .with_import_params(HashMap::from([("a".into(), "1".into())]))
            .with_request_vars(HashMap::from([("b".into(), "2".into())]))
            .with_file_vars(HashMap::from([("c".into(), "3".into())]))
            .with_session_vars(HashMap::from([("d".into(), "4".into())]))
            .with_env(HashMap::from([("e".into(), "5".into())]));
        assert_eq!(r.resolve("a"), Some("1".to_string()));
        assert_eq!(r.resolve("b"), Some("2".to_string()));
        assert_eq!(r.resolve("c"), Some("3".to_string()));
        assert_eq!(r.resolve("d"), Some("4".to_string()));
        assert_eq!(r.resolve("e"), Some("5".to_string()));
        assert_eq!(r.resolve("f"), None);
    }

    #[test]
    fn test_var_resolver_substitute_basic() {
        let r = VarResolver::new()
            .with_env(HashMap::from([("name".into(), "World".into())]));
        let result = r.substitute("Hello, {{name}}!");
        assert_eq!(result, "Hello, World!");
    }

    #[test]
    fn test_var_resolver_substitute_multiple() {
        let r = VarResolver::new()
            .with_env(HashMap::from([
                ("first".into(), "Jane".into()),
                ("last".into(), "Doe".into()),
            ]));
        let result = r.substitute("{{first}} {{last}}");
        assert_eq!(result, "Jane Doe");
    }

    #[test]
    fn test_var_resolver_substitute_not_found_preserved() {
        let r = VarResolver::new();
        let result = r.substitute("Hello, {{missing}}!");
        assert_eq!(result, "Hello, {{missing}}!");
    }

    #[test]
    fn test_var_resolver_substitute_no_vars() {
        let r = VarResolver::new();
        let result = r.substitute("no variables at all");
        assert_eq!(result, "no variables at all");
    }

    #[test]
    fn test_var_resolver_substitute_magic_vars() {
        let r = VarResolver::new();
        let result = r.substitute("{{$timestamp}}");
        assert!(result.chars().all(|c| c.is_ascii_digit()));
        assert!(result.len() > 10);
    }

    #[test]
    fn test_var_resolver_priority_chain_in_substitute() {
        let r = VarResolver::new()
            .with_file_vars(HashMap::from([("host".into(), "file.com".into())]))
            .with_request_vars(HashMap::from([("host".into(), "request.com".into())]))
            .with_env(HashMap::from([("host".into(), "env.com".into())]));
        // request_vars has highest priority among these three
        let result = r.substitute("{{host}}");
        assert_eq!(result, "request.com");
    }

    #[test]
    fn test_var_resolver_substitute_iterative_resolution() {
        let r = VarResolver::new()
            .with_file_vars(HashMap::from([
                ("token".into(), "admin".into()),
                ("auth".into(), "Bearer {{token}}".into()),
            ]));
        let result = r.substitute("Authorization: {{auth}}");
        assert_eq!(result, "Authorization: Bearer admin");
    }

    // ---- Parser existing tests ----

    #[test]
    fn test_substitute_vars_simple() {
        let mut env_vars = HashMap::new();
        env_vars.insert("name".to_string(), "John".to_string());
        let parser = Parser::new(env_vars);
        let result = parser.substitute_vars("Hello, {{name}}!", &HashMap::new(), &HashMap::new());
        assert_eq!(result, "Hello, John!");
    }

    #[test]
    fn test_substitute_vars_multiple() {
        let mut env_vars = HashMap::new();
        env_vars.insert("first".to_string(), "Jane".to_string());
        env_vars.insert("last".to_string(), "Doe".to_string());
        let parser = Parser::new(env_vars);
        let result = parser.substitute_vars("{{first}} {{last}}", &HashMap::new(), &HashMap::new());
        assert_eq!(result, "Jane Doe");
    }

    #[test]
    fn test_substitute_vars_not_found() {
        let parser = Parser::new(HashMap::new());
        let result = parser.substitute_vars("{{missing}}", &HashMap::new(), &HashMap::new());
        assert_eq!(result, "{{missing}}");
    }

    #[test]
    fn test_substitute_vars_no_vars() {
        let parser = Parser::new(HashMap::new());
        let result = parser.substitute_vars("no variables", &HashMap::new(), &HashMap::new());
        assert_eq!(result, "no variables");
    }

    #[test]
    fn test_extract_connection_success() {
        let parser = Parser::new(HashMap::new());
        let block = "# @connection redis://localhost:6379\nGET user:123";
        let result = parser
            .extract_connection(block, &HashMap::new(), &HashMap::new())
            .unwrap();
        assert_eq!(result, "redis://localhost:6379");
    }

    #[test]
    fn test_extract_connection_missing() {
        let parser = Parser::new(HashMap::new());
        let block = "GET http://example.com";
        let result = parser.extract_connection(block, &HashMap::new(), &HashMap::new());
        assert!(result.is_err());
    }

    #[test]
    fn test_extract_connection_postgres() {
        let parser = Parser::new(HashMap::new());
        let block = "# @connection postgres://user:pass@localhost:5432/db\nSELECT 1";
        let result = parser
            .extract_connection(block, &HashMap::new(), &HashMap::new())
            .unwrap();
        assert_eq!(result, "postgres://user:pass@localhost:5432/db");
    }

    #[test]
    fn test_extract_connection_with_vars() {
        let mut env_vars = HashMap::new();
        env_vars.insert("db_host".to_string(), "localhost".to_string());
        env_vars.insert("db_port".to_string(), "5432".to_string());
        let parser = Parser::new(env_vars);
        let block = "# @connection postgres://user:pass@{{db_host}}:{{db_port}}/mydb\nSELECT 1";
        let result = parser
            .extract_connection(block, &HashMap::new(), &HashMap::new())
            .unwrap();
        assert_eq!(result, "postgres://user:pass@localhost:5432/mydb");
    }

    #[test]
    fn test_parse_variable_line_equals() {
        let parser = Parser::new(HashMap::new());
        let result = parser.parse_variable_line("@host = https://example.com");
        assert_eq!(
            result,
            Some(("host".to_string(), "https://example.com".to_string()))
        );
    }

    #[test]
    fn test_parse_variable_line_space() {
        let parser = Parser::new(HashMap::new());
        let result = parser.parse_variable_line("@host https://example.com");
        assert_eq!(
            result,
            Some(("host".to_string(), "https://example.com".to_string()))
        );
    }

    #[test]
    fn test_parse_variable_line_invalid() {
        let parser = Parser::new(HashMap::new());
        assert_eq!(parser.parse_variable_line("GET https://example.com"), None);
        assert_eq!(parser.parse_variable_line("# comment"), None);
        assert_eq!(parser.parse_variable_line("@host"), None);
    }

    #[test]
    fn test_extract_file_variables() {
        let parser = Parser::new(HashMap::new());
        let content = r#"@host = https://api.example.com
@token = abc123

### Request 1
GET {{host}}/users
"#;
        let vars = parser.extract_file_variables(content);
        assert_eq!(
            vars.get("host"),
            Some(&"https://api.example.com".to_string())
        );
        assert_eq!(vars.get("token"), Some(&"abc123".to_string()));
    }

    #[test]
    fn test_file_variables_stop_at_request() {
        let parser = Parser::new(HashMap::new());
        let content = r#"@host = https://api.example.com

### Request 1
@should_not_parse = value
GET /users
"#;
        let vars = parser.extract_file_variables(content);
        assert_eq!(vars.len(), 1);
        assert_eq!(
            vars.get("host"),
            Some(&"https://api.example.com".to_string())
        );
        assert_eq!(vars.get("should_not_parse"), None);
    }

    #[test]
    fn test_request_variables() {
        let parser = Parser::new(HashMap::new());
        let block = r#"### Request 1
@user_id = 123
@api_key = secret
GET /users/{{user_id}}
Authorization: Bearer {{api_key}}
"#;
        let request = parser
            .parse_block(block, Protocol::Http, &HashMap::new())
            .unwrap();
        assert!(request.body_str().contains("GET /users/123"));
        assert!(request.body_str().contains("Authorization: Bearer secret"));
    }

    #[test]
    fn test_variable_priority_integration() {
        let mut env_vars = HashMap::new();
        env_vars.insert("host".to_string(), "env.com".to_string());
        env_vars.insert("port".to_string(), "8080".to_string());

        let parser = Parser::new(env_vars);

        let content = r#"@host = file.com
@timeout = 30

### Request 1
@host = request.com
GET http://{{host}}:{{port}}/{{timeout}}
"#;

        let request = parser.parse_at_line(content, 6, "http").unwrap();

        // host should be from request_vars (highest priority)
        assert!(request.body_str().contains("http://request.com:8080/30"));
    }

    #[test]
    fn test_prescript_multiline_stripped() {
        let parser = Parser::new(HashMap::new());
        let block = "### Request 1\n< {%\n  local x = 1\n%}\nGET /api/data\n";
        let request = parser
            .parse_block(block, Protocol::Http, &HashMap::new())
            .unwrap();
        assert!(request.body_str().contains("GET /api/data"));
        assert!(!request.body_str().contains("{%"));
        assert!(!request.body_str().contains("local x"));
    }

    #[test]
    fn test_prescript_singleline_stripped() {
        let parser = Parser::new(HashMap::new());
        let block =
            "### Request 1\n< {% request.variables.set(\"token\", \"abc\") %}\nGET /api/data\n";
        let request = parser
            .parse_block(block, Protocol::Http, &HashMap::new())
            .unwrap();
        assert!(request.body_str().contains("GET /api/data"));
        assert!(!request.body_str().contains("{%"));
    }

    #[test]
    fn test_prescript_external_stripped() {
        let parser = Parser::new(HashMap::new());
        let block = "### Request 1\n< ./scripts/gen.lua\nGET /api/data\n";
        let request = parser
            .parse_block(block, Protocol::Http, &HashMap::new())
            .unwrap();
        assert!(request.body_str().contains("GET /api/data"));
        assert!(!request.body_str().contains("gen.lua"));
    }

    #[test]
    fn test_assertion_external_stripped() {
        let parser = Parser::new(HashMap::new());
        let block = "### Request 1\nGET /api/data\n> ./scripts/check.lua\n";
        let request = parser
            .parse_block(block, Protocol::Http, &HashMap::new())
            .unwrap();
        assert!(request.body_str().contains("GET /api/data"));
        assert!(!request.body_str().contains("check.lua"));
    }

    #[test]
    fn test_assertion_external_stripped_multi_block() {
        let parser = Parser::new(HashMap::new());
        let content = "### Request 1\nGET /api/data\n> ./scripts/check.lua\n\n### Request 2\nGET /api/other\n";
        let request = parser.parse_at_line(content, 2, "http").unwrap();
        assert!(request.body_str().contains("GET /api/data"));
        assert!(!request.body_str().contains("check.lua"));
    }

    #[test]
    fn test_prescript_injected_vars() {
        let parser = Parser::new(HashMap::new());
        let block = "### Request 1\n@auth_token = injected-value\nGET /api?token={{auth_token}}\n";
        let request = parser
            .parse_block(block, Protocol::Http, &HashMap::new())
            .unwrap();
        assert!(request.body_str().contains("GET /api?token=injected-value"));
    }

    // ---- @var enhancements: quote stripping, {{var}} in values, multi-line blocks ----

    #[test]
    fn test_parse_variable_line_quotes_stripped() {
        let parser = Parser::new(HashMap::new());
        let r = parser.parse_variable_line("@host = \"https://example.com\"");
        assert_eq!(
            r,
            Some(("host".to_string(), "https://example.com".to_string()))
        );
    }

    #[test]
    fn test_parse_variable_line_single_quotes_stripped() {
        let parser = Parser::new(HashMap::new());
        let r = parser.parse_variable_line("@host 'http://localhost'");
        assert_eq!(
            r,
            Some(("host".to_string(), "http://localhost".to_string()))
        );
    }

    #[test]
    fn test_file_var_references_other_file_var() {
        let parser = Parser::new(HashMap::new());
        let content = r#"@pageNum = 1
@pageSize = 10
@page = pageNum={{pageNum}}&pageSize={{pageSize}}

### Request
GET /api?{{page}}
"#;
        let vars = parser.extract_file_variables(content);
        assert_eq!(vars.get("pageNum"), Some(&"1".to_string()));
        assert_eq!(vars.get("pageSize"), Some(&"10".to_string()));
        assert_eq!(vars.get("page"), Some(&"pageNum=1&pageSize=10".to_string()));

        let req = parser.parse_at_line(content, 5, "http").unwrap();
        assert!(req.body_str().contains("GET /api?pageNum=1&pageSize=10"));
    }

    #[test]
    fn test_multiline_file_var() {
        let parser = Parser::new(HashMap::new());
        let content = r#"@token = abc123
@headers=>>>
Authorization: {{token}}
X-Custom: yes
<<<

### Request
POST /api/data
{{headers}}

{"key": "value"}
"#;
        let req = parser.parse_at_line(content, 8, "http").unwrap();
        assert!(req.body_str().contains("Authorization: abc123"));
        assert!(req.body_str().contains("X-Custom: yes"));
        assert!(req.body_str().contains("{\"key\": \"value\"}"));
    }

    #[test]
    fn test_multiline_file_var_forward_ref_resolved() {
        let parser = Parser::new(HashMap::new());
        // Iterative substitution resolves even forward references
        let content = r#"@page = id={{pageNum}}
@pageNum = 99

### Request
GET /{{page}}
"#;
        let req = parser.parse_at_line(content, 4, "http").unwrap();
        assert!(req.body_str().contains("GET /id=99"));
        assert!(!req.body_str().contains("{{pageNum}}"));
    }

    #[test]
    fn test_request_var_refers_to_file_var() {
        let parser = Parser::new(HashMap::new());
        let content = r#"@base = /api/v1

### Request
@path = {{base}}/users
GET {{path}}
"#;
        let req = parser.parse_at_line(content, 5, "http").unwrap();
        assert!(req.body_str().contains("GET /api/v1/users"));
    }

    #[test]
    fn test_multiline_request_var() {
        let parser = Parser::new(HashMap::new());
        let block = r#"### Request
@token = secret
@headers=>>>
Authorization: {{token}}
Content-Type: application/json
<<<
POST /api/data
{{headers}}
"#;
        let req = parser
            .parse_block(block, Protocol::Http, &HashMap::new())
            .unwrap();
        assert!(req.body_str().contains("POST /api/data"));
        assert!(req.body_str().contains("Authorization: secret"));
        assert!(req.body_str().contains("Content-Type: application/json"));
    }

    #[test]
    fn test_var_transitive_resolution_file_level() {
        let parser = Parser::new(HashMap::new());
        let content = r#"@admin_token = secret
@token = {{admin_token}}

### Request
GET /api
Authorization: {{token}}
"#;
        let req = parser.parse_at_line(content, 5, "http").unwrap();
        assert!(req.body_str().contains("Authorization: secret"));
        assert!(!req.body_str().contains("{{admin_token}}"));
    }

    #[test]
    fn test_var_transitive_resolution_forward_ref() {
        let parser = Parser::new(HashMap::new());
        // admin_token defined AFTER token at file level.
        // extract_file_variables can't resolve token at definition time,
        // but the body-level iterative substitution resolves the full chain.
        let content = r#"@token = {{admin_token}}
@admin_token = secret

### Request
GET /api
Authorization: {{token}}
"#;
        let req = parser.parse_at_line(content, 5, "http").unwrap();
        assert!(req.body_str().contains("Authorization: secret"));
        assert!(!req.body_str().contains("{{admin_token}}"));
    }

    #[test]
    fn test_var_transitive_resolution_request_level() {
        let parser = Parser::new(HashMap::new());
        let block = r#"### Request
@admin_token = secret
@token = {{admin_token}}
GET /api
Authorization: {{token}}
"#;
        let req = parser
            .parse_block(block, Protocol::Http, &HashMap::new())
            .unwrap();
        assert!(req.body_str().contains("Authorization: secret"));
    }

    #[test]
    fn test_magic_var_timestamp() {
        let parser = Parser::new(HashMap::new());
        let result = parser.substitute_vars("{{$timestamp}}", &HashMap::new(), &HashMap::new());
        // Should be a long numeric string (timestamp + random)
        assert!(result.len() > 10);
        assert!(result.chars().all(|c| c.is_ascii_digit()));
    }

    #[test]
    fn test_magic_var_uuid() {
        let parser = Parser::new(HashMap::new());
        let result = parser.substitute_vars("{{$uuid}}", &HashMap::new(), &HashMap::new());
        // UUID format: 8-4-4-4-12
        assert_eq!(result.len(), 36);
        assert_eq!(result.chars().filter(|&c| c == '-').count(), 4);
    }

    #[test]
    fn test_magic_var_date() {
        let parser = Parser::new(HashMap::new());
        let result = parser.substitute_vars("{{$date}}", &HashMap::new(), &HashMap::new());
        // YYYY-MM-DD
        assert_eq!(result.len(), 10);
        assert_eq!(&result[4..5], "-");
        assert_eq!(&result[7..8], "-");
    }

    #[test]
    fn test_magic_var_randomInt() {
        let parser = Parser::new(HashMap::new());
        let result = parser.substitute_vars("{{$randomInt}}", &HashMap::new(), &HashMap::new());
        let val: u64 = result.parse().unwrap();
        assert!(val < 10000000);
    }

    #[test]
    fn test_magic_var_not_found_preserved() {
        let parser = Parser::new(HashMap::new());
        let result = parser.substitute_vars("{{$unknown}}", &HashMap::new(), &HashMap::new());
        assert_eq!(result, "{{$unknown}}");
    }

    #[test]
    fn test_comments_between_blocks_excluded_from_body() {
        let parser = Parser::new(HashMap::new());
        let content = "### Request 1\nGET /api/one\n\n> {% client.test(\"a\", function() end) %}\n\n# ─────────────────\n# Comment between blocks\n# ─────────────────\n\n### Request 2\nGET /api/two\n";
        let request = parser.parse_at_line(content, 2, "http").unwrap();
        assert!(request.body_str().contains("GET /api/one"));
        assert!(
            !request.body_str().contains("Comment between blocks"),
            "body should not contain inter-block comments"
        );
        assert!(
            !request.body_str().contains("──"),
            "body should not contain inter-block comment decorations"
        );
    }

    #[test]
    fn test_magic_var_in_body() {
        let parser = Parser::new(HashMap::new());
        let content = "### Request\nPOST /api/log\nContent-Type: application/json\n\n{\"ts\": \"{{$timestamp}}\", \"uuid\": \"{{$uuid}}\"}\n";
        let request = parser
            .parse_block(content, Protocol::Http, &HashMap::new())
            .unwrap();
        assert!(!request.body_str().contains("{{$timestamp}}"));
        assert!(!request.body_str().contains("{{$uuid}}"));
        assert!(request.body_str().contains("\"ts\": \""));
        assert!(request.body_str().contains("\"uuid\": \""));
    }

    #[test]
    fn test_var_circular_ref_no_infinite_loop() {
        let parser = Parser::new(HashMap::new());
        let content = r#"@a = {{b}}
@b = {{a}}

### Request
GET /api
X-Val: {{a}}
"#;
        // Should not hang or panic — caps at 20 iterations
        let req = parser.parse_at_line(content, 5, "http").unwrap();
        let body = req.body_str();
        assert!(body.contains("X-Val: {{b}}") || body.contains("X-Val: {{a}}"));
    }
}
