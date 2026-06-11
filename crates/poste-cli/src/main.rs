use clap::{Parser, Subcommand};
use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::io::{BufRead, BufReader, Read, Write};

#[derive(Parser)]
#[command(name = "poste")]
#[command(about = "Execute requests from files")]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Execute a request at a specific line
    Run {
        /// File path (used for env.json discovery and extension detection;
        /// with --stdin the file does not need to exist on disk)
        file: String,
        /// Line number
        #[arg(short, long)]
        line: usize,
        /// Environment name
        #[arg(short, long, default_value = "dev")]
        env: String,
        /// Output as JSON (for Neovim plugin consumption)
        #[arg(long)]
        json: bool,
        /// Read request content from stdin instead of from the file
        #[arg(long)]
        stdin: bool,
        /// Override database name (for USE statement context from the editor)
        #[arg(long)]
        database: Option<String>,
    },
    /// Manage SQL connections
    Connection {
        #[command(subcommand)]
        action: ConnectionAction,
    },
    /// Introspect database structure (list databases, schemas, tables, columns, indexes)
    Introspect {
        /// Connection name (from connections.json)
        name: String,
        /// Introspection type: databases, schemas, tables, columns, indexes
        #[arg(long)]
        r#type: String,
        /// Schema name (for PG tables/columns/indexes)
        #[arg(long)]
        schema: Option<String>,
        /// Table name (for columns/indexes)
        #[arg(long)]
        table: Option<String>,
        /// Database name (overrides connection's default database)
        #[arg(long)]
        database: Option<String>,
        /// Directory to search for connections.json
        #[arg(long)]
        path: Option<String>,
        /// Environment name (for variable substitution)
        #[arg(short, long, default_value = "dev")]
        env: String,
    },
    /// SQL context detection (for completion/indicator placement)
    Context {
        #[command(subcommand)]
        action: ContextAction,
    },
}

#[derive(Subcommand)]
enum ContextAction {
    /// Detect SQL completion context at cursor position
    Detect {
        /// Byte offset of cursor within SQL text (0-based)
        offset: usize,
        /// Optional dialect for function filtering (generic, postgres, mysql, sqlite)
        #[arg(long, default_value = "generic")]
        dialect: String,
    },
    /// Find statement boundaries containing a cursor line
    Stmt {
        /// Cursor line number (0-based)
        cursor_line: usize,
    },
    /// Persistent server mode: read line-delimited JSON requests from stdin
    Serve,
}

#[derive(Subcommand)]
enum ConnectionAction {
    /// List all connections from connections.json
    List {
        /// Directory to search for connections.json
        #[arg(long)]
        path: Option<String>,
        /// Environment name (for variable substitution)
        #[arg(short, long, default_value = "dev")]
        env: String,
        /// Output as JSON
        #[arg(long)]
        json: bool,
    },
    /// Test a connection by name
    Test {
        /// Connection name
        name: String,
        /// Directory to search for connections.json
        #[arg(long)]
        path: Option<String>,
        /// Environment name (for variable substitution)
        #[arg(short, long, default_value = "dev")]
        env: String,
    },
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();

    match cli.command {
        Commands::Connection { action } => {
            handle_connection_command(action).await?;
        }
        Commands::Introspect { name, r#type, schema, table, database, path, env } => {
            handle_introspect_command(name, r#type, schema, table, database, path, env).await?;
        }
        Commands::Context { action } => {
            handle_context_command(action)?;
        }
        Commands::Run { file, line, env, json, stdin, database } => {
            let file_path = std::path::PathBuf::from(&file);

            // Determine the directory to search for env.json, and the file extension.
            // With --stdin the file may not exist on disk, so use its path as-is.
            let (search_dir, file_ext) = if stdin {
                let abs = if file_path.is_absolute() {
                    file_path.clone()
                } else {
                    std::env::current_dir()?.join(&file_path)
                };
                let ext = abs
                    .extension()
                    .and_then(|e| e.to_str())
                    .unwrap_or("http")
                    .to_string();
                let dir = abs.parent()
                    .unwrap_or_else(|| std::path::Path::new("."))
                    .to_path_buf();
                (dir, ext)
            } else {
                // Resolve and canonicalize the file path
                let abs = if file_path.is_absolute() {
                    file_path.clone()
                } else {
                    std::env::current_dir()?.join(&file_path)
                };
                let canonical = std::fs::canonicalize(&abs)
                    .map_err(|e| anyhow::anyhow!("Request file not found: {} ({})", abs.display(), e))?;
                let ext = canonical
                    .extension()
                    .and_then(|e| e.to_str())
                    .unwrap_or("http")
                    .to_string();
                let dir = canonical.parent().context("File path resolves to root")?.to_path_buf();
                (dir, ext)
            };

            // Find env.json: optional (SQL files with direct connection names don't need it)
            let mut dir = search_dir.as_path();
            let env_vars = loop {
                let candidate = dir.join("env.json");
                if candidate.exists() {
                    let env_file = poste_core::Environment::load(candidate.to_str().context("env.json path is not valid UTF-8")?)?;
                    let vars = env_file.envs.get(&env).cloned().unwrap_or_default();
                    break vars;
                }
                match dir.parent() {
                    Some(parent) => dir = parent,
                    None => break std::collections::HashMap::new(),
                }
            };

            // Read request content
            let content = if stdin {
                let mut buf = String::new();
                std::io::stdin().read_to_string(&mut buf)?;
                buf
            } else {
                let canonical = std::fs::canonicalize(&file_path)
                    .unwrap_or(file_path.clone());
                std::fs::read_to_string(&canonical)?
            };

            // Parse the request
            let parser = poste_core::Parser::new(env_vars.clone());
            let mut request = parser.parse_at_line(&content, line, &file_ext)?;

            // Resolve connection name for SQL protocols
            // If the connection value doesn't look like a URL, it's a name to resolve via connections.json.
            // Recognized URL formats:
            //   - Contains "://" (postgres://, mysql://, etc.)
            //   - Starts with "sqlite:" (sqlite:/path, sqlite::memory:)
            //   - Starts with "/" or "./" (bare file paths for SQLite)
            if is_sql_protocol(&request.protocol) && !is_connection_url(&request.connection) && !request.connection.is_empty() {
                let conn_name = request.connection.clone();
                let conn_store = poste_exec::sql_connection::ConnectionStore::load(&search_dir)?;
                request.connection = conn_store.resolve(&conn_name, &env_vars)
                    .map_err(|e| anyhow::anyhow!("Failed to resolve connection '{}': {}", conn_name, e))?;
            }

            // Override database from --database flag (USE statement context from editor)
            if let Some(ref db) = database {
                if is_sql_protocol(&request.protocol) && !request.connection.is_empty() {
                    request.connection = poste_core::replace_database_in_url(&request.connection, db);
                }
            }

            // Auto-detect protocol from connection URL for .sql files (which default to Postgres)
            // If the resolved connection is a SQLite URL, override to Sqlite protocol
            if request.protocol == poste_core::Protocol::Postgres && request.connection.starts_with("sqlite:") {
                request.protocol = poste_core::Protocol::Sqlite;
            }
            if request.protocol == poste_core::Protocol::Postgres && request.connection.starts_with("mysql://") {
                request.protocol = poste_core::Protocol::Mysql;
            }

            // Load cookie jar
            let cookie_jar = poste_exec::CookieJar::load(&env);

            // Execute
            let response = poste_exec::Executor::execute(&request, Some(&cookie_jar)).await?;

            // Save cookies (best effort)
            if let Err(e) = cookie_jar.save() {
                eprintln!("[poste] warning: failed to save cookies: {}", e);
            }

            if json {
                println!("{}", serde_json::to_string(&response)?);
            } else {
                println!("Executing: {:?}", request.name);
                println!("Protocol: {:?}", request.protocol);
                println!("Connection: {}", request.connection);
                println!();

                println!("Status: {}", response.status_text);
                println!("Latency: {}ms", response.latency_ms);
                println!("URL: {}", response.url);
                if !response.cookies.is_empty() {
                    println!("Cookies:");
                    for c in &response.cookies {
                        println!("  {}={} (domain={}, path={})", c.name, c.value, c.domain, c.path);
                    }
                }
                println!("Headers:");
                for (key, value) in &response.headers {
                    println!("  {}: {}", key, value);
                }
                println!();
                println!("Body:");

                if response.content_type.contains("json") {
                    match serde_json::from_str::<serde_json::Value>(&response.body) {
                        Ok(json) => println!("{}", serde_json::to_string_pretty(&json).unwrap()),
                        Err(_) => println!("{}", response.body),
                    }
                } else {
                    println!("{}", response.body);
                }
            }
        }
    }

    Ok(())
}

/// Check if a protocol is SQL-based.
fn is_sql_protocol(protocol: &poste_core::Protocol) -> bool {
    matches!(protocol, poste_core::Protocol::Postgres | poste_core::Protocol::Mysql | poste_core::Protocol::Sqlite)
}

/// Check if a connection string looks like a URL (not a name).
fn is_connection_url(conn: &str) -> bool {
    // Standard URL schemes
    if conn.contains("://") {
        return true;
    }
    // SQLite: sqlite:/path, sqlite::memory:, sqlite:relative
    if conn.starts_with("sqlite:") {
        return true;
    }
    // Bare file paths (for SQLite): /absolute or ./relative
    if conn.starts_with('/') || conn.starts_with("./") {
        return true;
    }
    false
}

// ---------------------------------------------------------------------------
// Context command helpers
// ---------------------------------------------------------------------------

#[derive(Serialize)]
struct ContextDetectResponse {
    version: u32,
    ctx_type: String,
    ctx_data: Option<String>,
    ctx_schema: Option<String>,
    prefix: String,
    tables: Vec<TableRefInfo>,
    functions: Vec<&'static str>,
    in_string: bool,
    in_comment: bool,
}

#[derive(Serialize)]
struct TableRefInfo {
    name: String,
    alias: Option<String>,
    schema: Option<String>,
}

#[derive(Serialize)]
struct ContextStmtResponse {
    start_line: usize,
    end_line: usize,
}

fn make_detect_response(result: &poste_core::sql_context::ContextResult) -> ContextDetectResponse {
    let ctx_type = result.context_type.name().to_string();
    let ctx_data = result.context_type.data();
    let ctx_schema = match &result.context_type {
        poste_core::sql_context::ContextType::DotColumn { schema, .. } => schema.clone(),
        poste_core::sql_context::ContextType::SchemaTable { schema } => Some(schema.clone()),
        _ => None,
    };
    let tables: Vec<TableRefInfo> = result.tables.iter().map(|t| TableRefInfo {
        name: t.name.clone(),
        alias: t.alias.clone(),
        schema: t.schema.clone(),
    }).collect();
    ContextDetectResponse {
        version: 1,
        ctx_type,
        ctx_data,
        ctx_schema,
        prefix: result.prefix.clone(),
        tables,
        functions: result.functions.clone(),
        in_string: result.in_string,
        in_comment: result.in_comment,
    }
}

fn handle_context_command(action: ContextAction) -> Result<()> {
    match action {
        ContextAction::Detect { offset, dialect } => {
            let mut sql = String::new();
            std::io::stdin().read_to_string(&mut sql)?;
            let dialect = match dialect.as_str() {
                "postgres" => poste_core::sql_context::SqlDialect::Postgres,
                "mysql" => poste_core::sql_context::SqlDialect::MySql,
                "sqlite" => poste_core::sql_context::SqlDialect::Sqlite,
                _ => poste_core::sql_context::SqlDialect::Generic,
            };
            let result = poste_core::sql_context::detect_context_with_dialect(&sql, offset, dialect);
            let response = match result {
                Some(ctx) => make_detect_response(&ctx),
                None => ContextDetectResponse {
                    version: 1,
                    ctx_type: "keyword".into(),
                    ctx_data: None,
                    ctx_schema: None,
                    prefix: String::new(),
                    tables: vec![],
                    functions: vec![],
                    in_string: true,
                    in_comment: true,
                },
            };
            println!("{}", serde_json::to_string(&response)?);
        }
        ContextAction::Stmt { cursor_line } => {
            let mut input = String::new();
            std::io::stdin().read_to_string(&mut input)?;
            let lines: Vec<&str> = input.lines().collect();
            let span = poste_core::sql_context::find_statement_span(&lines, cursor_line);
            let response = match span {
                Some((start, end)) => ContextStmtResponse { start_line: start, end_line: end },
                None => ContextStmtResponse { start_line: 0, end_line: 0 },
            };
            println!("{}", serde_json::to_string(&response)?);
        }
        ContextAction::Serve => {
            handle_serve()?;
        }
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Serve command: persistent line-delimited JSON protocol
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
struct ServeRequest {
    id: u64,
    method: String,
    params: serde_json::Value,
}

#[derive(Serialize)]
struct ServeResponse {
    id: u64,
    ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    result: Option<serde_json::Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

#[derive(Deserialize)]
struct DetectParams {
    sql: String,
    offset: usize,
    #[serde(default = "default_dialect")]
    dialect: String,
}

fn default_dialect() -> String {
    "generic".to_string()
}

#[derive(Deserialize)]
struct StmtParams {
    sql: String,
    cursor_line: usize,
}

fn handle_serve() -> Result<()> {
    let stdin = std::io::stdin();
    let reader = BufReader::new(stdin.lock());
    let stdout = std::io::stdout();
    let mut out = stdout.lock();

    for line in reader.lines() {
        let line = match line {
            Ok(l) => l,
            Err(_) => break, // EOF or error
        };
        if line.trim().is_empty() {
            continue;
        }

        let request: ServeRequest = match serde_json::from_str(&line) {
            Ok(r) => r,
            Err(e) => {
                // Can't parse — no id to respond with, skip
                eprintln!("[poste serve] invalid request: {}", e);
                continue;
            }
        };

        let response = match request.method.as_str() {
            "detect" => {
                match serde_json::from_value::<DetectParams>(request.params) {
                    Ok(params) => {
                        let dialect = match params.dialect.as_str() {
                            "postgres" => poste_core::sql_context::SqlDialect::Postgres,
                            "mysql" => poste_core::sql_context::SqlDialect::MySql,
                            "sqlite" => poste_core::sql_context::SqlDialect::Sqlite,
                            _ => poste_core::sql_context::SqlDialect::Generic,
                        };
                        let result = poste_core::sql_context::detect_context_with_dialect(
                            &params.sql, params.offset, dialect,
                        );
                        let ctx_resp = match result {
                            Some(ctx) => make_detect_response(&ctx),
                            None => ContextDetectResponse {
                                version: 1,
                                ctx_type: "keyword".into(),
                                ctx_data: None,
                                ctx_schema: None,
                                prefix: String::new(),
                                tables: vec![],
                                functions: vec![],
                                in_string: true,
                                in_comment: true,
                            },
                        };
                        let val = serde_json::to_value(&ctx_resp).unwrap_or_default();
                        ServeResponse { id: request.id, ok: true, result: Some(val), error: None }
                    }
                    Err(e) => ServeResponse {
                        id: request.id, ok: false, result: None,
                        error: Some(format!("invalid detect params: {}", e)),
                    },
                }
            }
            "stmt" => {
                match serde_json::from_value::<StmtParams>(request.params) {
                    Ok(params) => {
                        let lines: Vec<&str> = params.sql.lines().collect();
                        let span = poste_core::sql_context::find_statement_span(
                            &lines, params.cursor_line,
                        );
                        let stmt_resp = match span {
                            Some((start, end)) => ContextStmtResponse { start_line: start, end_line: end },
                            None => ContextStmtResponse { start_line: 0, end_line: 0 },
                        };
                        let val = serde_json::to_value(&stmt_resp).unwrap_or_default();
                        ServeResponse { id: request.id, ok: true, result: Some(val), error: None }
                    }
                    Err(e) => ServeResponse {
                        id: request.id, ok: false, result: None,
                        error: Some(format!("invalid stmt params: {}", e)),
                    },
                }
            }
            _ => ServeResponse {
                id: request.id, ok: false, result: None,
                error: Some(format!("unknown method: {}", request.method)),
            },
        };

        let json = serde_json::to_string(&response)?;
        writeln!(out, "{}", json)?;
        out.flush()?;
    }

    Ok(())
}

async fn handle_connection_command(action: ConnectionAction) -> Result<()> {
    use poste_exec::sql_connection::{ConnectionStore, test_connection};

    match action {
        ConnectionAction::List { path, env, json } => {
            let search_dir = match path {
                Some(p) => std::path::PathBuf::from(p),
                None => std::env::current_dir()?,
            };

            let store = ConnectionStore::load(&search_dir)?;

            // Load env vars for variable substitution display
            let env_vars = load_env_vars(&search_dir, &env);

            if json {
                let list = store.to_json_list();
                println!("{}", serde_json::to_string_pretty(&list)?);
            } else {
                if store.names().is_empty() {
                    println!("No connections found.");
                    if let Some(src) = store.source_path() {
                        println!("  Searched: {}", src.display());
                    }
                    return Ok(());
                }

                println!("Connections (from {:?}):\n", store.source_path());
                for item in store.to_json_list() {
                    let name = item["name"].as_str().unwrap_or("?");
                    let dialect = item["dialect"].as_str().unwrap_or("?");
                    let icon = match dialect {
                        "postgres" => "🐘",
                        "mysql" => "🐬",
                        "sqlite" => "📦",
                        _ => "❓",
                    };

                    if dialect == "sqlite" {
                        let path = item["path"].as_str().unwrap_or("?");
                        println!("  {} {} ({}) — {}", icon, name, dialect, path);
                    } else {
                        let host = item["host"].as_str().unwrap_or("?");
                        let port = item["port"].as_u64().unwrap_or(0);
                        let db = item["database"].as_str().unwrap_or("?");
                        println!("  {} {} ({}) — {}:{}/{}", icon, name, dialect, host, port, db);
                    }

                    // Show resolved URL
                    if let Ok(url) = store.resolve(name, &env_vars) {
                        println!("    → {}", url);
                    }
                }
            }
        }
        ConnectionAction::Test { name, path, env } => {
            let search_dir = match path {
                Some(p) => std::path::PathBuf::from(p),
                None => std::env::current_dir()?,
            };

            let store = ConnectionStore::load(&search_dir)?;
            let env_vars = load_env_vars(&search_dir, &env);

            let config = store.get(&name)
                .ok_or_else(|| anyhow::anyhow!("Connection '{}' not found", name))?;

            // Resolve variables
            let mut resolved = config.clone();
            resolved.host = resolved.host.map(|s| poste_core::substitute_vars(&s, &env_vars));
            resolved.password = resolved.password.map(|s| poste_core::substitute_vars(&s, &env_vars));
            resolved.user = resolved.user.map(|s| poste_core::substitute_vars(&s, &env_vars));
            resolved.database = resolved.database.map(|s| poste_core::substitute_vars(&s, &env_vars));
            resolved.path = resolved.path.map(|s| poste_core::substitute_vars(&s, &env_vars));

            print!("Testing connection '{}' ... ", name);
            std::io::Write::flush(&mut std::io::stdout())?;

            match test_connection(&resolved).await {
                Ok(_) => println!("✓ OK"),
                Err(e) => {
                    println!("✗ FAILED");
                    eprintln!("  Error: {}", e);
                    std::process::exit(1);
                }
            }
        }
    }

    Ok(())
}

/// Load env vars for variable substitution.
fn load_env_vars(search_dir: &std::path::Path, env_name: &str) -> std::collections::HashMap<String, String> {
    let mut dir = search_dir;
    loop {
        let candidate = dir.join("env.json");
        if candidate.exists() {
            if let Ok(env_file) = poste_core::Environment::load(candidate.to_str().expect("env.json path must be valid UTF-8")) {
                if let Some(vars) = env_file.envs.get(env_name) {
                    return vars.clone();
                }
            }
            break;
        }
        match dir.parent() {
            Some(parent) => dir = parent,
            None => break,
        }
    }
    std::collections::HashMap::new()
}

async fn handle_introspect_command(
    conn_name: String,
    introspect_type: String,
    schema: Option<String>,
    table: Option<String>,
    database: Option<String>,
    path: Option<String>,
    env: String,
) -> Result<()> {
    use poste_exec::sql_connection::ConnectionStore;
    use poste_exec::sql_introspect::{self, IntrospectParams, IntrospectType};

    let search_dir = match path {
        Some(p) => std::path::PathBuf::from(p),
        None => std::env::current_dir()?,
    };

    // Load and resolve connection
    let store = ConnectionStore::load(&search_dir)?;
    let env_vars = load_env_vars(&search_dir, &env);

    let config = store
        .get(&conn_name)
        .ok_or_else(|| anyhow::anyhow!("Connection '{}' not found", conn_name))?;

    // Resolve variables and build URL
    let mut resolved = config.clone();
    resolved.host = resolved.host.map(|s| poste_core::substitute_vars(&s, &env_vars));
    resolved.password = resolved.password.map(|s| poste_core::substitute_vars(&s, &env_vars));
    resolved.user = resolved.user.map(|s| poste_core::substitute_vars(&s, &env_vars));
    resolved.database = resolved.database.map(|s| poste_core::substitute_vars(&s, &env_vars));
    resolved.path = resolved.path.map(|s| poste_core::substitute_vars(&s, &env_vars));

    let mut connection_url = resolved.to_url();
    let dialect_name = resolved.dialect.clone();

    // Override database if --database flag is provided
    if let Some(ref db) = database {
        connection_url = poste_core::replace_database_in_url(&connection_url, db);
    }

    let params = IntrospectParams {
        connection_url,
        dialect_name,
        introspect_type: IntrospectType::parse_str(&introspect_type)?,
        schema,
        table,
    };

    let result = sql_introspect::introspect(&params).await?;
    println!("{}", serde_json::to_string(&result)?);

    Ok(())
}
