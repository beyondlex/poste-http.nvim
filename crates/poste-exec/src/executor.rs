use poste_core::{Protocol, Request};
use crate::response::Response;
use crate::cookie_jar::CookieJar;
use anyhow::Result;
use std::collections::HashMap;
use std::time::Instant;

pub struct Executor;

impl Executor {
    pub async fn execute(request: &Request, cookie_jar: Option<&CookieJar>) -> Result<Response> {
        let start = Instant::now();
        let mut response = match request.protocol {
            Protocol::Http => Self::execute_http(request, cookie_jar).await,
            Protocol::Redis => Self::execute_redis(request).await,
            Protocol::Mysql => Self::execute_mysql(request).await,
            Protocol::Postgres => Self::execute_postgres(request).await,
            Protocol::Mongodb => Self::execute_mongodb(request).await,
            Protocol::Amqp => Self::execute_amqp(request).await,
        }?;
        response.latency_ms = start.elapsed().as_millis() as u64;
        Ok(response)
    }

    /// Execute HTTP request via curl subprocess.
    ///
    /// Using curl gives us verbose trace output (TLS, DNS, proxy, HTTP/2) for free,
    /// identical to what kulala.nvim shows in its Verbose tab.
    async fn execute_http(request: &Request, cookie_jar: Option<&CookieJar>) -> Result<Response> {
        // Parse the HTTP request from the body
        let lines: Vec<&str> = request.body.lines().collect();
        if lines.is_empty() {
            anyhow::bail!("Empty HTTP request");
        }

        // First line: METHOD URL
        let request_line = lines[0].trim();
        let parts: Vec<&str> = request_line.split_whitespace().collect();
        if parts.len() < 2 {
            anyhow::bail!("Invalid HTTP request line: {}", request_line);
        }

        let method = parts[0].to_uppercase();
        let url = parts[1].to_string();

        // Parse request headers and find body separator
        let mut req_headers = Vec::new();
        let mut body_start = None;

        for (i, line) in lines.iter().enumerate().skip(1) {
            if line.trim().is_empty() {
                body_start = Some(i + 1);
                break;
            }
            if let Some((key, value)) = line.split_once(':') {
                req_headers.push((key.trim().to_string(), value.trim().to_string()));
            }
        }

        // Extract request body
        let req_body = body_start
            .map(|s| lines[s..].join("\n"))
            .unwrap_or_default();

        // Create temp file for response headers (curl -D)
        let headers_file = tempfile::NamedTempFile::new()?;
        let headers_path = headers_file.path().to_path_buf();

        // Build curl command
        let mut args = vec![
            "-s".to_string(),   // silent (no progress bar)
            "-S".to_string(),   // show errors even when silent
            "-v".to_string(),   // verbose trace to stderr
            "-L".to_string(),   // follow redirects
            "-X".to_string(), method.clone(),
            "-D".to_string(), headers_path.to_string_lossy().to_string(),
            "-A".to_string(), "poste/0.1.0".to_string(),
        ];

        // Request headers
        for (key, value) in &req_headers {
            args.push("-H".to_string());
            args.push(format!("{}: {}", key, value));
        }

        // Request body
        // Use --data-binary to preserve binary data and newlines (important for multipart/form-data)
        if !req_body.trim().is_empty() {
            args.push("--data-binary".to_string());
            args.push(req_body.clone());
        }

        // Cookie jar: curl manages cookies natively
        if let Some(ref jar) = cookie_jar {
            let path = jar.path().to_string_lossy().to_string();
            args.push("-b".to_string());  // read cookies
            args.push(path.clone());
            args.push("-c".to_string());  // write cookies
            args.push(path);
        }

        args.push(url.clone());

        // Execute curl
        let output = tokio::process::Command::new("curl")
            .args(&args)
            .output()
            .await
            .map_err(|e| anyhow::anyhow!("Failed to execute curl: {}. Is curl installed?", e))?;

        // Read response headers from temp file
        let headers_content = std::fs::read_to_string(&headers_path).unwrap_or_default();

        // Parse response
        let response = parse_curl_response(&headers_content, &output.stdout, &url)?;

        // Read cookies from jar after curl has written them
        let cookies = cookie_jar.as_ref()
            .map(|j| j.read_all())
            .unwrap_or_default();

        // Build metadata
        let mut metadata = HashMap::new();
        metadata.insert("method".to_string(), method);
        metadata.insert(
            "request_headers".to_string(),
            req_headers
                .iter()
                .map(|(k, v)| format!("{}: {}", k, v))
                .collect::<Vec<_>>()
                .join("\n"),
        );
        if !req_body.trim().is_empty() {
            metadata.insert("request_body".to_string(), req_body);
        }
        metadata.insert(
            "timestamp".to_string(),
            chrono::Local::now().format("%b %d %H:%M:%S").to_string(),
        );
        metadata.insert(
            "verbose".to_string(),
            String::from_utf8_lossy(&output.stderr).to_string(),
        );
        metadata.insert(
            "exit_code".to_string(),
            output.status.code().unwrap_or(-1).to_string(),
        );

        Ok(Response {
            protocol: "http".to_string(),
            status: response.status,
            status_text: response.status_text,
            latency_ms: 0, // filled by execute()
            url,
            content_type: response.content_type,
            headers: response.headers,
            body: response.body,
            cookies,
            metadata,
        })
    }

    async fn execute_redis(request: &Request) -> Result<Response> {
        let connection = if request.connection.is_empty() {
            anyhow::bail!("Redis request missing @connection directive");
        } else {
            &request.connection
        };

        let client = redis::Client::open(connection.as_str())?;
        let mut con = client.get_multiplexed_async_connection().await?;

        // Parse the command from body: first non-empty, non-comment line
        let cmd_line = request
            .body
            .lines()
            .map(|l| l.trim())
            .find(|l| !l.is_empty() && !l.starts_with('#') && !l.starts_with("--"))
            .ok_or_else(|| anyhow::anyhow!("Empty Redis command"))?;

        let tokens: Vec<&str> = cmd_line.split_whitespace().collect();
        if tokens.is_empty() {
            anyhow::bail!("Empty Redis command");
        }

        let cmd_name = tokens[0].to_uppercase();
        let args: Vec<&str> = tokens[1..].to_vec();

        let mut cmd = redis::cmd(&cmd_name);
        for arg in &args {
            cmd.arg(*arg);
        }

        let result: redis::Value = cmd.query_async(&mut con).await?;
        let body = format_redis_value(&result);

        let type_name = match &result {
            redis::Value::Nil => "nil",
            redis::Value::Int(_) => "integer",
            redis::Value::BulkString(_) => "string",
            redis::Value::Array(_) => "array",
            redis::Value::Okay => "ok",
            redis::Value::SimpleString(_) => "string",
            redis::Value::Map(_) => "map",
            _ => "unknown",
        };

        let status_text = match &result {
            redis::Value::Okay => "OK".to_string(),
            redis::Value::Nil => "(nil)".to_string(),
            redis::Value::Int(n) => format!("{}", n),
            redis::Value::Array(a) => format!("{} elements", a.len()),
            _ => body.chars().take(40).collect::<String>(),
        };

        let mut metadata = HashMap::new();
        metadata.insert("command".to_string(), cmd_line.to_string());
        metadata.insert("type".to_string(), type_name.to_string());

        Ok(Response {
            protocol: "redis".to_string(),
            status: 0,
            status_text,
            latency_ms: 0,
            url: connection.clone(),
            content_type: "text/plain".to_string(),
            headers: Vec::new(),
            body,
            cookies: Vec::new(),
            metadata,
        })
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

/// Parsed response from curl output.
struct CurlResponse {
    status: u16,
    status_text: String,
    content_type: String,
    headers: Vec<(String, String)>,
    body: String,
}

/// Parse response headers from curl's -D file and body from stdout.
///
/// The headers file may contain multiple header blocks (one per redirect hop).
/// We parse the last block, which is the final response.
fn parse_curl_response(
    headers_content: &str,
    body_bytes: &[u8],
    request_url: &str,
) -> Result<CurlResponse> {
    // Split into header blocks separated by blank lines.
    // Take the last non-empty block (final response after redirects).
    let blocks: Vec<&str> = headers_content
        .split("\r\n\r\n")
        .filter(|b| !b.trim().is_empty())
        .collect();

    let last_block = blocks.last().copied().unwrap_or("");

    let mut status: u16 = 0;
    let mut status_text = String::new();
    let mut headers: Vec<(String, String)> = Vec::new();
    let mut content_type = "text/plain".to_string();

    for line in last_block.lines() {
        let line = line.trim();
        if line.starts_with("HTTP/") {
            // Status line: "HTTP/2 200" or "HTTP/1.1 200 OK"
            let parts: Vec<&str> = line.splitn(3, ' ').collect();
            if parts.len() >= 2 {
                status = parts[1].parse().unwrap_or(0);
                status_text = if parts.len() >= 3 && !parts[2].is_empty() {
                    format!("{} {}", status, parts[2])
                } else {
                    // HTTP/2 has no reason phrase; look up common codes
                    format!("{} {}", status, http_reason(status))
                };
            }
        } else if let Some((key, value)) = line.split_once(':') {
            let key = key.trim().to_string();
            let value = value.trim().to_string();
            if key.to_lowercase() == "content-type" {
                content_type = value.clone();
            }
            headers.push((key, value));
        }
    }

    // If no status line found (e.g., empty headers), infer from body presence
    if status == 0 && !body_bytes.is_empty() {
        status = 200;
        status_text = "200 OK".to_string();
    }

    let body = String::from_utf8_lossy(body_bytes).to_string();

    // If request_url was empty, try to extract Host header for display
    let _ = request_url; // may use later for URL enrichment

    Ok(CurlResponse {
        status,
        status_text,
        content_type,
        headers,
        body,
    })
}

/// HTTP reason phrases for common status codes (HTTP/2 doesn't include them).
fn http_reason(code: u16) -> &'static str {
    match code {
        100 => "Continue",
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        301 => "Moved Permanently",
        302 => "Found",
        304 => "Not Modified",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        409 => "Conflict",
        413 => "Payload Too Large",
        422 => "Unprocessable Entity",
        429 => "Too Many Requests",
        500 => "Internal Server Error",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        504 => "Gateway Timeout",
        _ => "",
    }
}

/// Format a Redis Value for display.
fn format_redis_value(val: &redis::Value) -> String {
    match val {
        redis::Value::Nil => "(nil)".to_string(),
        redis::Value::Int(n) => format!("(integer) {}", n),
        redis::Value::BulkString(b) => {
            match std::str::from_utf8(b) {
                Ok(s) => format!("\"{}\"", s),
                Err(_) => format!("(binary, {} bytes)", b.len()),
            }
        }
        redis::Value::Array(arr) => {
            if arr.is_empty() {
                "(empty array)".to_string()
            } else {
                arr.iter()
                    .enumerate()
                    .map(|(i, v)| format!("{}) {}", i + 1, format_redis_value(v)))
                    .collect::<Vec<_>>()
                    .join("\n")
            }
        }
        redis::Value::Okay => "OK".to_string(),
        redis::Value::SimpleString(s) => s.clone(),
        redis::Value::Map(m) => {
            m.iter()
                .map(|(k, v)| format!("{}: {}", format_redis_value(k), format_redis_value(v)))
                .collect::<Vec<_>>()
                .join("\n")
        }
        _ => format!("{:?}", val),
    }
}
