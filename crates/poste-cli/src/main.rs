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
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();

    match cli.command {
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
            let parser = poste_core::Parser::new(env_vars);
            let request = parser.parse_at_line(&content, line, &file_ext)?;

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
