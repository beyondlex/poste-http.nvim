use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub enum Protocol {
    Http,
    Redis,
    Mysql,
    Postgres,
    Sqlite,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Request {
    pub name: Option<String>,
    pub protocol: Protocol,
    pub connection: String,
    /// Resolved body after file includes (`< filename`) and magic vars are expanded.
    /// This is what gets sent as the HTTP request body (via curl --data-binary).
    pub body: String,
    /// Original body before file include resolution, for display in the request
    /// preview / Verbose tab.  If empty, falls back to `body`.
    pub raw_body: String,
}

/// Replace the database name in a connection URL.
/// "postgres://user:pass@host:5432/olddb" → "postgres://user:pass@host:5432/newdb"
/// Handles URLs with or without auth, port, and existing database.
pub fn replace_database_in_url(url: &str, new_db: &str) -> String {
    if let Some(scheme_end) = url.find("://") {
        let after_scheme = &url[scheme_end + 3..];
        if let Some(last_slash) = after_scheme.rfind('/') {
            let base = &url[..scheme_end + 3 + last_slash + 1];
            return format!("{}{}", base, new_db);
        }
        return format!("{}/{}", url, new_db);
    }
    url.to_string()
}
