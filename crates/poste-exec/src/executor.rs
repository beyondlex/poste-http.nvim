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
            Protocol::Mysql | Protocol::Postgres | Protocol::Sqlite => {
                crate::sql_executor::execute_sql(request).await
            }
        }?;
        response.latency_ms = start.elapsed().as_millis() as u64;
        Ok(response)
    }

    /// Execute HTTP request via curl subprocess.
    ///
    /// Using curl gives us verbose trace output (TLS, DNS, proxy, HTTP/2) for free,
    /// identical to what kulala.nvim shows in its Verbose tab.
    async fn execute_http(request: &Request, cookie_jar: Option<&CookieJar>) -> Result<Response> {
        let lines: Vec<&str> = request.body.lines().collect();
        if lines.is_empty() {
            anyhow::bail!("Empty HTTP request");
        }

        let request_line = lines[0].trim();
        let space_pos = request_line.find(char::is_whitespace)
            .ok_or_else(|| anyhow::anyhow!("Invalid HTTP request line: {}", request_line))?;

        let method = request_line[..space_pos].to_uppercase();
        let url = request_line[space_pos..].trim_start().to_string();
        // Strip HTTP version suffix (e.g. " HTTP/1.1") from the URL
        let url = url.split_whitespace().next().unwrap_or(&url).to_string();

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

        let req_body = body_start
            .map(|s| lines[s..].join("\n"))
            .unwrap_or_default()
            .trim_end()
            .to_string();

        // For application/x-www-form-urlencoded, strip newlines entirely.
        // Newlines are not valid in this format and often appear due to
        // multi-line formatting in the .http file (e.g. each key-value pair
        // on its own line).  Raw newlines would be appended to the preceding
        // value, which is almost certainly unintended.
        let is_form_urlencoded = req_headers.iter().any(|(k, v)|
            k.to_lowercase() == "content-type" && v.contains("x-www-form-urlencoded")
        );
        let req_body = if is_form_urlencoded {
            req_body.replace('\n', "")
        } else {
            req_body
        };

        let headers_file = tempfile::NamedTempFile::new()?;
        let headers_path = headers_file.path().to_path_buf();

        let args = Self::build_curl_args(&method, &url, &req_headers, &req_body, cookie_jar, &headers_path);
        let (stdout, stderr, status) = Self::execute_curl(&args).await?;
        let headers_content = std::fs::read_to_string(&headers_path).unwrap_or_default();

        let mut response = parse_curl_response(&headers_content, &stdout, &url)?;

        let cookies = cookie_jar.as_ref()
            .map(|j| j.read_all())
            .unwrap_or_default();

        let mut metadata = HashMap::new();

        // If the response is binary content (image, PDF, zip, etc.), save it to
        // /tmp/ and store the file path in metadata instead of mangled UTF-8 text.
        if is_binary_content_type(&response.content_type) && !stdout.is_empty() {
            // Try to extract filename from Content-Disposition header (e.g.,
            // `attachment; filename="考勤统计.xls"`), falling back to a
            // timestamp-based name.
            let disp_header = response.headers.iter()
                .find(|(k, _)| k.to_lowercase() == "content-disposition")
                .map(|(_, v)| v.as_str());
            let file_name = disp_header
                .and_then(parse_filename_from_disposition)
                .filter(|n: &String| !n.is_empty())
                .unwrap_or_else(|| {
                    format!("poste_{}_{}", chrono::Local::now().format("%Y%m%d_%H%M%S"), response.status)
                });
            let tmp_path = resolve_path_with_conflict("/tmp", &file_name);
            match std::fs::write(&tmp_path, &stdout) {
                Err(e) => {
                    metadata.insert("file_save_error".to_string(), format!("failed to write to {}: {}", tmp_path.display(), e));
                }
                Ok(()) => {
                    let file_size = stdout.len();
                    metadata.insert("file_path".to_string(), tmp_path.to_string_lossy().to_string());
                    metadata.insert("file_size".to_string(), file_size.to_string());
                    metadata.insert("file_content_type".to_string(), response.content_type.clone());
                    // Replace mangled body with a summary
                    response.body = format!("[Binary file saved to: {}]\n[Size: {} bytes]\n[Content-Type: {}]",
                        tmp_path.display(), file_size, response.content_type);
                }
            }
        }

        metadata.insert("method".to_string(), method.clone());
        metadata.insert("request_headers".to_string(),
            req_headers.iter()
                .map(|(k, v)| format!("{}: {}", k, v))
                .collect::<Vec<_>>()
                .join("\n"));
        if !req_body.trim().is_empty() {
            metadata.insert("request_body".to_string(), req_body);
        }
        metadata.insert("timestamp".to_string(),
            chrono::Local::now().format("%Y-%m-%d %H:%M:%S").to_string());
        metadata.insert("verbose".to_string(),
            String::from_utf8_lossy(&stderr).to_string());
        metadata.insert("exit_code".to_string(),
            status.code().unwrap_or(-1).to_string());

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

    /// Build curl argument list from parsed request components.
    fn build_curl_args(
        method: &str,
        url: &str,
        req_headers: &[(String, String)],
        req_body: &str,
        cookie_jar: Option<&CookieJar>,
        headers_path: &std::path::Path,
    ) -> Vec<String> {
        let mut args = vec![
            "-s".to_string(),
            "-S".to_string(),
            "-v".to_string(),
            "-L".to_string(),
            "-X".to_string(), method.to_string(),
            "-D".to_string(), headers_path.to_string_lossy().to_string(),
            "-A".to_string(), "poste/0.1.0".to_string(),
        ];

        for (key, value) in req_headers {
            args.push("-H".to_string());
            args.push(format!("{}: {}", key, value));
        }

        if !req_body.trim().is_empty() {
            args.push("--data-binary".to_string());
            args.push(req_body.to_string());
        }

        if let Some(jar) = &cookie_jar {
            let path = jar.path().to_string_lossy().to_string();
            args.push("-b".to_string());
            args.push(path.clone());
            args.push("-c".to_string());
            args.push(path);
        }

        args.push(url.to_string());
        args
    }

    /// Execute curl subprocess and return (stdout, stderr, exit_status).
    async fn execute_curl(args: &[String]) -> Result<(Vec<u8>, Vec<u8>, std::process::ExitStatus)> {
        let output = tokio::process::Command::new("curl")
            .args(args)
            .output()
            .await
            .map_err(|e| anyhow::anyhow!("Failed to execute curl: {}. Is curl installed?", e))?;
        Ok((output.stdout, output.stderr, output.status))
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

/// Detect whether a Content-Type indicates binary data that should not be
/// rendered as text in the response body/verbose tabs.
///
/// Matches common binary MIME types: images, audio, video, archives,
/// office documents, protobuf, etc.
fn is_binary_content_type(content_type: &str) -> bool {
    let ct = content_type.to_lowercase();
    // Strip parameters (charset, boundary, etc.)
    let mime = ct.split(';').next().unwrap_or(&ct).trim().to_string();

    // Image, audio, video
    if mime.starts_with("image/")
        || mime.starts_with("audio/")
        || mime.starts_with("video/")
    {
        return true;
    }

    // Known binary application types
    matches!(
        mime.as_str(),
        "application/octet-stream"
            | "application/pdf"
            | "application/zip"
            | "application/gzip"
            | "application/x-tar"
            | "application/x-bzip2"
            | "application/x-7z-compressed"
            | "application/x-rar-compressed"
            | "application/java-archive"
            | "application/vnd.ms-excel"
            | "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
            | "application/vnd.ms-powerpoint"
            | "application/vnd.openxmlformats-officedocument.presentationml.presentation"
            | "application/msword"
            | "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
            | "application/x-protobuf"
            | "application/msgpack"
            | "application/cbor"
            | "application/wasm"
    )
}

/// Extract the filename from a Content-Disposition header value.
///
/// Supports formats:
///   `attachment; filename="考勤统计.xls"`
///   `attachment; filename=report.pdf`
///   `inline; filename*=UTF-8''encoded%20name.pdf` (RFC 5987 — returns the
///     percent-encoded string as-is; callers may want to decode it further)
///
/// Returns `None` if no filename parameter is present.
fn parse_filename_from_disposition(header_value: &str) -> Option<String> {
    // Look for `filename*=charset'lang'value` (RFC 5987) first — it takes
    // precedence.  We return the raw percent-encoded value so that callers
    // get a valid filename (percent-encoded bytes are safe on disk).
    if let Some(start) = header_value.find("filename*=") {
        let rest = &header_value[start + 10..];
        // After `filename*=`, skip charset'lang' → find the third '.
        let mut quote_count = 0;
        let mut value_start = 0;
        for (i, ch) in rest.char_indices() {
            if ch == '\'' {
                quote_count += 1;
                if quote_count == 3 {
                    value_start = i + 1;
                    break;
                }
            }
        }
        if quote_count == 3 {
            let raw: String = rest[value_start..]
                .trim()
                .trim_matches('"')
                .chars()
                .take_while(|&c| c != ';' && c != ' ')
                .collect();
            if !raw.is_empty() {
                return Some(sanitize_filename(&raw));
            }
        }
    }

    // Look for `filename="value"` or `filename=value`
    if let Some(start) = header_value.find("filename=") {
        let rest = &header_value[start + 9..];
        if rest.starts_with('"') {
            // Quoted: filename="value"
            let end = rest[1..].find('"').map(|i| i + 1).unwrap_or(rest.len());
            let name = &rest[1..end];
            if !name.is_empty() {
                return Some(sanitize_filename(name));
            }
        } else if rest.starts_with('\'') {
            // Single-quoted: filename='value'
            let end = rest[1..].find('\'').map(|i| i + 1).unwrap_or(rest.len());
            let name = &rest[1..end];
            if !name.is_empty() {
                return Some(sanitize_filename(name));
            }
        } else {
            // Unquoted: filename=value  (value ends at ; or whitespace or end)
            let name: String = rest
                .trim()
                .chars()
                .take_while(|&c| c != ';' && c != ' ')
                .collect();
            if !name.is_empty() {
                return Some(sanitize_filename(&name));
            }
        }
    }

    None
}

/// Sanitize a filename for safe use on disk: strip directory separators,
/// null bytes, colons (Windows), and ".." path traversal sequences.
///
/// After sanitization the result is a flat filename with no path components,
/// safe to join with any directory.
fn sanitize_filename(name: &str) -> String {
    // First pass: strip dangerous characters
    let sanitized: String = name
        .chars()
        .filter(|&c| c != '/' && c != '\\' && c != '\0' && c != ':')
        .collect();
    // Second pass: remove ".." sequences to prevent path traversal
    let without_dots = sanitized.replace("..", "");
    let trimmed = without_dots.trim().to_string();
    // Avoid empty or dot-only names after sanitization
    if trimmed.is_empty() || trimmed == "." || trimmed == ".." {
        "downloaded_file".to_string()
    } else {
        trimmed
    }
}

/// Given a directory and filename, return a path that does not conflict with
/// any existing file.  If the base path already exists, append `(1)`, `(2)`,
/// etc. before the extension (e.g. `report(1).xls`, `report(2).xls`).
///
/// Falls back to the base path if it does not exist, or if we exhaust the
/// range 1..1000 (unlikely, but safe).
fn resolve_path_with_conflict(dir: &str, filename: &str) -> std::path::PathBuf {
    let base = std::path::Path::new(dir).join(filename);
    if !base.exists() {
        return base;
    }

    let stem = std::path::Path::new(filename)
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or(filename);
    let ext = std::path::Path::new(filename)
        .extension()
        .and_then(|s| s.to_str())
        .map(|s| format!(".{}", s))
        .unwrap_or_default();

    for i in 1..1000 { // see constants.lua MAX_CONFLICT_SUFFIX
        let candidate = if ext.is_empty() {
            format!("{}({})", stem, i)
        } else {
            format!("{}({}).{}", stem, i, ext.trim_start_matches('.'))
        };
        let path = std::path::Path::new(dir).join(&candidate);
        if !path.exists() {
            return path;
        }
    }

    // Give up and return the original path (will overwrite)
    base
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
                    if arr.len() % 2 == 0 && !arr.is_empty() {
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
    let chars = input.chars().peekable();

    for c in chars {
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

#[cfg(test)]
mod tests {
    use super::*;

    // ---------------------------------------------------------------------------
    // sanitize_filename
    // ---------------------------------------------------------------------------

    #[test]
    fn test_sanitize_filename_normal() {
        assert_eq!(sanitize_filename("report.pdf"), "report.pdf");
    }

    #[test]
    fn test_sanitize_filename_strips_slashes() {
        assert_eq!(sanitize_filename("foo/bar.txt"), "foobar.txt");
    }

    #[test]
    fn test_sanitize_filename_strips_backslashes() {
        assert_eq!(sanitize_filename("foo\\bar.txt"), "foobar.txt");
    }

    #[test]
    fn test_sanitize_filename_prevents_path_traversal() {
        // `..` is removed after `/` and `\` are stripped, so `../../etc/passwd`
        // becomes `etcpasswd` (no more path separators)
        let result = sanitize_filename("../../etc/passwd");
        assert!(!result.contains(".."));
        assert!(!result.contains('/'));

        let result = sanitize_filename("..\\..\\windows\\system32");
        assert!(!result.contains(".."));
        assert!(!result.contains('\\'));
    }

    #[test]
    fn test_sanitize_filename_strips_null_bytes() {
        assert_eq!(sanitize_filename("test\0.txt"), "test.txt");
    }

    #[test]
    fn test_sanitize_filename_strips_colons() {
        assert_eq!(sanitize_filename("file:name.txt"), "filename.txt");
    }

    #[test]
    fn test_sanitize_filename_empty_after_sanitization() {
        assert_eq!(sanitize_filename(".."), "downloaded_file");
        assert_eq!(sanitize_filename("."), "downloaded_file");
        assert_eq!(sanitize_filename(""), "downloaded_file");
    }

    #[test]
    fn test_sanitize_filename_trims_whitespace() {
        assert_eq!(sanitize_filename("  test.txt  "), "test.txt");
    }

    // ---------------------------------------------------------------------------
    // resolve_path_with_conflict
    // ---------------------------------------------------------------------------

    #[test]
    fn test_resolve_path_stays_in_target_dir() {
        let tmp = std::env::temp_dir();
        let path = resolve_path_with_conflict(tmp.to_str().unwrap(), "/etc/passwd");
        assert!(
            path.starts_with(&tmp),
            "path {:?} should start with {:?}",
            path,
            tmp
        );
    }

    #[test]
    fn test_resolve_path_no_conflict() {
        let tmp = std::env::temp_dir();
        let name = format!("poste_test_unique_{}", std::process::id());
        let path = resolve_path_with_conflict(tmp.to_str().unwrap(), &name);
        assert_eq!(path, tmp.join(&name));
        // Cleanup
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn test_resolve_path_with_conflict_appends_suffix() {
        let tmp = std::env::temp_dir();
        let name = format!("poste_test_conflict_{}", std::process::id());
        let path = tmp.join(&name);
        // Create the file so there's a conflict
        let _ = std::fs::write(&path, "existing");
        let resolved = resolve_path_with_conflict(tmp.to_str().unwrap(), &name);
        assert_ne!(resolved, path);
        assert!(resolved.starts_with(&tmp));
        // Cleanup
        let _ = std::fs::remove_file(&path);
        let _ = std::fs::remove_file(&resolved);
    }

    // ---------------------------------------------------------------------------
    // is_binary_content_type
    // ---------------------------------------------------------------------------

    #[test]
    fn test_is_binary_content_type_images() {
        assert!(is_binary_content_type("image/png"));
        assert!(is_binary_content_type("image/jpeg"));
        assert!(is_binary_content_type("image/gif"));
    }

    #[test]
    fn test_is_binary_content_type_audio_video() {
        assert!(is_binary_content_type("audio/mpeg"));
        assert!(is_binary_content_type("video/mp4"));
    }

    #[test]
    fn test_is_binary_content_type_application_types() {
        assert!(is_binary_content_type("application/pdf"));
        assert!(is_binary_content_type("application/zip"));
        assert!(is_binary_content_type("application/octet-stream"));
    }

    #[test]
    fn test_is_binary_content_type_text() {
        assert!(!is_binary_content_type("text/plain"));
        assert!(!is_binary_content_type("text/html"));
        assert!(!is_binary_content_type("application/json"));
    }

    #[test]
    fn test_is_binary_content_type_strips_parameters() {
        assert!(is_binary_content_type("image/png; charset=utf-8"));
    }

    // ---------------------------------------------------------------------------
    // parse_curl_response
    // ---------------------------------------------------------------------------

    #[test]
    fn test_parse_curl_response_simple() {
        let headers = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n";
        let body = b"{\"key\": \"value\"}";
        let response = parse_curl_response(headers, body, "http://example.com").unwrap();
        assert_eq!(response.status, 200);
        assert_eq!(response.status_text, "200 OK");
        assert_eq!(response.content_type, "application/json");
        assert_eq!(response.body, "{\"key\": \"value\"}");
    }

    #[test]
    fn test_parse_curl_response_redirect() {
        let headers = "HTTP/1.1 301 Moved Permanently\r\nLocation: /new\r\n\r\nHTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n";
        let body = b"final response";
        let response = parse_curl_response(headers, body, "http://example.com").unwrap();
        assert_eq!(response.status, 200);
        assert_eq!(response.status_text, "200 OK");
    }

    #[test]
    fn test_parse_curl_response_http2() {
        let headers = "HTTP/2 200\r\ncontent-type: application/json\r\n\r\n";
        let body = b"{}";
        let response = parse_curl_response(headers, body, "http://example.com").unwrap();
        assert_eq!(response.status, 200);
        assert!(response.status_text.contains("OK"));
    }

    #[test]
    fn test_parse_curl_response_empty_headers() {
        let body = b"some content";
        let response = parse_curl_response("", body, "http://example.com").unwrap();
        assert_eq!(response.status, 200);
        assert_eq!(response.status_text, "200 OK");
        assert_eq!(response.body, "some content");
    }

    // ---------------------------------------------------------------------------
    // parse_filename_from_disposition
    // ---------------------------------------------------------------------------

    #[test]
    fn test_parse_filename_from_disposition_quoted() {
        let result = parse_filename_from_disposition(r#"attachment; filename="report.pdf""#);
        assert_eq!(result, Some("report.pdf".to_string()));
    }

    #[test]
    fn test_parse_filename_from_disposition_unquoted() {
        let result = parse_filename_from_disposition("attachment; filename=report.pdf");
        assert_eq!(result, Some("report.pdf".to_string()));
    }

    #[test]
    fn test_parse_filename_from_disposition_no_filename() {
        let result = parse_filename_from_disposition("attachment");
        assert_eq!(result, None);
    }

    #[test]
    fn test_parse_filename_from_disposition_sanitizes() {
        let result = parse_filename_from_disposition(r#"attachment; filename="../../etc/passwd""#);
        let result = result.unwrap();
        assert!(!result.contains(".."));
        assert!(!result.contains('/'));
    }

    // ---------------------------------------------------------------------------
    // http_reason
    // ---------------------------------------------------------------------------

    #[test]
    fn test_http_reason_common_codes() {
        assert_eq!(http_reason(200), "OK");
        assert_eq!(http_reason(404), "Not Found");
        assert_eq!(http_reason(500), "Internal Server Error");
    }

    #[test]
    fn test_http_reason_unknown_code() {
        assert_eq!(http_reason(999), "");
    }
}
