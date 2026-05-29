use crate::request::{Request, Protocol};
use anyhow::Result;
use regex::Regex;

pub struct Parser {
    env: std::collections::HashMap<String, String>,
}

impl Parser {
    pub fn new(env_vars: std::collections::HashMap<String, String>) -> Self {
        Self { env: env_vars }
    }

    /// Parse a request file and extract the request at the given line
    pub fn parse_at_line(&self, content: &str, line_num: usize) -> Result<Request> {
        // Detect protocol from file extension (passed via context)
        // For now, assume .http
        let protocol = Protocol::Http;
        
        // Find the request block containing the cursor
        let requests: Vec<&str> = content.split("\n### ").collect();
        
        let mut current_line = 0;
        for block in requests {
            let block_lines = block.lines().count();
            if current_line + block_lines > line_num {
                return self.parse_block(block, protocol);
            }
            current_line += block_lines + 1; // +1 for the ### separator
        }
        
        anyhow::bail!("No request found at line {}", line_num);
    }

    fn parse_block(&self, block: &str, protocol: Protocol) -> Result<Request> {
        let mut lines = block.lines();
        
        // First line might be the name (after ###)
        let name = lines.next()
            .map(|l| l.trim().to_string())
            .filter(|l| !l.is_empty());
        
        // Extract connection from @connection comment
        let connection = self.extract_connection(block)?;
        
        // Replace {{var}} with env values
        let body = self.substitute_vars(block);
        
        Ok(Request {
            name,
            protocol,
            connection,
            body,
        })
    }

    fn extract_connection(&self, block: &str) -> Result<String> {
        let re = Regex::new(r"(?:--|#)\s*@connection\s+(.+)")?;
        for line in block.lines() {
            if let Some(caps) = re.captures(line) {
                return Ok(self.substitute_vars(caps[1].trim()).to_string());
            }
        }
        anyhow::bail!("No @connection directive found in request block");
    }

    fn substitute_vars(&self, input: &str) -> String {
        let re = Regex::new(r"\{\{(\w+)\}\}").unwrap();
        re.replace_all(input, |caps: &regex::Captures| {
            let var_name = &caps[1];
            self.env.get(var_name).cloned().unwrap_or_else(|| caps[0].to_string())
        }).to_string()
    }
}
