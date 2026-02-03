use crate::VimError;
use anyhow::Result;
use serde_json::Value;

use super::{ChannelCommand, JsonRpcMessage};

/// Unified protocol message - either JSON-RPC or Vim channel command
#[derive(Debug, Clone)]
pub enum VimProtocol {
    JsonRpc(JsonRpcMessage),
    Channel(ChannelCommand),
}

/// Protocol parser trait - data-driven parsing strategy
pub trait ProtocolParser: Send + Sync {
    fn can_parse(&self, json: &Value) -> bool;
    fn parse(&self, json: &Value) -> Result<VimProtocol>;
}

/// JSON-RPC protocol parser
pub struct JsonRpcParser;

impl ProtocolParser for JsonRpcParser {
    fn can_parse(&self, json: &Value) -> bool {
        if let Some(arr) = json.as_array() {
            match arr.len() {
                // Notification: [{"method": "xxx", "params": ...}]
                1 => arr[0].is_object() && arr[0].get("method").is_some(),
                // Request/Response: [id, data]
                2 => arr[0].is_number(),
                _ => false,
            }
        } else {
            false
        }
    }

    fn parse(&self, json: &Value) -> Result<VimProtocol> {
        let arr = json
            .as_array()
            .ok_or_else(|| VimError::Protocol("Expected JSON array for JSON-RPC".to_string()))?;

        let msg = JsonRpcMessage::parse(arr)?;
        Ok(VimProtocol::JsonRpc(msg))
    }
}

/// Vim channel command parser
pub struct ChannelParser;

impl ProtocolParser for ChannelParser {
    fn can_parse(&self, json: &Value) -> bool {
        if let Some(arr) = json.as_array() {
            if arr.is_empty() {
                return false;
            }

            // Channel commands start with string: ["call", ...], ["expr", ...], etc.
            if let Some(cmd) = arr[0].as_str() {
                matches!(cmd, "call" | "expr" | "ex" | "normal" | "redraw")
            } else {
                false
            }
        } else {
            false
        }
    }

    fn parse(&self, json: &Value) -> Result<VimProtocol> {
        let arr = json.as_array().ok_or_else(|| {
            VimError::Protocol("Expected JSON array for channel command".to_string())
        })?;

        let cmd = ChannelCommand::parse(arr)?;
        Ok(VimProtocol::Channel(cmd))
    }
}

/// Unified message parser - data-driven protocol dispatch
pub struct MessageParser {
    parsers: Vec<Box<dyn ProtocolParser>>,
}

impl Default for MessageParser {
    fn default() -> Self {
        Self::new()
    }
}

impl MessageParser {
    pub fn new() -> Self {
        Self {
            parsers: vec![Box::new(JsonRpcParser), Box::new(ChannelParser)],
        }
    }

    /// Parse unified vim protocol message
    pub fn parse(&self, json: &Value) -> Result<VimProtocol> {
        for parser in &self.parsers {
            if parser.can_parse(json) {
                return parser.parse(json);
            }
        }
        Err(VimError::Protocol("Unknown message format".to_string()).into())
    }
}

impl VimProtocol {
    /// Encode protocol message back to JSON
    pub fn encode(&self) -> Value {
        match self {
            VimProtocol::JsonRpc(msg) => msg.encode(),
            VimProtocol::Channel(cmd) => cmd.encode(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn test_message_parser() {
        let parser = MessageParser::new();

        // Test JSON-RPC request parsing
        let json = json!([1, {"method": "goto_definition", "params": {"file": "test.rs"}}]);
        let msg = parser.parse(&json).unwrap();

        match msg {
            VimProtocol::JsonRpc(JsonRpcMessage::Request { id, method, .. }) => {
                assert_eq!(id, 1);
                assert_eq!(method, "goto_definition");
            }
            _ => panic!("Expected JsonRpc Request"),
        }

        // Test channel command parsing
        let json = json!(["call", "test_func", ["arg1", 42], -123]);
        let msg = parser.parse(&json).unwrap();

        match msg {
            VimProtocol::Channel(ChannelCommand::Call { func, id, .. }) => {
                assert_eq!(func, "test_func");
                assert_eq!(id, -123);
            }
            _ => panic!("Expected Channel Call"),
        }

        // Test notification parsing
        let json = json!([{"method": "notification", "params": {"data": "test"}}]);
        let msg = parser.parse(&json).unwrap();

        match msg {
            VimProtocol::JsonRpc(JsonRpcMessage::Notification { method, .. }) => {
                assert_eq!(method, "notification");
            }
            _ => panic!("Expected JsonRpc Notification"),
        }
    }

    #[test]
    fn test_protocol_parsers() {
        let jsonrpc_parser = JsonRpcParser;
        let channel_parser = ChannelParser;

        // JSON-RPC can parse requests/responses/notifications
        assert!(jsonrpc_parser.can_parse(&json!([1, {"method": "test"}])));
        assert!(jsonrpc_parser.can_parse(&json!([-1, {"result": "ok"}])));
        assert!(jsonrpc_parser.can_parse(&json!([{"method": "notify"}])));

        // But not channel commands
        assert!(!jsonrpc_parser.can_parse(&json!(["call", "func", []])));

        // Channel parser can parse channel commands
        assert!(channel_parser.can_parse(&json!(["call", "func", []])));
        assert!(channel_parser.can_parse(&json!(["expr", "test"])));
        assert!(channel_parser.can_parse(&json!(["ex", "command"])));

        // But not JSON-RPC
        assert!(!channel_parser.can_parse(&json!([1, {"method": "test"}])));
    }

    #[test]
    fn test_protocol_encoding() {
        // Test that encoding preserves the original structure
        let parser = MessageParser::new();

        let original = json!(["call", "test_func", ["arg"], -123]);
        let parsed = parser.parse(&original).unwrap();
        let encoded = parsed.encode();

        assert_eq!(original, encoded);
    }
}
