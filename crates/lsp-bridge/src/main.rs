use lsp_bridge::{LspBridge, VimAction, VimCommand};
use std::io::{self, BufRead};
use tokio::io::AsyncWriteExt;
use tokio::sync::mpsc;
use tracing::{error, info};

/// 解析Vim输入为命令 - 使用类型安全的 VimCommand enum
fn parse_vim_input(input: &str) -> Option<VimCommand> {
    serde_json::from_str::<VimCommand>(input).ok()
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    use std::fs::OpenOptions;
    use tracing_subscriber::{fmt, layer::SubscriberExt, util::SubscriberInitExt};

    let pid = std::process::id();
    let log_path = format!("/tmp/lsp-bridge-{}.log", pid);

    let log_file = OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .open(&log_path)?;

    tracing_subscriber::registry()
        .with(fmt::layer().with_writer(log_file).with_ansi(false))
        .init();

    info!("lsp-bridge starting with log: {}", log_path);

    let init_action = VimAction::Init {
        log_file: log_path.clone(),
    };

    let mut stdout = tokio::io::stdout();
    let init_json = serde_json::to_string(&init_action)?;
    stdout.write_all((init_json + "\n").as_bytes()).await?;
    stdout.flush().await?;

    // Create channel for diagnostic notifications
    let (diagnostic_tx, mut diagnostic_rx) = mpsc::unbounded_channel::<VimAction>();
    let mut bridge = LspBridge::with_diagnostic_sender(diagnostic_tx);
    let stdin = io::stdin();

    for line in stdin.lock().lines() {
        match line {
            Ok(input) => {
                if input.trim().is_empty() {
                    continue;
                }

                info!("Received input: {}", input);

                if let Some(vim_cmd) = parse_vim_input(&input) {
                    let file_path = vim_cmd.file_path();
                    info!("Processing command: {:?} for {}", vim_cmd, file_path);

                    let action = bridge.handle_command(vim_cmd).await;

                    let response_json = serde_json::to_string(&action)?;
                    info!("Sending response: {}", response_json);
                    stdout.write_all(response_json.as_bytes()).await?;
                    stdout.write_all(b"\n").await?;
                    stdout.flush().await?;

                    // Check for any pending diagnostic notifications
                    while let Ok(diagnostic_action) = diagnostic_rx.try_recv() {
                        let diagnostic_json = serde_json::to_string(&diagnostic_action)?;
                        info!("Sending diagnostic notification: {}", diagnostic_json);
                        stdout.write_all(diagnostic_json.as_bytes()).await?;
                        stdout.write_all(b"\n").await?;
                        stdout.flush().await?;
                    }

                    info!("Command processed");
                    continue;
                }

                error!("Failed to parse input as VimCommand: {}", input);
                let error_response = VimAction::Error {
                    message: format!("Invalid command format: {}", input),
                };

                let response_json = serde_json::to_string(&error_response)?;
                stdout.write_all(response_json.as_bytes()).await?;
                stdout.write_all(b"\n").await?;
                stdout.flush().await?;
            }
            Err(e) => {
                error!("Failed to read from stdin: {}", e);
                break;
            }
        }
    }

    info!("lsp-bridge shutting down...");
    Ok(())
}
