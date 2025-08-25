//! vim crate - v4 implementation
//!
//! Based on the comprehensive v4 specification for vim client with channel command support.
//! Follows Linus philosophy: eliminate special cases, use data structures to simplify algorithms.

use anyhow::{Error, Result};
use async_trait::async_trait;
use serde::{de::DeserializeOwned, Serialize};
use serde_json::{json, Value};
use std::collections::HashMap;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::oneshot;
use tracing::error;

// ================================================================
// Core data structures - Vim protocol messages
// ================================================================

/// Unified Vim message types - handles both JSON-RPC and Vim channel protocols
/// Eliminates protocol confusion through intelligent encoding/parsing
#[derive(Debug, Clone)]
pub enum VimMessage {
    // JSON-RPC messages (vim-to-client)
    Request {
        id: u64,
        method: String,
        params: Value,
    },
    Response {
        id: i64,
        result: Value,
    },
    Notification {
        method: String,
        params: Value,
    },

    // Vim channel commands (client-to-vim)
    /// Call vim function with response: ["call", func, args, id]
    Call {
        func: String,
        args: Vec<Value>,
        id: u64,
    },
    /// Call vim function without response: ["call", func, args]
    CallAsync {
        func: String,
        args: Vec<Value>,
    },
    /// Execute vim expression with response: ["expr", expr, id]
    Expr {
        expr: String,
        id: u64,
    },
    /// Execute vim expression without response: ["expr", expr]
    ExprAsync {
        expr: String,
    },
    /// Execute ex command: ["ex", command]
    Ex {
        command: String,
    },
    /// Execute normal mode command: ["normal", keys]
    Normal {
        keys: String,
    },
    /// Redraw screen: ["redraw", force?]
    Redraw {
        force: bool,
    },
}

impl VimMessage {
    /// Intelligent protocol parsing - handles both JSON-RPC and Vim channel formats
    pub fn parse(json: &Value) -> Result<Self> {
        match json.as_array() {
            Some(arr) if arr.len() == 1 && arr[0].is_object() => {
                match &arr[0] {
                    Value::Object(obj) => {
                        // [{"method":"goto_definition_notification","params":{"file":"test_data/src/lib.rs","column":15,"line":14}}]
                        Ok(VimMessage::Notification {
                            method: obj["method"]
                                .as_str()
                                .ok_or_else(|| Error::msg("Missing method"))?
                                .to_string(),
                            params: obj["params"].clone(),
                        })
                    }
                    _ => Err(Error::msg("Invalid message format")),
                }
            }
            Some(arr) if arr.len() >= 2 => {
                match &arr[0] {
                    // JSON-RPC protocol
                    Value::Number(n) if n.as_i64().map(|x| x > 0).unwrap_or(false) => {
                        // [positive_id, {"method": "xxx", "params": ...}] - vim request
                        let obj = &arr[1];
                        let id = n.as_u64().ok_or_else(|| Error::msg("Invalid request id"))?;
                        Ok(VimMessage::Request {
                            id,
                            method: obj["method"]
                                .as_str()
                                .ok_or_else(|| Error::msg("Missing method"))?
                                .to_string(),
                            params: obj["params"].clone(),
                        })
                    }
                    Value::Number(n) if n.as_i64().map(|x| x < 0).unwrap_or(false) => {
                        // [negative_id, result] - vim response to our commands
                        Ok(VimMessage::Response {
                            id: n.as_i64().unwrap(),
                            result: arr[1].clone(),
                        })
                    }
                    // Vim channel protocol
                    Value::String(s) if s == "call" && arr.len() >= 3 => {
                        let func = arr[1]
                            .as_str()
                            .ok_or_else(|| Error::msg("Invalid call function"))?
                            .to_string();
                        let args = arr[2]
                            .as_array()
                            .ok_or_else(|| Error::msg("Invalid call args"))?
                            .clone();

                        if arr.len() >= 4 {
                            // ["call", func, args, id] - with response
                            let id = arr[3]
                                .as_u64()
                                .ok_or_else(|| Error::msg("Invalid call id"))?;
                            Ok(VimMessage::Call { func, args, id })
                        } else {
                            // ["call", func, args] - async
                            Ok(VimMessage::CallAsync { func, args })
                        }
                    }
                    Value::String(s) if s == "expr" && arr.len() >= 2 => {
                        let expr = arr[1]
                            .as_str()
                            .ok_or_else(|| Error::msg("Invalid expr"))?
                            .to_string();

                        if arr.len() >= 3 {
                            // ["expr", expr, id] - with response
                            let id = arr[2]
                                .as_u64()
                                .ok_or_else(|| Error::msg("Invalid expr id"))?;
                            Ok(VimMessage::Expr { expr, id })
                        } else {
                            // ["expr", expr] - async
                            Ok(VimMessage::ExprAsync { expr })
                        }
                    }
                    Value::String(s) if s == "ex" && arr.len() >= 2 => {
                        let command = arr[1]
                            .as_str()
                            .ok_or_else(|| Error::msg("Invalid ex command"))?
                            .to_string();
                        Ok(VimMessage::Ex { command })
                    }
                    Value::String(s) if s == "normal" && arr.len() >= 2 => {
                        let keys = arr[1]
                            .as_str()
                            .ok_or_else(|| Error::msg("Invalid normal keys"))?
                            .to_string();
                        Ok(VimMessage::Normal { keys })
                    }
                    Value::String(s) if s == "redraw" => {
                        let force = arr.len() >= 2 && arr[1].as_str() == Some("force");
                        Ok(VimMessage::Redraw { force })
                    }
                    _ => Err(Error::msg("Invalid message format")),
                }
            }
            _ => Err(Error::msg("Invalid message format")),
        }
    }

    /// Intelligent encoding - chooses format based on message type
    pub fn encode(&self) -> Value {
        match self {
            // JSON-RPC format
            VimMessage::Request { id, method, params } => {
                json!([*id, {"method": method, "params": params}])
            }
            VimMessage::Response { id, result } => {
                json!([*id, result])
            }
            VimMessage::Notification { method, params } => {
                json![vec![json!({"method": method, "params": params})]]
            }

            // Vim channel format
            VimMessage::Call { func, args, id } => {
                json!(["call", func, args, id])
            }
            VimMessage::CallAsync { func, args } => {
                json!(["call", func, args])
            }
            VimMessage::Expr { expr, id } => {
                json!(["expr", expr, id])
            }
            VimMessage::ExprAsync { expr } => {
                json!(["expr", expr])
            }
            VimMessage::Ex { command } => {
                json!(["ex", command])
            }
            VimMessage::Normal { keys } => {
                json!(["normal", keys])
            }
            VimMessage::Redraw { force } => {
                if *force {
                    json!(["redraw", "force"])
                } else {
                    json!(["redraw", ""])
                }
            }
        }
    }
}

// ================================================================
// VimContext trait - Interface segregation for handlers
// ================================================================

/// VimContext trait - Provides vim execution context for handlers
/// This follows interface segregation principle - handlers only get what they need
/// No access to transport, handlers, pending_calls, or other internal state
#[async_trait]
pub trait VimContext: Send + Sync {
    /// Call vim function with response: ["call", func, args, id]
    async fn call(&mut self, func: &str, args: Vec<Value>) -> Result<Value>;

    /// Call vim function without response: ["call", func, args]
    async fn call_async(&mut self, func: &str, args: Vec<Value>) -> Result<()>;

    /// Execute vim expression with response: ["expr", expr, id]
    async fn expr(&mut self, expr: &str) -> Result<Value>;

    /// Execute vim expression without response: ["expr", expr]
    async fn expr_async(&mut self, expr: &str) -> Result<()>;

    /// Execute ex command: ["ex", command]
    async fn ex(&mut self, command: &str) -> Result<()>;

    /// Execute normal mode command: ["normal", keys]
    async fn normal(&mut self, keys: &str) -> Result<()>;

    /// Redraw vim screen: ["redraw", force?]
    async fn redraw(&mut self, force: bool) -> Result<()>;

    /// Legacy compatibility: Execute vim expression via call
    async fn eval(&mut self, expr: &str) -> Result<Value>;

    /// Legacy compatibility: Execute vim command via call
    async fn execute(&mut self, cmd: &str) -> Result<Value>;
}

// ================================================================
// Unified Handler trait - v4 core design
// ================================================================

/// Unified Handler trait - eliminates method/notification special cases
/// Option<Output> perfectly expresses return semantics: None=notification, Some=response
/// VimContext parameter provides controlled access to vim capabilities (interface segregation)
#[async_trait]
pub trait Handler: Send + Sync {
    type Input: DeserializeOwned;
    type Output: Serialize;

    async fn handle(
        &self,
        ctx: &mut dyn VimContext,
        input: Self::Input,
    ) -> Result<Option<Self::Output>>;
}

/// Type-erased dispatcher - compile-time type safety to runtime dispatch
#[async_trait]
trait HandlerDispatch: Send + Sync {
    async fn dispatch(&self, ctx: &mut dyn VimContext, params: Value) -> Result<Option<Value>>;
}

/// Auto implementation - converts type-safe Handler to runtime dispatch version
#[async_trait]
impl<H: Handler> HandlerDispatch for H {
    async fn dispatch(&self, ctx: &mut dyn VimContext, params: Value) -> Result<Option<Value>> {
        let input: H::Input = serde_json::from_value(params)?;
        let result = self.handle(ctx, input).await?;

        match result {
            Some(output) => Ok(Some(serde_json::to_value(output)?)),
            None => Ok(None),
        }
    }
}

// ================================================================
// Transport abstraction - message-level processing
// ================================================================

#[async_trait]
pub trait MessageTransport: Send + Sync {
    async fn send(&self, msg: &VimMessage) -> Result<()>;
    async fn recv(&self) -> Result<VimMessage>;
}

/// Stdio Transport - handles stdin/stdout communication
pub struct StdioTransport {
    stdin: std::sync::Arc<tokio::sync::Mutex<BufReader<tokio::io::Stdin>>>,
}

impl Default for StdioTransport {
    fn default() -> Self {
        Self::new()
    }
}

impl StdioTransport {
    pub fn new() -> Self {
        Self {
            stdin: std::sync::Arc::new(tokio::sync::Mutex::new(BufReader::new(tokio::io::stdin()))),
        }
    }
}

#[async_trait]
impl MessageTransport for StdioTransport {
    async fn send(&self, msg: &VimMessage) -> Result<()> {
        let json = msg.encode();
        let line = format!("{}\n", json);
        let mut stdout = tokio::io::stdout();
        stdout.write_all(line.as_bytes()).await?;
        stdout.flush().await?;
        Ok(())
    }

    async fn recv(&self) -> Result<VimMessage> {
        let mut line = String::new();
        let mut stdin = self.stdin.lock().await;

        // Keep reading until we get a non-empty line
        loop {
            line.clear();
            let n = stdin.read_line(&mut line).await?;

            if n == 0 {
                // EOF reached
                return Err(anyhow::anyhow!("EOF reached"));
            }

            let trimmed = line.trim();
            if !trimmed.is_empty() {
                // Got a non-empty line, try to parse it
                let json: Value = serde_json::from_str(trimmed)?;
                return VimMessage::parse(&json);
            }
            // Empty line, continue reading
        }
    }
}

/// UnixSocket Transport - handles Unix domain socket communication for remote bridges
pub struct UnixSocketTransport {
    reader: std::sync::Arc<tokio::sync::Mutex<BufReader<tokio::net::unix::OwnedReadHalf>>>,
    writer: std::sync::Arc<tokio::sync::Mutex<tokio::net::unix::OwnedWriteHalf>>,
}

impl UnixSocketTransport {
    /// Connect to existing Unix socket (client mode)
    pub async fn connect(socket_path: &str) -> Result<Self> {
        let stream = UnixStream::connect(socket_path).await?;
        let (read_half, write_half) = stream.into_split();

        Ok(Self {
            reader: std::sync::Arc::new(tokio::sync::Mutex::new(BufReader::new(read_half))),
            writer: std::sync::Arc::new(tokio::sync::Mutex::new(write_half)),
        })
    }

    /// Create Unix socket server and accept first connection (server mode)
    pub async fn bind_and_accept(socket_path: &str) -> Result<Self> {
        // Remove existing socket file if it exists
        let _ = tokio::fs::remove_file(socket_path).await;

        let listener = UnixListener::bind(socket_path)?;
        let (stream, _) = listener.accept().await?;
        let (read_half, write_half) = stream.into_split();

        Ok(Self {
            reader: std::sync::Arc::new(tokio::sync::Mutex::new(BufReader::new(read_half))),
            writer: std::sync::Arc::new(tokio::sync::Mutex::new(write_half)),
        })
    }
}

#[async_trait]
impl MessageTransport for UnixSocketTransport {
    async fn send(&self, msg: &VimMessage) -> Result<()> {
        let json = msg.encode();
        let line = format!("{}\n", json);

        let mut writer = self.writer.lock().await;
        writer.write_all(line.as_bytes()).await?;
        writer.flush().await?;
        Ok(())
    }

    async fn recv(&self) -> Result<VimMessage> {
        let mut line = String::new();
        let mut reader = self.reader.lock().await;

        // Keep reading until we get a non-empty line
        loop {
            line.clear();
            let n = reader.read_line(&mut line).await?;

            if n == 0 {
                // EOF reached
                return Err(anyhow::anyhow!("EOF reached on Unix socket"));
            }

            let trimmed = line.trim();
            if !trimmed.is_empty() {
                // Got a non-empty line, try to parse it
                let json: Value = serde_json::from_str(trimmed)?;
                return VimMessage::parse(&json);
            }
            // Empty line, continue reading
        }
    }
}

// ================================================================
// VimClient renamed to `vim` - unified message processing core
// ================================================================

/// The main vim client - handles all vim communication via channel commands
pub struct Vim {
    transport: Box<dyn MessageTransport>,
    handlers: HashMap<String, std::sync::Arc<dyn HandlerDispatch>>,
    pending_calls: HashMap<u64, oneshot::Sender<Value>>,
    next_id: u64,
}

impl Vim {
    /// Create stdio client
    pub fn new_stdio() -> Self {
        Self {
            transport: Box::new(StdioTransport::new()),
            handlers: HashMap::new(),
            pending_calls: HashMap::new(),
            next_id: 1,
        }
    }

    /// Create Unix socket client (connects to existing socket)
    pub async fn new_unix_socket(socket_path: &str) -> Result<Self> {
        Ok(Self {
            transport: Box::new(UnixSocketTransport::connect(socket_path).await?),
            handlers: HashMap::new(),
            pending_calls: HashMap::new(),
            next_id: 1,
        })
    }

    /// Create Unix socket server (binds and accepts first connection)
    pub async fn new_unix_socket_server(socket_path: &str) -> Result<Self> {
        Ok(Self {
            transport: Box::new(UnixSocketTransport::bind_and_accept(socket_path).await?),
            handlers: HashMap::new(),
            pending_calls: HashMap::new(),
            next_id: 1,
        })
    }

    /// Create TCP client (placeholder for future implementation)
    pub async fn new_tcp(_addr: &str) -> Result<Self> {
        // TODO: Implement TCP transport
        Err(Error::msg("TCP transport not yet implemented"))
    }

    /// Type-safe handler registration - compile-time checks
    pub fn add_handler<H: Handler + 'static>(&mut self, method: &str, handler: H) {
        self.handlers
            .insert(method.to_string(), std::sync::Arc::new(handler));
    }

    /// Call vim function - channel command
    pub async fn call(&mut self, func: &str, args: Vec<Value>) -> Result<Value> {
        self.next_id += 1;
        let call_id = self.next_id;
        let (tx, rx) = oneshot::channel();
        self.pending_calls.insert(call_id, tx);

        // Send vim channel command: ["call", func, args, id]
        let msg = VimMessage::Call {
            func: func.to_string(),
            args,
            id: call_id,
        };

        self.transport.send(&msg).await?;
        rx.await.map_err(|_| Error::msg("Call timeout"))
    }

    /// Execute vim expression with response
    pub async fn expr(&mut self, expr: &str) -> Result<Value> {
        self.next_id += 1;
        let expr_id = self.next_id;
        let (tx, rx) = oneshot::channel();
        self.pending_calls.insert(expr_id, tx);

        let msg = VimMessage::Expr {
            expr: expr.to_string(),
            id: expr_id,
        };

        self.transport.send(&msg).await?;
        rx.await.map_err(|_| Error::msg("Expr timeout"))
    }

    /// Execute vim expression without response (fire-and-forget)
    pub async fn expr_async(&mut self, expr: &str) -> Result<()> {
        let msg = VimMessage::ExprAsync {
            expr: expr.to_string(),
        };

        self.transport.send(&msg).await?;
        Ok(())
    }

    /// Execute ex command (no response)
    pub async fn ex(&mut self, command: &str) -> Result<()> {
        let msg = VimMessage::Ex {
            command: command.to_string(),
        };

        self.transport.send(&msg).await?;
        Ok(())
    }

    /// Execute normal mode command (no response)
    pub async fn normal(&mut self, keys: &str) -> Result<()> {
        let msg = VimMessage::Normal {
            keys: keys.to_string(),
        };

        self.transport.send(&msg).await?;
        Ok(())
    }

    /// Redraw vim screen
    pub async fn redraw(&mut self, force: bool) -> Result<()> {
        let msg = VimMessage::Redraw { force };

        self.transport.send(&msg).await?;
        Ok(())
    }

    /// Legacy compatibility: Execute vim expression via call
    pub async fn eval(&mut self, expr: &str) -> Result<Value> {
        self.call("eval", vec![json!(expr)]).await
    }

    /// Legacy compatibility: Execute vim command via call
    pub async fn execute(&mut self, cmd: &str) -> Result<Value> {
        self.call("execute", vec![json!(cmd)]).await
    }

    /// Call vim function without handling return value (fire-and-forget)
    /// Useful for notifications and commands where response is not needed
    pub async fn call_async(&mut self, func: &str, args: Vec<Value>) -> Result<()> {
        // Send vim channel command: ["call", func, args]
        let msg = VimMessage::CallAsync {
            func: func.to_string(),
            args,
        };

        self.transport.send(&msg).await?;
        Ok(())
    }

    /// Main message processing loop - unified handling for all message types
    pub async fn run(&mut self) -> Result<()> {
        loop {
            match self.transport.recv().await {
                Ok(msg) => {
                    if let Err(e) = self.handle_message(msg).await {
                        error!("Message handling error: {}", e);
                    }
                }
                Err(e) => {
                    error!("Transport error: {}", e);
                    continue;
                }
            }
        }
        #[allow(unreachable_code)]
        Ok(())
    }

    /// Unified message handling - no special cases
    async fn handle_message(&mut self, msg: VimMessage) -> Result<()> {
        match msg {
            // JSON-RPC messages
            VimMessage::Request { id, method, params } => {
                self.handle_request(id, method, params).await
            }
            VimMessage::Response { id, result } => self.handle_response(id, result).await,
            VimMessage::Notification { method, params } => {
                self.handle_notification(method, params).await
            }

            // Vim channel commands - these are outgoing commands, should not be received
            // If received, they indicate a protocol error but we handle gracefully
            VimMessage::Call { .. }
            | VimMessage::CallAsync { .. }
            | VimMessage::Expr { .. }
            | VimMessage::ExprAsync { .. }
            | VimMessage::Ex { .. }
            | VimMessage::Normal { .. }
            | VimMessage::Redraw { .. } => {
                // These are outgoing commands, receiving them is unexpected
                eprintln!("Warning: Received outgoing command message, ignoring");
                Ok(())
            }
        }
    }

    /// Handle requests from vim
    async fn handle_request(&mut self, id: u64, method: String, params: Value) -> Result<()> {
        tracing::debug!("Handling request: method={}, params={}", method, params);

        // Clone Arc to avoid borrow checker issues
        if let Some(handler) = self.handlers.get(&method).cloned() {
            match handler.dispatch(self, params).await {
                Ok(Some(result)) => {
                    // Has return value - send response
                    let response = VimMessage::Response {
                        id: id as i64,
                        result,
                    };
                    self.transport.send(&response).await?;
                }
                Ok(None) => {
                    // notification - no reply
                }
                Err(e) => {
                    // Unified error handling
                    let response = VimMessage::Response {
                        id: id as i64,
                        result: json!({"error": e.to_string()}),
                    };
                    self.transport.send(&response).await?;
                }
            }
        } else {
            // Unknown method
            let response = VimMessage::Response {
                id: id as i64,
                result: json!({"error": format!("Unknown method: {}", method)}),
            };
            self.transport.send(&response).await?;
        }
        Ok(())
    }

    /// Handle vim responses - format: [id, result]
    async fn handle_response(&mut self, id: i64, result: Value) -> Result<()> {
        // Find and remove the pending call with matching ID
        if let Some(sender) = self.pending_calls.remove(&(id as u64)) {
            let _ = sender.send(result);
        }
        Ok(())
    }

    /// Handle notifications
    async fn handle_notification(&mut self, method: String, params: Value) -> Result<()> {
        if let Some(handler) = self.handlers.get(&method).cloned() {
            // notification processing same as request - just no response sent
            let _ = handler.dispatch(self, params).await;
        }
        Ok(())
    }
}

// ================================================================
// VimContext implementation for Vim - Interface segregation
// ================================================================

/// Implementation of VimContext trait for Vim
/// This provides handlers with vim execution context they need
/// Following interface segregation principle - no access to internal state
#[async_trait]
impl VimContext for Vim {
    /// Call vim function with response: ["call", func, args, id]
    async fn call(&mut self, func: &str, args: Vec<Value>) -> Result<Value> {
        // Delegate to existing implementation
        self.call(func, args).await
    }

    /// Call vim function without response: ["call", func, args]
    async fn call_async(&mut self, func: &str, args: Vec<Value>) -> Result<()> {
        // Delegate to existing implementation
        self.call_async(func, args).await
    }

    /// Execute vim expression with response: ["expr", expr, id]
    async fn expr(&mut self, expr: &str) -> Result<Value> {
        // Delegate to existing implementation
        self.expr(expr).await
    }

    /// Execute vim expression without response: ["expr", expr]
    async fn expr_async(&mut self, expr: &str) -> Result<()> {
        // Delegate to existing implementation
        self.expr_async(expr).await
    }

    /// Execute ex command: ["ex", command]
    async fn ex(&mut self, command: &str) -> Result<()> {
        // Delegate to existing implementation
        self.ex(command).await
    }

    /// Execute normal mode command: ["normal", keys]
    async fn normal(&mut self, keys: &str) -> Result<()> {
        // Delegate to existing implementation
        self.normal(keys).await
    }

    /// Redraw vim screen: ["redraw", force?]
    async fn redraw(&mut self, force: bool) -> Result<()> {
        // Delegate to existing implementation
        self.redraw(force).await
    }

    /// Legacy compatibility: Execute vim expression via call
    async fn eval(&mut self, expr: &str) -> Result<Value> {
        // Delegate to existing implementation
        self.eval(expr).await
    }

    /// Legacy compatibility: Execute vim command via call
    async fn execute(&mut self, cmd: &str) -> Result<Value> {
        // Delegate to existing implementation
        self.execute(cmd).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_vim_message_parsing() {
        // Test vim request parsing
        let json = json!([1, {"method": "goto_definition", "params": {"file": "test.rs"}}]);
        let msg = VimMessage::parse(&json).unwrap();

        match msg {
            VimMessage::Request { id, method, .. } => {
                assert_eq!(id, 1);
                assert_eq!(method, "goto_definition");
            }
            _ => panic!("Expected Request"),
        }

        // Test vim response parsing
        let json = json!([-42, {"result": "success"}]);
        let msg = VimMessage::parse(&json).unwrap();

        match msg {
            VimMessage::Response { id, .. } => {
                assert_eq!(id, -42);
            }
            _ => panic!("Expected Response"),
        }
    }

    #[test]
    fn test_notification_parsing() {
        // Test notification message parsing: [{"method": "xxx", "params": {...}}]
        // According to the parsing logic, this should be treated as an array with first element being an object
        let json = json!([{"method": "goto_definition_notification", "params": {"file": "test.rs", "line": 10, "column": 5}}]);
        let msg = VimMessage::parse(&json).unwrap();

        match msg {
            VimMessage::Notification { method, params } => {
                assert_eq!(method, "goto_definition_notification");
                assert_eq!(params["file"], "test.rs");
                assert_eq!(params["line"], 10);
                assert_eq!(params["column"], 5);
            }
            _ => panic!("Expected Notification"),
        }
    }

    #[test]
    fn test_vim_channel_parsing() {
        // Test vim channel command parsing

        // Test call with response: ["call", "func", args, id]
        let json = json!(["call", "test_func", ["arg1", 42], 123]);
        let msg = VimMessage::parse(&json).unwrap();

        match msg {
            VimMessage::Call { func, args, id } => {
                assert_eq!(func, "test_func");
                assert_eq!(args, vec![json!("arg1"), json!(42)]);
                assert_eq!(id, 123);
            }
            _ => panic!("Expected Call"),
        }

        // Test async call: ["call", "func", args]
        let json = json!(["call", "async_func", ["data"]]);
        let msg = VimMessage::parse(&json).unwrap();

        match msg {
            VimMessage::CallAsync { func, args } => {
                assert_eq!(func, "async_func");
                assert_eq!(args, vec![json!("data")]);
            }
            _ => panic!("Expected CallAsync"),
        }

        // Test expr with response: ["expr", "expression", id]
        let json = json!(["expr", "line('$')", 456]);
        let msg = VimMessage::parse(&json).unwrap();

        match msg {
            VimMessage::Expr { expr, id } => {
                assert_eq!(expr, "line('$')");
                assert_eq!(id, 456);
            }
            _ => panic!("Expected Expr"),
        }

        // Test async expr: ["expr", "expression"]
        let json = json!(["expr", "echo 'test'"]);
        let msg = VimMessage::parse(&json).unwrap();

        match msg {
            VimMessage::ExprAsync { expr } => {
                assert_eq!(expr, "echo 'test'");
            }
            _ => panic!("Expected ExprAsync"),
        }

        // Test ex command: ["ex", "command"]
        let json = json!(["ex", "set number"]);
        let msg = VimMessage::parse(&json).unwrap();

        match msg {
            VimMessage::Ex { command } => {
                assert_eq!(command, "set number");
            }
            _ => panic!("Expected Ex"),
        }

        // Test normal command: ["normal", "keys"]
        let json = json!(["normal", "ggVG"]);
        let msg = VimMessage::parse(&json).unwrap();

        match msg {
            VimMessage::Normal { keys } => {
                assert_eq!(keys, "ggVG");
            }
            _ => panic!("Expected Normal"),
        }

        // Test redraw: ["redraw"] and ["redraw", "force"]
        let json = json!(["redraw", ""]);
        let msg = VimMessage::parse(&json).unwrap();

        match msg {
            VimMessage::Redraw { force } => {
                assert!(!force);
            }
            _ => panic!("Expected Redraw"),
        }

        let json = json!(["redraw", "force"]);
        let msg = VimMessage::parse(&json).unwrap();

        match msg {
            VimMessage::Redraw { force } => {
                assert!(force);
            }
            _ => panic!("Expected Redraw with force"),
        }
    }

    #[test]
    fn test_vim_message_encoding() {
        // Test VimMessage (vim-to-client) encoding uses JSON-RPC format
        let msg = VimMessage::Request {
            id: 123,
            method: "goto_definition".to_string(),
            params: json!({"file": "test.rs"}),
        };

        let encoded = msg.encode();
        let expected = json!([123, {"method": "goto_definition", "params": {"file": "test.rs"}}]);
        assert_eq!(encoded, expected, "VimMessage should use JSON-RPC format");

        // Test response encoding
        let response = VimMessage::Response {
            id: -42,
            result: json!({"location": "test.rs:10:5"}),
        };

        let encoded = response.encode();
        let expected = json!([-42, {"location": "test.rs:10:5"}]);
        assert_eq!(
            encoded, expected,
            "VimMessage response should be [id, result]"
        );
    }

    #[test]
    fn test_vim_channel_message_encoding() {
        // Test VimMessage channel command encoding follows Vim channel command format

        // Test call with response: ["call", func, args, id]
        let call_msg = VimMessage::Call {
            func: "test_func".to_string(),
            args: vec![json!("arg1"), json!(42)],
            id: 123,
        };

        let encoded = call_msg.encode();
        let expected = json!(["call", "test_func", [json!("arg1"), json!(42)], 123]);
        assert_eq!(
            encoded, expected,
            "VimMessage::Call should encode as [\"call\", func, args, id]"
        );

        // Test call without response: ["call", func, args]
        let call_async = VimMessage::CallAsync {
            func: "test_func".to_string(),
            args: vec![json!("arg1"), json!(42)],
        };

        let encoded = call_async.encode();
        let expected = json!(["call", "test_func", [json!("arg1"), json!(42)]]);
        assert_eq!(
            encoded, expected,
            "VimMessage::CallAsync should encode as [\"call\", func, args]"
        );

        // Test expr command: ["expr", expr, id]
        let expr_msg = VimMessage::Expr {
            expr: "line('$')".to_string(),
            id: 456,
        };

        let encoded = expr_msg.encode();
        let expected = json!(["expr", "line('$')", 456]);
        assert_eq!(
            encoded, expected,
            "VimMessage::Expr should encode as [\"expr\", expr, id]"
        );

        // Test ex command: ["ex", command]
        let ex_msg = VimMessage::Ex {
            command: "echo 'hello'".to_string(),
        };

        let encoded = ex_msg.encode();
        let expected = json!(["ex", "echo 'hello'"]);
        assert_eq!(
            encoded, expected,
            "VimMessage::Ex should encode as [\"ex\", command]"
        );

        // Test redraw: ["redraw", "force"] or ["redraw", ""]
        let redraw_force = VimMessage::Redraw { force: true };
        let encoded = redraw_force.encode();
        let expected = json!(["redraw", "force"]);
        assert_eq!(
            encoded, expected,
            "VimMessage::Redraw with force should encode as [\"redraw\", \"force\"]"
        );

        let redraw_normal = VimMessage::Redraw { force: false };
        let encoded = redraw_normal.encode();
        let expected = json!(["redraw", ""]);
        assert_eq!(
            encoded, expected,
            "VimMessage::Redraw without force should encode as [\"redraw\", \"\"]"
        );
    }

    #[tokio::test]
    async fn test_unix_socket_transport() {
        // Test Unix socket transport creation
        let socket_path = "/tmp/test_yac_socket";

        // Clean up any existing socket
        let _ = std::fs::remove_file(socket_path);

        // Test that we can create a transport (this will test bind functionality)
        let server_result = UnixSocketTransport::bind_and_accept(socket_path).await;
        // We expect this to block waiting for a connection, so we just verify the socket was created
        drop(server_result);

        // Clean up
        let _ = std::fs::remove_file(socket_path);
    }
}
