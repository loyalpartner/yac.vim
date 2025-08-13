use anyhow::Result;
use tracing::{info, instrument};

mod bridge;
mod file;
mod handlers;
mod lsp;
mod utils;

use crate::bridge::BridgeServer;
use crate::utils::config::Config;

#[instrument]
#[tokio::main]
async fn main() -> Result<()> {
    setup_logging();

    info!("Starting YAC.vim LSP Bridge");

    let config = Config::load()?;
    let mut server = BridgeServer::new(config).await?;

    info!("LSP Bridge server started successfully");
    server.run().await?;

    Ok(())
}

fn setup_logging() {
    tracing_subscriber::fmt()
        .with_env_filter(
            std::env::var("RUST_LOG").unwrap_or_else(|_| "yac_vim=debug,info".to_string()),
        )
        .init();
}
