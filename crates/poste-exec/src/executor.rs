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
        // Handle unresolved {{variable references}} that may contain spaces
        // (e.g. {{Request Name.response.body.field}} with spaces in the request name).
        let request_line = lines[0].trim();
        let space_pos = request_line.find(char::is_whitespace)
            .ok_or_else(|| anyhow::anyhow!("Invalid HTTP request line: {}", request_line))?;

        let method = request_line[..space_pos].to_uppercase();
        let url = request_line[space_pos..].trim_start().to_string();

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

        // Parse the command from body: concatenate all non-empty, non-comment lines
        let cmd_lines: Vec<&str> = request
            .body
            .lines()
            .map(|l| l.trim())
            .filter(|l| !l.is_empty() && !l.starts_with('#') && !l.starts_with("--") && !l.starts_with('>'))
            .collect();

        if cmd_lines.is_empty() {
            anyhow::bail!("Empty Redis command");
        }

        let cmd_line = cmd_lines.join(" ");
        let tokens = parse_shell_args(&cmd_line)?;
        if tokens.is_empty() {
            anyhow::bail!("Empty Redis command");
        }

        let cmd_name = tokens[0].to_uppercase();
        let args: Vec<&str> = tokens[1..].iter().map(|s| s.as_str()).collect();

        let mut cmd = redis::cmd(&cmd_name);
        for arg in &args {
            cmd.arg(*arg);
        }

        let result: redis::Value = cmd.query_async(&mut con).await?;
        
        // Convert to structured JSON for Lua-side rendering
        let structured = redis_value_to_json(&result, &cmd_name);
        let body = serde_json::to_string(&structured)?;

        let type_name = structured.get("type").and_then(|v| v.as_str()).unwrap_or("unknown");
        
        let status_text = match &result {
            redis::Value::Okay => "OK".to_string(),
            redis::Value::Nil => "(nil)".to_string(),
            redis::Value::Int(n) => format!("{}", n),
            redis::Value::Array(a) => format!("{} elements", a.len()),
            _ => type_name.to_string(),
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

/// Convert Redis Value to structured JSON for Lua-side rendering.
/// Uses command inference and heuristics to detect semantic types.
fn redis_value_to_json(val: &redis::Value, cmd_name: &str) -> serde_json::Value {
    use serde_json::{json, Value};

    match val {
        redis::Value::Nil => json!({
            "type": "nil",
            "value": null
        }),
        redis::Value::Int(n) => json!({
            "type": "integer",
            "value": n
        }),
        redis::Value::Okay => json!({
            "type": "string",
            "value": "OK"
        }),
        redis::Value::SimpleString(s) => json!({
            "type": "string",
            "value": s
        }),
        redis::Value::BulkString(b) => {
            match std::str::from_utf8(b) {
                Ok(s) => {
                    // Heuristic: try JSON parse
                    if let Ok(parsed) = serde_json::from_str::<Value>(s) {
                        json!({
                            "type": "string",
                            "value": s,
                            "parsed": parsed
                        })
                    } else {
                        json!({
                            "type": "string",
                            "value": s
                        })
                    }
                }
                Err(_) => json!({
                    "type": "binary",
                    "bytes": b.len()
                }),
            }
        }
        redis::Value::Array(arr) => {
            if arr.is_empty() {
                return json!({
                    "type": "list",
                    "value": []
                });
            }

            // Command inference
            let inferred_type = match cmd_name.to_uppercase().as_str() {
                "HGETALL" | "HSCAN" => "hash",
                "LRANGE" | "LINDEX" | "LPOP" | "RPOP" => "list",
                "SMEMBERS" | "SINTER" | "SUNION" | "SDIFF" | "SRANDMEMBER" => "set",
                "ZRANGE" | "ZRANGEBYSCORE" | "ZRANGEBYLEX" | "ZPOPMIN" | "ZPOPMAX" => "zset",
                "XRANGE" | "XREVRANGE" | "XREAD" | "XREADGROUP" => "stream",
                _ => {
                    // Heuristic: check if array looks like key-value pairs (even length, alternating types)
                    if arr.len() % 2 == 0 && arr.len() > 0 {
                        let all_strings = arr.iter().all(|v| matches!(v, redis::Value::BulkString(_) | redis::Value::SimpleString(_)));
                        if all_strings {
                            "hash"
                        } else {
                            "list"
                        }
                    } else {
                        "list"
                    }
                }
            };

            match inferred_type {
                "hash" => {
                    // Convert to object
                    let mut map = serde_json::Map::new();
                    for chunk in arr.chunks(2) {
                        if chunk.len() == 2 {
                            let key = match &chunk[0] {
                                redis::Value::BulkString(b) => String::from_utf8_lossy(b).to_string(),
                                redis::Value::SimpleString(s) => s.clone(),
                                _ => continue,
                            };
                            let val = redis_value_to_json(&chunk[1], "");
                            map.insert(key, val["value"].clone());
                        }
                    }
                    json!({
                        "type": "hash",
                        "value": Value::Object(map)
                    })
                }
                "zset" => {
                    // Convert to array of {score, member}
                    let mut items = Vec::new();
                    for chunk in arr.chunks(2) {
                        if chunk.len() == 2 {
                            let member = match &chunk[0] {
                                redis::Value::BulkString(b) => String::from_utf8_lossy(b).to_string(),
                                redis::Value::SimpleString(s) => s.clone(),
                                _ => continue,
                            };
                            let score = match &chunk[1] {
                                redis::Value::BulkString(b) => {
                                    String::from_utf8_lossy(b).parse::<f64>().unwrap_or(0.0)
                                }
                                redis::Value::Int(n) => *n as f64,
                                _ => 0.0,
                            };
                            items.push(json!({
                                "member": member,
                                "score": score
                            }));
                        }
                    }
                    json!({
                        "type": "zset",
                        "value": items
                    })
                }
                _ => {
                    // list or set
                    let items: Vec<Value> = arr.iter()
                        .map(|v| redis_value_to_json(v, "")["value"].clone())
                        .collect();
                    json!({
                        "type": inferred_type,
                        "value": items
                    })
                }
            }
        }
        redis::Value::Map(m) => {
            // Redis 7+ native map type
            let mut map = serde_json::Map::new();
            for (k, v) in m {
                let key = match k {
                    redis::Value::BulkString(b) => String::from_utf8_lossy(b).to_string(),
                    redis::Value::SimpleString(s) => s.clone(),
                    _ => continue,
                };
                let val = redis_value_to_json(v, "");
                map.insert(key, val["value"].clone());
            }
            json!({
                "type": "hash",
                "value": Value::Object(map)
            })
        }
        _ => json!({
            "type": "unknown",
            "value": format!("{:?}", val)
        }),
    }
}

/// Parse shell-style arguments, handling quotes
fn parse_shell_args(input: &str) -> Result<Vec<String>> {
    let mut args = Vec::new();
    let mut current = String::new();
    let mut in_quotes = false;
    let mut quote_char = ' ';
    let mut chars = input.chars().peekable();

    while let Some(c) = chars.next() {
        match c {
            '"' | '\'' if !in_quotes => {
                in_quotes = true;
                quote_char = c;
            }
            c if c == quote_char && in_quotes => {
                in_quotes = false;
            }
            '`' if !in_quotes => {
                // Skip backticks - they're markdown formatting, not part of the command
                continue;
            }
            ' ' | '\t' if !in_quotes => {
                if !current.is_empty() {
                    args.push(current.clone());
                    current.clear();
                }
            }
            _ => {
                current.push(c);
            }
        }
    }

    if in_quotes {
        anyhow::bail!("Unclosed quote in command: {}", input);
    }

    if !current.is_empty() {
        args.push(current);
    }

    Ok(args)
}
