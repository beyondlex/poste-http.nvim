use clap::{Parser, Subcommand};
use anyhow::Result;
use std::io::Read;

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
    },
    /// Manage SQL connections
    Connection {
        #[command(subcommand)]
        action: ConnectionAction,
    },
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
        Commands::Run { file, line, env, json, stdin } => {
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
                let dir = canonical.parent().unwrap().to_path_buf();
                (dir, ext)
            };

            // Find env.json: look in search_dir, then walk up
            let mut dir = search_dir.as_path();
            let env_path = loop {
                let candidate = dir.join("env.json");
                if candidate.exists() {
                    break candidate;
                }
                match dir.parent() {
                    Some(parent) => dir = parent,
                    None => anyhow::bail!(
                        "env.json not found. Searched from {} to filesystem root",
                        search_dir.display()
                    ),
                }
            };
            let env_file = poste_core::Environment::load(env_path.to_str().unwrap())?;

            let env_vars = env_file.envs.get(&env)
                .ok_or_else(|| anyhow::anyhow!("Environment '{}' not found", env))?
                .clone();

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
            resolved.host = resolved.host.map(|s| substitute_vars_cli(&s, &env_vars));
            resolved.password = resolved.password.map(|s| substitute_vars_cli(&s, &env_vars));
            resolved.user = resolved.user.map(|s| substitute_vars_cli(&s, &env_vars));
            resolved.database = resolved.database.map(|s| substitute_vars_cli(&s, &env_vars));
            resolved.path = resolved.path.map(|s| substitute_vars_cli(&s, &env_vars));

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
            if let Ok(env_file) = poste_core::Environment::load(candidate.to_str().unwrap()) {
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

/// Substitute {{var}} references for CLI display.
fn substitute_vars_cli(input: &str, vars: &std::collections::HashMap<String, String>) -> String {
    use regex::Regex;
    let re = Regex::new(r"\{\{([^}]+)\}\}").unwrap();
    re.replace_all(input, |caps: &regex::Captures| {
        let var_name = &caps[1];
        vars.get(var_name)
            .cloned()
            .unwrap_or_else(|| caps[0].to_string())
    })
    .to_string()
}
