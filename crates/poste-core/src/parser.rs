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
            if current_line + block_lines > line_num {
                return self.parse_block(block, protocol);
            }
            current_line += block_lines;
        }
        
        anyhow::bail!("No request found at line {}", line_num);
    }

    fn parse_block(&self, block: &str, protocol: Protocol) -> Result<Request> {
        let lines = block.lines();
        
        // First line should be ### Request Name
        let mut name = None;
        let mut request_lines = Vec::new();
        
        for line in lines {
            if line.trim().starts_with("###") {
                // Extract name after ###
                name = Some(line.trim().trim_start_matches("###").trim().to_string());
            } else {
                request_lines.push(line);
            }
        }
        
        // For HTTP, connection is embedded in the request line (URL)
        // For other protocols, we need @connection directive
        let connection = match protocol {
            Protocol::Http => String::new(), // Will be extracted from request line
            _ => self.extract_connection(block)?,
        };
        
        // Reconstruct body without the ### line
        let body = self.substitute_vars(&request_lines.join("\n"));
        
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
