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
    /// Protocol parsing - uses data structures to eliminate special cases
    /// Linus-style "good taste": let data structure do the work
    pub fn parse(json: &Value) -> Result<Self> {
        let arr = json
            .as_array()
            .ok_or_else(|| Error::msg("Invalid message format"))?;

        // Single object array: notification
        if arr.len() == 1 && arr[0].is_object() {
            return Self::parse_notification(&arr[0]);
        }

        // Multi-element array: check first element type
        if arr.len() >= 2 {
            return Self::parse_multi_element(arr);
        }

        Err(Error::msg("Invalid message format"))
    }

    /// Parse notification: [{"method":"xxx","params":{...}}]
    fn parse_notification(obj: &Value) -> Result<Self> {
        let obj = obj
            .as_object()
            .ok_or_else(|| Error::msg("Invalid notification format"))?;
        Ok(VimMessage::Notification {
            method: obj["method"]
                .as_str()
                .ok_or_else(|| Error::msg("Missing method"))?
                .to_string(),
            params: obj["params"].clone(),
        })
    }

    /// Parse multi-element arrays - number or string first element
    fn parse_multi_element(arr: &[Value]) -> Result<Self> {
        match &arr[0] {
            Value::Number(n) => Self::parse_numeric_message(n, arr),
            Value::String(s) => Self::parse_string_command(s, arr),
            _ => Err(Error::msg("Invalid message format")),
        }
    }

    /// Parse numeric messages: JSON-RPC requests and responses
    fn parse_numeric_message(n: &serde_json::Number, arr: &[Value]) -> Result<Self> {
        let id = n.as_i64().ok_or_else(|| Error::msg("Invalid numeric id"))?;

        if id > 0 {
            // Positive: request [id, {"method":"xxx","params":{...}}]
            let id = n.as_u64().ok_or_else(|| Error::msg("Invalid request id"))?;
            let obj = &arr[1];
            Ok(VimMessage::Request {
                id,
                method: obj["method"]
                    .as_str()
                    .ok_or_else(|| Error::msg("Missing method"))?
                    .to_string(),
                params: obj["params"].clone(),
            })
        } else {
            // Negative: response [id, result]
            Ok(VimMessage::Response {
                id,
                result: arr[1].clone(),
            })
        }
    }

    /// Parse string commands: vim channel protocol
    fn parse_string_command(cmd: &str, arr: &[Value]) -> Result<Self> {
        match cmd {
            "call" if arr.len() >= 3 => {
                let func = arr[1]
                    .as_str()
                    .ok_or_else(|| Error::msg("Invalid call function"))?
                    .to_string();
                let args = arr[2]
                    .as_array()
                    .ok_or_else(|| Error::msg("Invalid call args"))?
                    .clone();

                if arr.len() >= 4 {
                    let id = arr[3]
                        .as_u64()
                        .ok_or_else(|| Error::msg("Invalid call id"))?;
                    Ok(VimMessage::Call { func, args, id })
                } else {
                    Ok(VimMessage::CallAsync { func, args })
                }
            }
            "expr" if arr.len() >= 2 => {
                let expr = arr[1]
                    .as_str()
                    .ok_or_else(|| Error::msg("Invalid expr"))?
                    .to_string();

                if arr.len() >= 3 {
                    let id = arr[2]
                        .as_u64()
                        .ok_or_else(|| Error::msg("Invalid expr id"))?;
                    Ok(VimMessage::Expr { expr, id })
                } else {
                    Ok(VimMessage::ExprAsync { expr })
                }
            }
            "ex" if arr.len() >= 2 => {
                let command = arr[1]
                    .as_str()
                    .ok_or_else(|| Error::msg("Invalid ex command"))?
                    .to_string();
                Ok(VimMessage::Ex { command })
            }
            "normal" if arr.len() >= 2 => {
                let keys = arr[1]
                    .as_str()
                    .ok_or_else(|| Error::msg("Invalid normal keys"))?
                    .to_string();
                Ok(VimMessage::Normal { keys })
            }
            "redraw" => {
                let force = arr.len() >= 2 && arr[1].as_str() == Some("force");
                Ok(VimMessage::Redraw { force })
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

/// Unified Handler trait - clear semantics, no special cases
///
/// Return value semantics (Linus-style "good taste"):
/// - Some(output): Request that needs response - will send JSON-RPC response
/// - None: Notification/fire-and-forget - no response sent back to vim
///
/// This eliminates the request/notification handler distinction through data presence
/// VimContext parameter provides controlled access to vim capabilities (interface segregation)
#[async_trait]
pub trait Handler: Send + Sync {
    type Input: DeserializeOwned;
    type Output: Serialize;

    /// Handle a vim message
    ///
    /// Returns:
    /// - Some(result): Sends JSON-RPC response back to vim
    /// - None: No response sent (fire-and-forget notification)
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

    /// Message handling - data-driven dispatch eliminates special cases
    async fn handle_message(&mut self, msg: VimMessage) -> Result<()> {
        use VimMessage::*;
        match msg {
            Request { id, method, params } => {
                self.handle_method_call(Some(id), method, params).await
            }
            Response { id, result } => self.handle_response(id, result).await,
            Notification { method, params } => self.handle_method_call(None, method, params).await,

            // Outgoing commands - protocol errors, handle gracefully
            Call { .. }
            | CallAsync { .. }
            | Expr { .. }
            | ExprAsync { .. }
            | Ex { .. }
            | Normal { .. }
            | Redraw { .. } => {
                tracing::warn!("Received outgoing command message, ignoring");
                Ok(())
            }
        }
    }

    /// Unified method call handler - handles both requests and notifications
    /// Option<id> eliminates request/notification special cases through data presence
    async fn handle_method_call(
        &mut self,
        response_id: Option<u64>,
        method: String,
        params: Value,
    ) -> Result<()> {
        tracing::debug!("Handling method call: method={}, params={}", method, params);

        // Get handler - same logic for both requests and notifications
        if let Some(handler) = self.handlers.get(&method).cloned() {
            match handler.dispatch(self, params).await {
                Ok(Some(result)) => {
                    // Has result - send response if needed
                    if let Some(id) = response_id {
                        let response = VimMessage::Response {
                            id: id as i64,
                            result,
                        };
                        self.transport.send(&response).await?;
                    }
                }
                Ok(None) => {
                    // No result - notification or fire-and-forget
                }
                Err(e) => {
                    // Error - send error response if needed, otherwise log
                    if let Some(id) = response_id {
                        let response = VimMessage::Response {
                            id: id as i64,
                            result: json!({"error": e.to_string()}),
                        };
                        self.transport.send(&response).await?;
                    } else {
                        tracing::error!("Notification handler error: {}", e);
                    }
                }
            }
        } else if let Some(id) = response_id {
            // Unknown method AND needs response
            let response = VimMessage::Response {
                id: id as i64,
                result: json!({"error": format!("Unknown method: {}", method)}),
            };
            self.transport.send(&response).await?;
        }
        // Unknown method + notification = ignore silently
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
        self.next_id += 1;
        let call_id = self.next_id;
        let (tx, rx) = oneshot::channel();
        self.pending_calls.insert(call_id, tx);

        let msg = VimMessage::Call {
            func: func.to_string(),
            args,
            id: call_id,
        };

        self.transport.send(&msg).await?;
        rx.await.map_err(|_| Error::msg("Call timeout"))
    }

    /// Call vim function without response: ["call", func, args]
    async fn call_async(&mut self, func: &str, args: Vec<Value>) -> Result<()> {
        let msg = VimMessage::CallAsync {
            func: func.to_string(),
            args,
        };

        self.transport.send(&msg).await?;
        Ok(())
    }

    /// Execute vim expression with response: ["expr", expr, id]
    async fn expr(&mut self, expr: &str) -> Result<Value> {
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

    /// Execute vim expression without response: ["expr", expr]
    async fn expr_async(&mut self, expr: &str) -> Result<()> {
        let msg = VimMessage::ExprAsync {
            expr: expr.to_string(),
        };

        self.transport.send(&msg).await?;
        Ok(())
    }

    /// Execute ex command: ["ex", command]
    async fn ex(&mut self, command: &str) -> Result<()> {
        let msg = VimMessage::Ex {
            command: command.to_string(),
        };

        self.transport.send(&msg).await?;
        Ok(())
    }

    /// Execute normal mode command: ["normal", keys]
    async fn normal(&mut self, keys: &str) -> Result<()> {
        let msg = VimMessage::Normal {
            keys: keys.to_string(),
        };

        self.transport.send(&msg).await?;
        Ok(())
    }

    /// Redraw vim screen: ["redraw", force?]
    async fn redraw(&mut self, force: bool) -> Result<()> {
        let msg = VimMessage::Redraw { force };

        self.transport.send(&msg).await?;
        Ok(())
    }

    /// Legacy compatibility: Execute vim expression via call
    async fn eval(&mut self, expr: &str) -> Result<Value> {
        self.call("eval", vec![json!(expr)]).await
    }

    /// Legacy compatibility: Execute vim command via call
    async fn execute(&mut self, cmd: &str) -> Result<Value> {
        self.call("execute", vec![json!(cmd)]).await
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
}
