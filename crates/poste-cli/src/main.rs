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
            // Load environment
            let env_path = format!("{}/../env.json", std::path::Path::new(&file).parent().unwrap().display());
            let env_file = if std::path::Path::new(&env_path).exists() {
                poste_core::Environment::load(&env_path)?
            } else {
                anyhow::bail!("Environment file not found: {}", env_path);
            };
            
            let env_vars = env_file.envs.get(&env)
                .ok_or_else(|| anyhow::anyhow!("Environment '{}' not found", env))?
                .clone();
            
            // Parse the request
            let content = std::fs::read_to_string(&file)?;
            let parser = poste_core::Parser::new(env_vars);
            let request = parser.parse_at_line(&content, line)?;
            
            println!("Executing: {:?}", request.name);
            println!("Protocol: {:?}", request.protocol);
            println!("Connection: {}", request.connection);
            println!();
            
            // Execute the request
            let response = poste_exec::Executor::execute(&request).await?;
            
            println!("Status: {}", response.status);
            println!("Headers:");
            for (key, value) in &response.headers {
                println!("  {}: {}", key, value);
            }
            println!();
            println!("Body:");
            println!("{}", response.body);
        }
    }

    Ok(())
}
