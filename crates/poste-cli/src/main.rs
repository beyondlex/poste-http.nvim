use clap::{Parser, Subcommand};
use anyhow::Result;

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
        /// File path
        file: String,
        /// Line number
        #[arg(short, long)]
        line: usize,
        /// Environment name
        #[arg(short, long, default_value = "dev")]
        env: String,
    },
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();

    match cli.command {
        Commands::Run { file, line, env } => {
            // Resolve the request file to an absolute path
            let file_path = std::path::Path::new(&file);
            let file_path = if file_path.is_absolute() {
                file_path.to_path_buf()
            } else {
                std::env::current_dir()?.join(file_path)
            };
            
            // Canonicalize to resolve .. and symlinks
            let file_path = std::fs::canonicalize(&file_path)
                .map_err(|e| anyhow::anyhow!("Request file not found: {} ({})", file_path.display(), e))?;

            // Find env.json: look in the request file's directory, then walk up
            let mut search_dir = file_path.parent().unwrap();
            let env_path = loop {
                let candidate = search_dir.join("env.json");
                if candidate.exists() {
                    break candidate;
                }
                match search_dir.parent() {
                    Some(parent) => search_dir = parent,
                    None => anyhow::bail!(
                        "env.json not found. Searched from {} to filesystem root",
                        file_path.parent().unwrap().display()
                    ),
                }
            };
            let env_file = poste_core::Environment::load(env_path.to_str().unwrap())?;
            
            let env_vars = env_file.envs.get(&env)
                .ok_or_else(|| anyhow::anyhow!("Environment '{}' not found", env))?
                .clone();
            
            // Parse the request
            let content = std::fs::read_to_string(&file_path)?;
            let parser = poste_core::Parser::new(env_vars);
            let request = parser.parse_at_line(&content, line)?;
            
            println!("Executing: {:?}", request.name);
            println!("Protocol: {:?}", request.protocol);
            println!("Connection: {}", request.connection);
            println!();
            
            // Execute the request and measure latency
            let start = std::time::Instant::now();
            let response = poste_exec::Executor::execute(&request).await?;
            let latency_ms = start.elapsed().as_millis();

            println!("Status: {}", response.status);
            println!("Latency: {}ms", latency_ms);
            println!("Headers:");
            for (key, value) in &response.headers {
                println!("  {}: {}", key, value);
            }
            println!();
            println!("Body:");

            // Pretty-print JSON responses
            if response.headers.get("content-type")
                .map(|ct| ct.contains("json"))
                .unwrap_or(false)
            {
                match serde_json::from_str::<serde_json::Value>(&response.body) {
                    Ok(json) => println!("{}", serde_json::to_string_pretty(&json).unwrap()),
                    Err(_) => println!("{}", response.body),
                }
            } else {
                println!("{}", response.body);
            }
        }
    }

    Ok(())
}
