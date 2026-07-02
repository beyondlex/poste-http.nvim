use anyhow::{Context, Result};
use clap::Parser;
use std::io::Read;

/// Execute a request at a specific line
#[derive(Parser)]
pub struct RunArgs {
    /// File path (used for env.json discovery and extension detection;
    /// with --stdin the file does not need to exist on disk)
    pub file: String,
    /// Line number
    #[arg(short, long)]
    pub line: usize,
    /// Environment name
    #[arg(short, long, default_value = "dev")]
    pub env: String,
    /// Output as JSON (for Neovim plugin consumption)
    #[arg(long)]
    pub json: bool,
    /// Read request content from stdin instead of from the file
    #[arg(long)]
    pub stdin: bool,
    /// Override database name (for USE statement context from the editor)
    #[arg(long)]
    pub database: Option<String>,
}

pub async fn execute(args: RunArgs) -> Result<()> {
    let file_path = std::path::PathBuf::from(&args.file);

    // Determine the directory to search for env.json, and the file extension.
    // With --stdin the file may not exist on disk, so use its path as-is.
    let (search_dir, file_ext) = if args.stdin {
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
        let dir = abs
            .parent()
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
        let dir = canonical
            .parent()
            .context("File path resolves to root")?
            .to_path_buf();
        (dir, ext)
    };

    // Find env.json: optional (SQL files with direct connection names don't need it)
    let mut dir = search_dir.as_path();
    let env_vars = loop {
        let candidate = dir.join("env.json");
        if candidate.exists() {
            let env_file = poste_core::Environment::load(
                candidate
                    .to_str()
                    .context("env.json path is not valid UTF-8")?,
            )?;
            let vars = env_file.envs.get(&args.env).cloned().unwrap_or_default();
            break vars;
        }
        match dir.parent() {
            Some(parent) => dir = parent,
            None => break std::collections::HashMap::new(),
        }
    };

    // Read request content
    let content = if args.stdin {
        let mut buf = String::new();
        std::io::stdin().read_to_string(&mut buf)?;
        buf
    } else {
        let canonical = std::fs::canonicalize(&file_path).unwrap_or(file_path.clone());
        std::fs::read_to_string(&canonical)?
    };

    // Parse the request
    let parser = poste_core::Parser::new(env_vars.clone());
    let mut request = parser.parse_at_line(&content, args.line, &file_ext)?;

    // Resolve connection name for SQL protocols
    if crate::util::is_sql_protocol(&request.protocol)
        && !crate::util::is_connection_url(&request.connection)
        && !request.connection.is_empty()
    {
        let conn_name = request.connection.clone();
        let conn_store = poste_exec::sql_connection::ConnectionStore::load(&search_dir)?;
        request.connection = conn_store
            .resolve(&conn_name, &env_vars)
            .map_err(|e| anyhow::anyhow!("Failed to resolve connection '{}': {}", conn_name, e))?;
    }

    // Override database from --database flag
    if let Some(ref db) = args.database {
        if crate::util::is_sql_protocol(&request.protocol) && !request.connection.is_empty() {
            request.connection = poste_core::replace_database_in_url(&request.connection, db);
        }
    }

    // Auto-detect protocol from connection URL for .sql files
    if request.protocol == poste_core::Protocol::Postgres
        && request.connection.starts_with("sqlite:")
    {
        request.protocol = poste_core::Protocol::Sqlite;
    }
    if request.protocol == poste_core::Protocol::Postgres
        && request.connection.starts_with("mysql://")
    {
        request.protocol = poste_core::Protocol::Mysql;
    }

    // Load cookie jar
    let cookie_jar = poste_exec::CookieJar::load(&args.env);

    // Execute
    let response = poste_exec::Executor::execute(&request, Some(&cookie_jar)).await?;

    // Save cookies (best effort)
    if let Err(e) = cookie_jar.save() {
        eprintln!("[poste] warning: failed to save cookies: {}", e);
    }

    if args.json {
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
                println!(
                    "  {}={} (domain={}, path={})",
                    c.name, c.value, c.domain, c.path
                );
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

    Ok(())
}

/// Load env vars for variable substitution.
pub fn load_env_vars(
    search_dir: &std::path::Path,
    env_name: &str,
) -> std::collections::HashMap<String, String> {
    let mut dir = search_dir;
    loop {
        let candidate = dir.join("env.json");
        if candidate.exists() {
            if let Ok(env_file) = poste_core::Environment::load(
                candidate
                    .to_str()
                    .expect("env.json path must be valid UTF-8"),
            ) {
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
