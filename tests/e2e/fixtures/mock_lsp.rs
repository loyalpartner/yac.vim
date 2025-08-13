use serde_json::{json, Value};
use std::collections::HashMap;
use std::io::{self, BufRead, BufReader, Write};
use std::process::{Command, Stdio};
use tokio::net::{TcpListener, TcpStream};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

/// 简单的Mock LSP服务器，用于自动化测试
pub struct SimpleMockLsp {
    responses: HashMap<String, Value>,
    port: u16,
}

impl SimpleMockLsp {
    pub fn new(port: u16) -> Self {
        let mut responses = HashMap::new();
        
        // 预设补全响应
        responses.insert("textDocument/completion".to_string(), json!({
            "items": [
                {
                    "label": "println!",
                    "kind": 3,
                    "detail": "macro",
                    "insertText": "println!(\"{}\")",
                    "documentation": "Prints to the standard output"
                },
                {
                    "label": "vec!",
                    "kind": 3,
                    "detail": "macro",
                    "insertText": "vec![]",
                    "documentation": "Creates a Vec containing the provided elements"
                }
            ]
        }));
        
        // 预设悬停响应
        responses.insert("textDocument/hover".to_string(), json!({
            "contents": {
                "kind": "markdown",
                "value": "**Function: println!**\n\nPrints to the standard output, with a newline."
            },
            "range": {
                "start": {"line": 0, "character": 4},
                "end": {"line": 0, "character": 12}
            }
        }));
        
        // 预设定义跳转响应
        responses.insert("textDocument/definition".to_string(), json!([
            {
                "uri": "file:///test.rs",
                "range": {
                    "start": {"line": 5, "character": 0},
                    "end": {"line": 5, "character": 10}
                }
            }
        ]));
        
        // 预设initialize响应
        responses.insert("initialize".to_string(), json!({
            "capabilities": {
                "textDocumentSync": 1,
                "completionProvider": {
                    "triggerCharacters": ["."]
                },
                "hoverProvider": true,
                "definitionProvider": true,
                "referencesProvider": true
            },
            "serverInfo": {
                "name": "mock-lsp-server",
                "version": "1.0.0"
            }
        }));
        
        Self { responses, port }
    }
    
    /// 启动Mock LSP服务器
    pub async fn start(&self) -> io::Result<()> {
        let listener = TcpListener::bind(format!("127.0.0.1:{}", self.port)).await?;
        println!("[Mock LSP] 服务器启动在端口 {}", self.port);
        
        while let Ok((stream, addr)) = listener.accept().await {
            println!("[Mock LSP] 接受连接: {}", addr);
            let responses = self.responses.clone();
            
            tokio::spawn(async move {
                if let Err(e) = Self::handle_connection(stream, responses).await {
                    eprintln!("[Mock LSP] 处理连接错误: {}", e);
                }
            });
        }
        
        Ok(())
    }
    
    async fn handle_connection(
        mut stream: TcpStream,
        responses: HashMap<String, Value>
    ) -> io::Result<()> {
        let mut buffer = vec![0; 1024];
        
        loop {
            match stream.read(&mut buffer).await {
                Ok(0) => break,
                Ok(n) => {
                    let data = String::from_utf8_lossy(&buffer[..n]);
                    if let Some(response) = Self::process_request(&data, &responses) {
                        stream.write_all(response.as_bytes()).await?;
                        stream.flush().await?;
                    }
                }
                Err(e) => {
                    eprintln!("[Mock LSP] 读取错误: {}", e);
                    break;
                }
            }
        }
        
        println!("[Mock LSP] 连接关闭");
        Ok(())
    }
    
    fn process_request(data: &str, responses: &HashMap<String, Value>) -> Option<String> {
        // 使用LSP消息解析器解析Content-Length格式的消息
        let mut parser = yac_vim::lsp::LspMessageParser::new();
        
        if let Ok(messages) = parser.parse_messages(data) {
            for message in messages {
                match message {
                    yac_vim::lsp::JsonRpcMessage::Request(request) => {
                        if let Some(result) = responses.get(&request.method) {
                            let response = json!({
                                "jsonrpc": "2.0",
                                "id": request.id,
                                "result": result
                            });
                            
                            println!("[Mock LSP] 响应方法: {}", request.method);
                            let response_str = response.to_string();
                            return Some(yac_vim::lsp::format_lsp_message(&response_str));
                        }
                    }
                    yac_vim::lsp::JsonRpcMessage::Notification(notification) => {
                        println!("[Mock LSP] 收到通知: {}", notification.method);
                        // 通知不需要响应
                    }
                    _ => {}
                }
            }
        }
        
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    
    #[test]
    fn test_mock_lsp_creation() {
        let mock_lsp = SimpleMockLsp::new(9999);
        assert_eq!(mock_lsp.port, 9999);
        assert!(mock_lsp.responses.contains_key("textDocument/completion"));
        assert!(mock_lsp.responses.contains_key("textDocument/hover"));
        assert!(mock_lsp.responses.contains_key("textDocument/definition"));
    }
}