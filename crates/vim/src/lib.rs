//! vim crate - v4 refactored implementation
//!
//! Clean architecture with separated concerns:
//! - Protocol parsing (JSON-RPC vs Vim channel)
//! - Command sending (ChannelCommandSender)  
//! - Message receiving (MessageReceiver)
//! - Transport abstraction (stdio, mock, etc.)
//!
//! Follows Linus philosophy: eliminate special cases, use data structures to simplify algorithms.

use anyhow::Result;
use async_trait::async_trait;
use serde_json::Value;
use std::sync::Arc;

// New modular architecture
pub mod protocol;
pub mod receiver;
pub mod sender;
pub mod transport;

// Re-export key types for backward compatibility
pub use protocol::{ChannelCommand, JsonRpcMessage, VimProtocol};
pub use receiver::{Handler, MessageReceiver};
pub use sender::ChannelCommandSender;
pub use transport::{MessageTransport, StdioTransport};

// ================================================================
// New VimClient - composition of sender + receiver
// ================================================================

/// The main vim client - composed of sender and receiver components
/// This replaces the old monolithic Vim struct with a cleaner design
pub struct VimClient {
    sender: ChannelCommandSender,
    receiver: MessageReceiver,
}

impl VimClient {
    /// Create stdio client
    pub fn new_stdio() -> Self {
        let transport = Arc::new(StdioTransport::new());
        let sender = ChannelCommandSender::new(transport.clone());
        let receiver = MessageReceiver::new(transport);

        Self { sender, receiver }
    }

    /// Create client with custom transport
    pub fn new(transport: Arc<dyn MessageTransport>) -> Self {
        let sender = ChannelCommandSender::new(transport.clone());
        let receiver = MessageReceiver::new(transport);

        Self { sender, receiver }
    }

    /// Get reference to command sender
    pub fn sender(&self) -> &ChannelCommandSender {
        &self.sender
    }

    /// Get mutable reference to receiver for adding handlers
    pub fn receiver_mut(&mut self) -> &mut MessageReceiver {
        &mut self.receiver
    }

    /// Type-safe handler registration
    pub fn add_handler<H: Handler + 'static>(&mut self, method: &str, handler: H) {
        self.receiver.add_handler(method, handler);
    }

    /// Main message processing loop
    pub async fn run(&mut self) -> Result<()> {
        self.receiver.run(&self.sender).await
    }

    // ================================================================
    // Backward compatibility methods - delegate to sender
    // ================================================================

    /// Call vim function with response: ["call", func, args, id]
    pub async fn call(&self, func: &str, args: Vec<Value>) -> Result<Value> {
        self.sender.call(func, args).await
    }

    /// Call vim function without response: ["call", func, args]
    pub async fn call_async(&self, func: &str, args: Vec<Value>) -> Result<()> {
        self.sender.call_async(func, args).await
    }

    /// Execute vim expression with response: ["expr", expr, id]
    pub async fn expr(&self, expr: &str) -> Result<Value> {
        self.sender.expr(expr).await
    }

    /// Execute vim expression without response: ["expr", expr]
    pub async fn expr_async(&self, expr: &str) -> Result<()> {
        self.sender.expr_async(expr).await
    }

    /// Execute ex command: ["ex", command]
    pub async fn ex(&self, command: &str) -> Result<()> {
        self.sender.ex(command).await
    }

    /// Execute normal mode command: ["normal", keys]
    pub async fn normal(&self, keys: &str) -> Result<()> {
        self.sender.normal(keys).await
    }

    /// Redraw vim screen: ["redraw", force?]
    pub async fn redraw(&self, force: bool) -> Result<()> {
        self.sender.redraw(force).await
    }

    /// Legacy compatibility: Execute vim expression via call
    pub async fn eval(&self, expr: &str) -> Result<Value> {
        self.sender.eval(expr).await
    }

    /// Legacy compatibility: Execute vim command via call
    pub async fn execute(&self, cmd: &str) -> Result<Value> {
        self.sender.execute(cmd).await
    }
}

// ================================================================
// Legacy compatibility - old Vim type alias
// ================================================================

/// Legacy type alias for backward compatibility
/// Use VimClient for new code
pub type Vim = VimClient;

// ================================================================
// VimContext trait - Interface segregation for handlers
// ================================================================

/// VimContext trait - Provides vim execution context for handlers
/// This is kept for backward compatibility with existing handlers
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

/// Implementation of VimContext for ChannelCommandSender
/// This bridges old VimContext-based handlers to new architecture
#[async_trait]
impl VimContext for ChannelCommandSender {
    async fn call(&mut self, func: &str, args: Vec<Value>) -> Result<Value> {
        ChannelCommandSender::call(self, func, args).await
    }

    async fn call_async(&mut self, func: &str, args: Vec<Value>) -> Result<()> {
        ChannelCommandSender::call_async(self, func, args).await
    }

    async fn expr(&mut self, expr: &str) -> Result<Value> {
        ChannelCommandSender::expr(self, expr).await
    }

    async fn expr_async(&mut self, expr: &str) -> Result<()> {
        ChannelCommandSender::expr_async(self, expr).await
    }

    async fn ex(&mut self, command: &str) -> Result<()> {
        ChannelCommandSender::ex(self, command).await
    }

    async fn normal(&mut self, keys: &str) -> Result<()> {
        ChannelCommandSender::normal(self, keys).await
    }

    async fn redraw(&mut self, force: bool) -> Result<()> {
        ChannelCommandSender::redraw(self, force).await
    }

    async fn eval(&mut self, expr: &str) -> Result<Value> {
        ChannelCommandSender::eval(self, expr).await
    }

    async fn execute(&mut self, cmd: &str) -> Result<Value> {
        ChannelCommandSender::execute(self, cmd).await
    }
}

// ================================================================
// Legacy VimMessage - backward compatibility
// ================================================================

/// Legacy VimMessage enum - kept for backward compatibility
/// Use the new protocol types (JsonRpcMessage, ChannelCommand) for new code
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
    Call {
        func: String,
        args: Vec<Value>,
        id: i64,
    },
    CallAsync {
        func: String,
        args: Vec<Value>,
    },
    Expr {
        expr: String,
        id: i64,
    },
    ExprAsync {
        expr: String,
    },
    Ex {
        command: String,
    },
    Normal {
        keys: String,
    },
    Redraw {
        force: bool,
    },
}

impl VimMessage {
    /// Legacy parse method - delegates to new protocol parser
    pub fn parse(json: &Value) -> Result<Self> {
        use protocol::MessageParser;

        let parser = MessageParser::new();
        let protocol_msg = parser.parse(json)?;

        Ok(Self::from_protocol(protocol_msg))
    }

    /// Legacy encode method - converts to new protocol and encodes
    pub fn encode(&self) -> Value {
        let protocol_msg = self.to_protocol();
        protocol_msg.encode()
    }

    /// Convert from new protocol to legacy VimMessage
    fn from_protocol(msg: VimProtocol) -> Self {
        match msg {
            VimProtocol::JsonRpc(rpc_msg) => match rpc_msg {
                JsonRpcMessage::Request { id, method, params } => {
                    VimMessage::Request { id, method, params }
                }
                JsonRpcMessage::Response { id, result } => VimMessage::Response { id, result },
                JsonRpcMessage::Notification { method, params } => {
                    VimMessage::Notification { method, params }
                }
            },
            VimProtocol::Channel(cmd) => match cmd {
                ChannelCommand::Call { func, args, id } => VimMessage::Call { func, args, id },
                ChannelCommand::CallAsync { func, args } => VimMessage::CallAsync { func, args },
                ChannelCommand::Expr { expr, id } => VimMessage::Expr { expr, id },
                ChannelCommand::ExprAsync { expr } => VimMessage::ExprAsync { expr },
                ChannelCommand::Ex { command } => VimMessage::Ex { command },
                ChannelCommand::Normal { keys } => VimMessage::Normal { keys },
                ChannelCommand::Redraw { force } => VimMessage::Redraw { force },
            },
        }
    }

    /// Convert from legacy VimMessage to new protocol
    fn to_protocol(&self) -> VimProtocol {
        match self {
            VimMessage::Request { id, method, params } => {
                VimProtocol::JsonRpc(JsonRpcMessage::Request {
                    id: *id,
                    method: method.clone(),
                    params: params.clone(),
                })
            }
            VimMessage::Response { id, result } => VimProtocol::JsonRpc(JsonRpcMessage::Response {
                id: *id,
                result: result.clone(),
            }),
            VimMessage::Notification { method, params } => {
                VimProtocol::JsonRpc(JsonRpcMessage::Notification {
                    method: method.clone(),
                    params: params.clone(),
                })
            }
            VimMessage::Call { func, args, id } => VimProtocol::Channel(ChannelCommand::Call {
                func: func.clone(),
                args: args.clone(),
                id: *id,
            }),
            VimMessage::CallAsync { func, args } => {
                VimProtocol::Channel(ChannelCommand::CallAsync {
                    func: func.clone(),
                    args: args.clone(),
                })
            }
            VimMessage::Expr { expr, id } => VimProtocol::Channel(ChannelCommand::Expr {
                expr: expr.clone(),
                id: *id,
            }),
            VimMessage::ExprAsync { expr } => {
                VimProtocol::Channel(ChannelCommand::ExprAsync { expr: expr.clone() })
            }
            VimMessage::Ex { command } => VimProtocol::Channel(ChannelCommand::Ex {
                command: command.clone(),
            }),
            VimMessage::Normal { keys } => {
                VimProtocol::Channel(ChannelCommand::Normal { keys: keys.clone() })
            }
            VimMessage::Redraw { force } => {
                VimProtocol::Channel(ChannelCommand::Redraw { force: *force })
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn test_legacy_vim_message_parsing() {
        // Test that old VimMessage::parse still works
        let json = json!([1, {"method": "goto_definition", "params": {"file": "test.rs"}}]);
        let msg = VimMessage::parse(&json).unwrap();

        match msg {
            VimMessage::Request { id, method, .. } => {
                assert_eq!(id, 1);
                assert_eq!(method, "goto_definition");
            }
            _ => panic!("Expected Request"),
        }

        // Test channel command parsing
        let json = json!(["call", "test_func", ["arg1", 42], -123]);
        let msg = VimMessage::parse(&json).unwrap();

        match msg {
            VimMessage::Call { func, args, id } => {
                assert_eq!(func, "test_func");
                assert_eq!(args, vec![json!("arg1"), json!(42)]);
                assert_eq!(id, -123);
            }
            _ => panic!("Expected Call"),
        }
    }

    #[test]
    fn test_legacy_vim_message_encoding() {
        let msg = VimMessage::Call {
            func: "test_func".to_string(),
            args: vec![json!("arg1"), json!(42)],
            id: -123,
        };

        let encoded = msg.encode();
        let expected = json!(["call", "test_func", [json!("arg1"), json!(42)], -123]);
        assert_eq!(encoded, expected);
    }

    #[tokio::test]
    async fn test_vim_client_backward_compatibility() {
        use transport::MockTransport;

        let transport = Arc::new(MockTransport::new());
        let client = VimClient::new(transport.clone());

        // Test that old API methods still work
        let _result = client.call_async("test_func", vec![json!("arg")]).await;

        let sent_messages = transport.get_sent_messages().await;
        assert_eq!(sent_messages.len(), 1);
    }
}
