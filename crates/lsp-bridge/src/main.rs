use lsp_bridge::{LspBridge, VimAction, VimCommand};
use std::io::{self, BufRead};
use tokio::io::AsyncWriteExt;
use tracing::{error, info};

/// 解析Vim输入为命令
fn parse_vim_input(input: &str) -> Option<VimCommand> {
    serde_json::from_str::<VimCommand>(input).ok()
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // 初始化日志到文件 - 每个进程独立日志
    use std::fs::OpenOptions;
    use tracing_subscriber::{fmt, layer::SubscriberExt, util::SubscriberInitExt};

    let pid = std::process::id();
    let log_path = format!("/tmp/lsp-bridge-{}.log", pid);

    let log_file = OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true) // 重新启动时清空日志
        .open(&log_path)?;

    tracing_subscriber::registry()
        .with(fmt::layer().with_writer(log_file).with_ansi(false))
        .init();

    info!("lsp-bridge starting with log: {}", log_path);

    // 向Vim发送初始化信息，包含日志路径
    let init_action = VimAction::Init {
        log_file: log_path.clone(),
    };

    let mut stdout = tokio::io::stdout();
    let init_json = serde_json::to_string(&init_action)?;
    stdout.write_all((init_json + "\n").as_bytes()).await?;
    stdout.flush().await?;

    let mut bridge = LspBridge::new();
    let stdin = io::stdin();

    // 读取 stdin 的每一行作为请求
    for line in stdin.lock().lines() {
        match line {
            Ok(input) => {
                if input.trim().is_empty() {
                    continue;
                }

                // 记录收到的输入，用于调试
                info!("Received input: {}", input);

                // 尝试解析为命令
                if let Some(vim_cmd) = parse_vim_input(&input) {
                    info!(
                        "Processing command: {} for {}",
                        vim_cmd.command, vim_cmd.file
                    );

                    // 处理Vim命令
                    let action = bridge.handle_command(vim_cmd).await;

                    // 返回动作
                    let response_json = serde_json::to_string(&action)?;
                    info!("Sending response: {}", response_json);
                    stdout.write_all(response_json.as_bytes()).await?;
                    stdout.write_all(b"\n").await?;
                    stdout.flush().await?;

                    info!("Command processed");
                    continue;
                }

                // 无法解析的输入
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
