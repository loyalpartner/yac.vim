use bytes::{Bytes, BytesMut};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;
use std::io;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};
use tokio::sync::{mpsc, oneshot};
use tokio::task::JoinHandle;
use tracing::{debug, error, warn};
use std::sync::atomic::{AtomicU32, Ordering};

pub mod mock;

// Constants - zero allocation
const JSONRPC_VERSION: &str = "2.0";
const CONTENT_LENGTH_HEADER: &str = "Content-Length: ";
const CRLF: &str = "\r\n";
const MAX_BUFFER_SIZE: usize = 1024 * 1024; // 1MB buffer limit

#[derive(Debug, thiserror::Error)]
pub enum LspError {
    #[error("IO: {0}")]
    Io(#[from] io::Error),
    #[error("JSON: {0}")]
    Json(#[from] serde_json::Error),
    #[error("Protocol: {0}")]
    Protocol(String),
    #[error("Process failed")]
    Process,
    #[error("Channel closed")]
    ChannelClosed,
    #[error("Timeout")]
    Timeout,
    #[error("Connection reset")]
    ConnectionReset,
    #[error("Invalid response {request_id}: {reason}")]
    InvalidResponse {
        request_id: String,
        reason: String,
    },
    #[error("Server error {code}: {message}")]
    ServerError {
        code: i32,
        message: String,
        data: Option<Value>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(untagged)]
pub enum RequestId {
    Number(u32),
    String(String),
}

impl From<u32> for RequestId {
    fn from(id: u32) -> Self {
        RequestId::Number(id)
    }
}

impl From<String> for RequestId {
    fn from(id: String) -> Self {
        RequestId::String(id)
    }
}

pub type Result<T> = std::result::Result<T, LspError>;

// Core message types - simpler is better
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(untagged)]
pub enum JsonRpcMessage {
    Request(JsonRpcRequest),
    Response(JsonRpcResponse),
    Notification(JsonRpcNotification),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JsonRpcRequest {
    pub jsonrpc: String,
    pub id: RequestId,
    pub method: String,
    pub params: Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JsonRpcResponse {
    pub jsonrpc: String,
    pub id: RequestId,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<JsonRpcError>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JsonRpcNotification {
    pub jsonrpc: String,
    pub method: String,
    pub params: Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JsonRpcError {
    pub code: i32,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<Value>,
}

// Message framing for LSP (Content-Length header protocol)
pub struct MessageFramer {
    buffer: BytesMut,
}

impl MessageFramer {
    pub fn new() -> Self {
        Self {
            buffer: BytesMut::with_capacity(8192),
        }
    }

    // Frame a message with Content-Length header
    pub fn frame_message(&mut self, content: &str) -> Bytes {
        self.buffer.clear();
        self.buffer.extend_from_slice(CONTENT_LENGTH_HEADER.as_bytes());
        self.buffer.extend_from_slice(content.len().to_string().as_bytes());
        self.buffer.extend_from_slice(CRLF.as_bytes());
        self.buffer.extend_from_slice(CRLF.as_bytes());
        self.buffer.extend_from_slice(content.as_bytes());
        self.buffer.split().freeze()
    }

    // Parse incoming messages from buffer
    pub fn parse_messages(&mut self, data: &[u8]) -> Result<Vec<String>> {
        // Prevent buffer overflow attacks
        if self.buffer.len() + data.len() > MAX_BUFFER_SIZE {
            return Err(LspError::Protocol(
                format!("Buffer overflow: {} bytes exceeds limit", self.buffer.len() + data.len())
            ));
        }
        
        self.buffer.extend_from_slice(data);
        let mut messages = Vec::new();

        while self.buffer.len() > 0 {
            // Look for Content-Length header
            let header_end = self.find_header_end()?;
            if header_end.is_none() {
                break; // Need more data
            }
            
            let header_end = header_end.unwrap();
            let content_length = self.parse_content_length(header_end)?;
            
            let message_start = header_end + 4; // Skip \r\n\r\n
            let message_end = message_start + content_length;
            
            if self.buffer.len() < message_end {
                break; // Need more data
            }
            
            // Extract complete message
            let message_bytes = self.buffer.split_to(message_end);
            let message = String::from_utf8_lossy(&message_bytes[message_start..])
                .into_owned();
            messages.push(message);
        }

        Ok(messages)
    }

    fn find_header_end(&self) -> Result<Option<usize>> {
        let pattern = b"\r\n\r\n";
        Ok(self.buffer.windows(pattern.len())
            .position(|window| window == pattern))
    }

    fn parse_content_length(&self, header_end: usize) -> Result<usize> {
        let header = &self.buffer[..header_end];
        let header_str = std::str::from_utf8(header)
            .map_err(|_| LspError::Protocol("Invalid UTF-8 in header".to_string()))?;
        
        for line in header_str.lines() {
            if line.starts_with(CONTENT_LENGTH_HEADER) {
                let length_str = &line[CONTENT_LENGTH_HEADER.len()..];
                return length_str.parse()
                    .map_err(|_| LspError::Protocol("Invalid Content-Length".to_string()));
            }
        }
        
        Err(LspError::Protocol("Missing Content-Length header".to_string()))
    }
}

// Transport layer - handles process communication
pub struct LspTransport {
    child: Child,
    stdin: ChildStdin,
    stdout: ChildStdout,
    framer: MessageFramer,
}

impl LspTransport {
    pub async fn spawn(command: &str, args: &[&str]) -> Result<Self> {
        let mut child = Command::new(command)
            .args(args)
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null())
            .spawn()?;

        let stdin = child.stdin.take()
            .ok_or(LspError::Process)?;
        let stdout = child.stdout.take()
            .ok_or(LspError::Process)?;

        Ok(Self {
            child,
            stdin,
            stdout,
            framer: MessageFramer::new(),
        })
    }

    pub async fn send_message(&mut self, message: &str) -> Result<()> {
        let framed = self.framer.frame_message(message);
        self.stdin.write_all(&framed).await?;
        self.stdin.flush().await?;
        debug!("Sent: {}", message);
        Ok(())
    }

    pub async fn read_messages(&mut self) -> Result<Vec<String>> {
        let mut buffer = [0u8; 4096];
        let n = self.stdout.read(&mut buffer).await?;
        
        if n == 0 {
            return Err(LspError::ConnectionReset);
        }

        self.framer.parse_messages(&buffer[..n])
    }

    pub async fn shutdown(&mut self) -> Result<()> {
        // Try graceful shutdown first
        if let Err(e) = self.send_message(r#"{"jsonrpc":"2.0","method":"shutdown","id":0}"#).await {
            warn!("Failed to send shutdown request: {}", e);
        }
        
        // Wait for graceful exit with timeout
        tokio::select! {
            result = self.child.wait() => {
                match result {
                    Ok(status) => debug!("LSP server exited with status: {}", status),
                    Err(e) => warn!("Error waiting for LSP server exit: {}", e),
                }
            }
            _ = tokio::time::sleep(Duration::from_secs(5)) => {
                warn!("LSP server didn't shutdown gracefully within 5s, killing");
                if let Err(e) = self.child.kill().await {
                    error!("Failed to kill LSP server: {}", e);
                }
            }
        }
        Ok(())
    }
}

// Protocol state machine
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum LspState {
    Uninitialized,
    Initializing,
    Initialized,
    ShuttingDown,
    Shutdown,
}

// Request/Response matching
pub struct PendingRequest {
    pub method: String,
    pub sender: oneshot::Sender<Result<Value>>,
}

// Commands sent to the background task
#[derive(Debug)]
enum ClientCommand {
    SendRequest {
        method: String,
        params: Value,
        response_tx: oneshot::Sender<Result<Value>>,
    },
    SendNotification {
        method: String,
        params: Value,
    },
    Shutdown,
}

// Main LSP client - now just a handle to the background task
pub struct LspClient {
    command_tx: mpsc::Sender<ClientCommand>,
    _background_task: JoinHandle<()>,
}

// The actual client logic runs in the background
struct LspClientInner {
    transport: LspTransport,
    state: LspState,
    request_id_counter: AtomicU32,
    pending_requests: HashMap<RequestId, PendingRequest>,
    command_rx: mpsc::Receiver<ClientCommand>,
}

impl LspClient {
    pub async fn new(command: &str, args: &[&str]) -> Result<Self> {
        let transport = LspTransport::spawn(command, args).await?;
        let (command_tx, command_rx) = mpsc::channel(100);
        
        let mut inner = LspClientInner {
            transport,
            state: LspState::Uninitialized,
            request_id_counter: AtomicU32::new(0),
            pending_requests: HashMap::new(),
            command_rx,
        };

        let background_task = tokio::spawn(async move {
            if let Err(e) = inner.run().await {
                error!("LSP client background task failed: {}", e);
            }
        });
        
        Ok(Self {
            command_tx,
            _background_task: background_task,
        })
    }

    pub async fn request(&self, method: &str, params: Value) -> Result<Value> {
        let (response_tx, response_rx) = oneshot::channel();
        
        let command = ClientCommand::SendRequest {
            method: method.to_string(),
            params,
            response_tx,
        };
        
        self.command_tx.send(command).await
            .map_err(|_| LspError::ChannelClosed)?;
        
        response_rx.await.map_err(|_| LspError::ChannelClosed)?
    }

    pub async fn notify(&self, method: &str, params: Value) -> Result<()> {
        let command = ClientCommand::SendNotification {
            method: method.to_string(),
            params,
        };
        
        self.command_tx.send(command).await
            .map_err(|_| LspError::ChannelClosed)?;
        
        Ok(())
    }

    pub async fn shutdown(&self) -> Result<()> {
        self.command_tx.send(ClientCommand::Shutdown).await
            .map_err(|_| LspError::ChannelClosed)?;
        Ok(())
    }
}

impl LspClientInner {
    fn next_request_id(&self) -> RequestId {
        let id = self.request_id_counter.fetch_add(1, Ordering::SeqCst);
        RequestId::Number(id)
    }

    async fn run(&mut self) -> Result<()> {
        loop {
            tokio::select! {
                // Handle commands from the main client
                cmd = self.command_rx.recv() => {
                    match cmd {
                        Some(ClientCommand::SendRequest { method, params, response_tx }) => {
                            if let Err(e) = self.handle_send_request(&method, params, response_tx).await {
                                error!("Failed to handle request {}: {}", method, e);
                            }
                        }
                        Some(ClientCommand::SendNotification { method, params }) => {
                            if let Err(e) = self.handle_send_notification(&method, params).await {
                                error!("Failed to handle notification {}: {}", method, e);
                            }
                        }
                        Some(ClientCommand::Shutdown) => {
                            self.state = LspState::ShuttingDown;
                            let _ = self.transport.shutdown().await;
                            self.state = LspState::Shutdown;
                            break;
                        }
                        None => break, // Channel closed
                    }
                }
                
                // Read messages from the LSP server
                messages = self.transport.read_messages() => {
                    match messages {
                        Ok(msgs) => {
                            for message in msgs {
                                if let Err(e) = self.handle_message(&message) {
                                    error!("Failed to handle message: {}", e);
                                }
                            }
                        }
                        Err(e) => {
                            error!("Failed to read messages: {}", e);
                            break;
                        }
                    }
                }
            }
        }
        Ok(())
    }

    async fn handle_send_request(&mut self, method: &str, params: Value, response_tx: oneshot::Sender<Result<Value>>) -> Result<()> {
        let id = self.next_request_id();
        let request = JsonRpcRequest {
            jsonrpc: JSONRPC_VERSION.to_string(),
            id: id.clone(),
            method: method.to_string(),
            params,
        };

        // Store pending request
        self.pending_requests.insert(id.clone(), PendingRequest {
            method: method.to_string(),
            sender: response_tx,
        });

        // Send message, propagate errors back to caller if it fails
        let message = match serde_json::to_string(&JsonRpcMessage::Request(request)) {
            Ok(msg) => msg,
            Err(json_err) => {
                // Remove pending request and send error back
                if let Some(pending) = self.pending_requests.remove(&id) {
                    let _ = pending.sender.send(Err(LspError::Protocol("JSON serialization failed".to_string())));
                }
                return Err(LspError::Json(json_err));
            }
        };
        
        if let Err(e) = self.transport.send_message(&message).await {
            // Remove pending request and send error back  
            if let Some(pending) = self.pending_requests.remove(&id) {
                let error_for_sender = match &e {
                    LspError::Io(_) => LspError::Protocol("Transport failed".to_string()),
                    LspError::Protocol(msg) => LspError::Protocol(msg.clone()),
                    _ => LspError::Protocol("Request failed".to_string()),
                };
                let _ = pending.sender.send(Err(error_for_sender));
            }
            return Err(e);
        }
        
        Ok(())
    }

    async fn handle_send_notification(&mut self, method: &str, params: Value) -> Result<()> {
        let notification = JsonRpcNotification {
            jsonrpc: JSONRPC_VERSION.to_string(),
            method: method.to_string(),
            params,
        };

        let message = serde_json::to_string(&JsonRpcMessage::Notification(notification))?;
        self.transport.send_message(&message).await?;
        Ok(())
    }

    fn handle_message(&mut self, message: &str) -> Result<()> {
        debug!("Received: {}", message);
        let msg: JsonRpcMessage = serde_json::from_str(message)?;
        
        match msg {
            JsonRpcMessage::Response(response) => self.handle_response(response),
            JsonRpcMessage::Notification(notification) => self.handle_notification(notification),
            JsonRpcMessage::Request(_) => {
                warn!("Server requests not supported");
                Ok(())
            }
        }
    }

    fn handle_response(&mut self, response: JsonRpcResponse) -> Result<()> {
        if let Some(pending) = self.pending_requests.remove(&response.id) {
            let result = if let Some(error) = response.error {
                Err(LspError::ServerError {
                    code: error.code,
                    message: error.message,
                    data: error.data,
                })
            } else {
                Ok(response.result.unwrap_or(Value::Null))
            };
            let _ = pending.sender.send(result);
        } else {
            let request_id = match &response.id {
                RequestId::Number(n) => n.to_string(),
                RequestId::String(s) => s.clone(),
            };
            warn!("Unknown request ID: {}", request_id);
        }
        Ok(())
    }

    fn handle_notification(&mut self, notification: JsonRpcNotification) -> Result<()> {
        debug!("Notification: {}", notification.method);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_message_framer() {
        let mut framer = MessageFramer::new();
        let content = r#"{"jsonrpc":"2.0","id":1,"method":"test"}"#;
        let framed = framer.frame_message(content);
        
        let expected = format!("Content-Length: {}\r\n\r\n{}", content.len(), content);
        assert_eq!(std::str::from_utf8(&framed).unwrap(), expected);
    }

    #[test]
    fn test_message_parsing() {
        let mut framer = MessageFramer::new();
        let content = r#"{"jsonrpc":"2.0","id":1,"method":"test"}"#;
        let raw_message = format!("Content-Length: {}\r\n\r\n{}", content.len(), content);
        
        let messages = framer.parse_messages(raw_message.as_bytes()).unwrap();
        assert_eq!(messages.len(), 1);
        assert_eq!(messages[0], content);
    }
}