use lsp_bridge::{VimCommand, VimAction, LspBridge};
use std::io::{self, BufRead};
use tokio::io::AsyncWriteExt;
use tracing::{error, info};

/// 解析Vim输入为命令
fn parse_vim_input(input: &str) -> Option<VimCommand> {
    serde_json::from_str::<VimCommand>(input).ok()
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // 初始化日志到文件
    use tracing_subscriber::{fmt, layer::SubscriberExt, util::SubscriberInitExt};
    use std::fs::OpenOptions;
    
    let log_file = OpenOptions::new()
        .create(true)
        .append(true)
        .open("/tmp/lsp-bridge.log")?;
        
    tracing_subscriber::registry()
        .with(fmt::layer().with_writer(log_file))
        .init();
    
    info!("lsp-bridge starting...");
    
    let mut bridge = LspBridge::new();
    let stdin = io::stdin();
    let mut stdout = tokio::io::stdout();
    
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
                    info!("Processing command: {} for {}", vim_cmd.command, vim_cmd.file);
                    
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