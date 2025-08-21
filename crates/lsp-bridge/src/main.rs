use lsp_bridge::{LspBridge, VimAction, VimCommand};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::mpsc;
use tracing::{error, info};

/// 解析Vim输入为命令 - 使用类型安全的 VimCommand enum
fn parse_vim_input(input: &str) -> Option<VimCommand> {
    serde_json::from_str::<VimCommand>(input).ok()
}

/// Linus 风格：消除特殊情况，统一输出处理
async fn send_response(
    stdout: &mut tokio::io::Stdout,
    action: &VimAction,
) -> Result<(), Box<dyn std::error::Error>> {
    let response_json = serde_json::to_string(action)?;
    stdout.write_all(response_json.as_bytes()).await?;
    stdout.write_all(b"\n").await?;
    stdout.flush().await?;
    Ok(())
}

/// Linus 风格：简化输入处理，消除深层嵌套
async fn handle_stdin_input(
    input: &str,
    bridge: &mut LspBridge,
    stdout: &mut tokio::io::Stdout,
) -> Result<(), Box<dyn std::error::Error>> {
    if input.is_empty() {
        return Ok(());
    }

    info!("Received input: {}", input);

    let action = match parse_vim_input(input) {
        Some(vim_cmd) => {
            let file_path = vim_cmd.file_path();
            info!("Processing command: {:?} for {}", vim_cmd, file_path);
            bridge.handle_command(vim_cmd).await
        }
        None => {
            error!("Failed to parse input as VimCommand: {}", input);
            VimAction::Error {
                message: format!("Invalid command format: {}", input),
            }
        }
    };

    info!("Sending response: {:?}", action);
    send_response(stdout, &action).await?;
    info!("Command processed");
    Ok(())
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

    let stdin = tokio::io::stdin();
    let mut reader = BufReader::new(stdin);
    let mut line_buffer = String::new();

    // Linus 风格：简单的事件循环，最多2层嵌套
    loop {
        tokio::select! {
            // Handle Vim commands from stdin
            result = reader.read_line(&mut line_buffer) => {
                match result {
                    Ok(0) => {
                        info!("EOF reached, shutting down");
                        break;
                    }
                    Ok(_) => {
                        let input = line_buffer.trim();
                        if let Err(e) = handle_stdin_input(input, &mut bridge, &mut stdout).await {
                            error!("Failed to handle input: {}", e);
                        }
                        line_buffer.clear();
                    }
                    Err(e) => {
                        error!("Failed to read from stdin: {}", e);
                        break;
                    }
                }
            }

            // Handle diagnostic notifications
            diagnostic_action = diagnostic_rx.recv() => {
                match diagnostic_action {
                    Some(action) => {
                        info!("Sending real-time diagnostic notification");
                        if let Err(e) = send_response(&mut stdout, &action).await {
                            error!("Failed to send diagnostic: {}", e);
                        }
                    }
                    None => {
                        info!("Diagnostic channel closed");
                        break;
                    }
                }
            }
        }
    }

    info!("lsp-bridge shutting down...");
    Ok(())
}
