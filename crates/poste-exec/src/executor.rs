use poste_core::{Request, Protocol};
use crate::response::Response;
use anyhow::Result;

pub struct Executor;

impl Executor {
    pub async fn execute(request: &Request) -> Result<Response> {
        match request.protocol {
            Protocol::Http => Self::execute_http(request).await,
            Protocol::Redis => Self::execute_redis(request).await,
            Protocol::Mysql => Self::execute_mysql(request).await,
            Protocol::Postgres => Self::execute_postgres(request).await,
            Protocol::Mongodb => Self::execute_mongodb(request).await,
            Protocol::Amqp => Self::execute_amqp(request).await,
        }
    }

    async fn execute_http(request: &Request) -> Result<Response> {
        let client = reqwest::Client::new();
        
        // Parse the HTTP request from the body
        let lines: Vec<&str> = request.body.lines().collect();
        if lines.is_empty() {
            anyhow::bail!("Empty HTTP request");
        }
        
        // First line is the request line: METHOD URL
        let request_line = lines[0].trim();
        let parts: Vec<&str> = request_line.split_whitespace().collect();
        if parts.len() < 2 {
            anyhow::bail!("Invalid HTTP request line: {}", request_line);
        }
        
        let method = parts[0].to_uppercase();
        let url = parts[1];
        
        // Find headers and body
        let mut headers = std::collections::HashMap::new();
        let mut body_start = None;
        
        for (i, line) in lines.iter().enumerate().skip(1) {
            if line.trim().is_empty() {
                body_start = Some(i + 1);
                break;
            }
            if let Some((key, value)) = line.split_once(':') {
                headers.insert(key.trim().to_string(), value.trim().to_string());
            }
        }
        
        // Build the request
        let mut req = match method.as_str() {
            "GET" => client.get(url),
            "POST" => client.post(url),
            "PUT" => client.put(url),
            "DELETE" => client.delete(url),
            "PATCH" => client.patch(url),
            "HEAD" => client.head(url),
            _ => anyhow::bail!("Unsupported HTTP method: {}", method),
        };
        
        // Add headers
        for (key, value) in &headers {
            req = req.header(key.as_str(), value.as_str());
        }
        
        // Add body if present
        if let Some(start) = body_start {
            let body: String = lines[start..].join("\n");
            if !body.trim().is_empty() {
                req = req.body(body);
            }
        }
        
        // Send the request
        let resp = req.send().await?;
        let status = resp.status().as_u16();
        
        // Collect response headers
        let mut resp_headers = std::collections::HashMap::new();
        for (key, value) in resp.headers() {
            if let Ok(v) = value.to_str() {
                resp_headers.insert(key.to_string(), v.to_string());
            }
        }
        
        // Get response body
        let body = resp.text().await?;
        
        Ok(Response {
            status,
            body,
            headers: resp_headers,
        })
    }

    async fn execute_redis(_request: &Request) -> Result<Response> {
        anyhow::bail!("Redis not implemented yet")
    }

    async fn execute_mysql(_request: &Request) -> Result<Response> {
        anyhow::bail!("MySQL not implemented yet")
    }

    async fn execute_postgres(_request: &Request) -> Result<Response> {
        anyhow::bail!("PostgreSQL not implemented yet")
    }

    async fn execute_mongodb(_request: &Request) -> Result<Response> {
        anyhow::bail!("MongoDB not implemented yet")
    }

    async fn execute_amqp(_request: &Request) -> Result<Response> {
        anyhow::bail!("AMQP not implemented yet")
    }
}
