use crate::request::{Request, Protocol};
use anyhow::Result;
use regex::Regex;
use std::collections::HashMap;

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
            "mongo" => Protocol::Mongodb,
            "amqp" => Protocol::Amqp,
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
            if line.trim().starts_with("###") {
                if !current_block.is_empty() {
                    blocks.push(current_block.clone());
                    current_block.clear();
                }
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

    fn parse_block(&self, block: &str, protocol: Protocol, file_vars: &HashMap<String, String>) -> Result<Request> {
        let lines = block.lines();

        // First line should be ### Request Name
        let mut name = None;
        let mut request_lines = Vec::new();
        let mut request_vars = HashMap::new();
        let mut found_request_line = false;

        for line in lines {
            if line.trim().starts_with("###") {
                // Extract name after ###
                name = Some(line.trim().trim_start_matches("###").trim().to_string());
            } else if !found_request_line {
                // Check if this is a variable definition before the request line
                if let Some((key, value)) = self.parse_variable_line(line) {
                    request_vars.insert(key, value);
                } else if !line.trim().is_empty() && !line.trim().starts_with('#') {
                    // This is the actual request line, mark it and add to request_lines
                    found_request_line = true;
                    request_lines.push(line);
                }
            } else {
                // After request line, everything is part of the request
                request_lines.push(line);
            }
        }

        // For HTTP, connection is embedded in the request line (URL)
        // For other protocols, we need @connection directive
        let connection = match protocol {
            Protocol::Http => String::new(), // Will be extracted from request line
            _ => self.extract_connection(block, file_vars, &request_vars)?,
        };

        // Reconstruct body without the ### line
        let body = self.substitute_vars(&request_lines.join("\n"), file_vars, &request_vars);

        Ok(Request {
            name,
            protocol,
            connection,
            body,
        })
    }

    fn extract_connection(&self, block: &str, file_vars: &HashMap<String, String>, request_vars: &HashMap<String, String>) -> Result<String> {
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
            let value = value.trim().to_string();
            if !name.is_empty() {
                return Some((name, value));
            }
        }

        // Try format: @name value
        if let Some((name, value)) = content.split_once(char::is_whitespace) {
            let name = name.trim().to_string();
            let value = value.trim().to_string();
            if !name.is_empty() {
                return Some((name, value));
            }
        }

        None
    }

    /// Extract file-level variables from content (before first ###)
    fn extract_file_variables(&self, content: &str) -> HashMap<String, String> {
        let mut vars = HashMap::new();

        for line in content.lines() {
            if line.trim().starts_with("###") {
                break; // Stop at first request
            }

            if let Some((key, value)) = self.parse_variable_line(line) {
                vars.insert(key, value);
            }
        }

        vars
    }

    fn substitute_vars(&self, input: &str, file_vars: &HashMap<String, String>, request_vars: &HashMap<String, String>) -> String {
        let re = Regex::new(r"\{\{(\w+)\}\}").unwrap();
        re.replace_all(input, |caps: &regex::Captures| {
            let var_name = &caps[1];
            // Priority: request_vars > file_vars > env
            request_vars
                .get(var_name)
                .or_else(|| file_vars.get(var_name))
                .or_else(|| self.env.get(var_name))
                .cloned()
                .unwrap_or_else(|| caps[0].to_string())
        }).to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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
        let result = parser.extract_connection(block, &HashMap::new(), &HashMap::new()).unwrap();
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
        let result = parser.extract_connection(block, &HashMap::new(), &HashMap::new()).unwrap();
        assert_eq!(result, "postgres://user:pass@localhost:5432/db");
    }

    #[test]
    fn test_extract_connection_with_vars() {
        let mut env_vars = HashMap::new();
        env_vars.insert("db_host".to_string(), "localhost".to_string());
        env_vars.insert("db_port".to_string(), "5432".to_string());
        let parser = Parser::new(env_vars);
        let block = "# @connection postgres://user:pass@{{db_host}}:{{db_port}}/mydb\nSELECT 1";
        let result = parser.extract_connection(block, &HashMap::new(), &HashMap::new()).unwrap();
        assert_eq!(result, "postgres://user:pass@localhost:5432/mydb");
    }

    #[test]
    fn test_parse_variable_line_equals() {
        let parser = Parser::new(HashMap::new());
        let result = parser.parse_variable_line("@host = https://example.com");
        assert_eq!(result, Some(("host".to_string(), "https://example.com".to_string())));
    }

    #[test]
    fn test_parse_variable_line_space() {
        let parser = Parser::new(HashMap::new());
        let result = parser.parse_variable_line("@host https://example.com");
        assert_eq!(result, Some(("host".to_string(), "https://example.com".to_string())));
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
        assert_eq!(vars.get("host"), Some(&"https://api.example.com".to_string()));
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
        assert_eq!(vars.get("host"), Some(&"https://api.example.com".to_string()));
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
        let request = parser.parse_block(block, Protocol::Http, &HashMap::new()).unwrap();
        assert!(request.body.contains("GET /users/123"));
        assert!(request.body.contains("Authorization: Bearer secret"));
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
        assert!(request.body.contains("http://request.com:8080/30"));
    }
}
