use anyhow::{Error, Result};
use serde_json::Value;

/// JSON-RPC messages (vim-to-client and responses)
#[derive(Debug, Clone)]
pub enum JsonRpcMessage {
    /// Request from vim to client: [positive_id, {"method": "xxx", "params": ...}]
    Request {
        id: u64,
        method: String,
        params: Value,
    },
    /// Response to client request: [negative_id, result]
    Response { id: i64, result: Value },
    /// Notification: [{"method": "xxx", "params": ...}]
    Notification { method: String, params: Value },
}

impl JsonRpcMessage {
    /// Parse JSON-RPC message from JSON array
    pub fn parse(arr: &[Value]) -> Result<Self> {
        match arr.len() {
            1 if arr[0].is_object() => {
                // Notification: [{"method": "xxx", "params": ...}]
                let obj = arr[0]
                    .as_object()
                    .ok_or_else(|| Error::msg("Invalid notification object"))?;

                let method = obj
                    .get("method")
                    .and_then(|v| v.as_str())
                    .ok_or_else(|| Error::msg("Missing method in notification"))?
                    .to_string();

                let params = obj.get("params").cloned().unwrap_or(Value::Null);

                Ok(JsonRpcMessage::Notification { method, params })
            }
            2 => {
                match &arr[0] {
                    Value::Number(n) if n.as_i64().map(|x| x > 0).unwrap_or(false) => {
                        // Request: [positive_id, {"method": "xxx", "params": ...}]
                        let id = n.as_u64().ok_or_else(|| Error::msg("Invalid request id"))?;

                        let obj = arr[1]
                            .as_object()
                            .ok_or_else(|| Error::msg("Invalid request object"))?;

                        let method = obj
                            .get("method")
                            .and_then(|v| v.as_str())
                            .ok_or_else(|| Error::msg("Missing method in request"))?
                            .to_string();

                        let params = obj.get("params").cloned().unwrap_or(Value::Null);

                        Ok(JsonRpcMessage::Request { id, method, params })
                    }
                    Value::Number(n) if n.as_i64().map(|x| x < 0).unwrap_or(false) => {
                        // Response: [negative_id, result]
                        let id = n
                            .as_i64()
                            .ok_or_else(|| Error::msg("Invalid response id"))?;
                        let result = arr[1].clone();

                        Ok(JsonRpcMessage::Response { id, result })
                    }
                    _ => Err(Error::msg("Invalid JSON-RPC message format")),
                }
            }
            _ => Err(Error::msg("Invalid JSON-RPC message length")),
        }
    }

    /// Encode JSON-RPC message to JSON
    pub fn encode(&self) -> Value {
        match self {
            JsonRpcMessage::Request { id, method, params } => {
                serde_json::json!([*id, {"method": method, "params": params}])
            }
            JsonRpcMessage::Response { id, result } => {
                serde_json::json!([*id, result])
            }
            JsonRpcMessage::Notification { method, params } => {
                serde_json::json!([{"method": method, "params": params}])
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn test_jsonrpc_request_parsing() {
        let json = json!([1, {"method": "goto_definition", "params": {"file": "test.rs"}}]);
        let msg = JsonRpcMessage::parse(json.as_array().unwrap()).unwrap();

        match msg {
            JsonRpcMessage::Request { id, method, params } => {
                assert_eq!(id, 1);
                assert_eq!(method, "goto_definition");
                assert_eq!(params["file"], "test.rs");
            }
            _ => panic!("Expected Request"),
        }
    }

    #[test]
    fn test_jsonrpc_response_parsing() {
        let json = json!([-42, {"result": "success"}]);
        let msg = JsonRpcMessage::parse(json.as_array().unwrap()).unwrap();

        match msg {
            JsonRpcMessage::Response { id, result } => {
                assert_eq!(id, -42);
                assert_eq!(result["result"], "success");
            }
            _ => panic!("Expected Response"),
        }
    }

    #[test]
    fn test_jsonrpc_notification_parsing() {
        let json = json!([{"method": "goto_definition_notification", "params": {"file": "test.rs", "line": 10}}]);
        let msg = JsonRpcMessage::parse(json.as_array().unwrap()).unwrap();

        match msg {
            JsonRpcMessage::Notification { method, params } => {
                assert_eq!(method, "goto_definition_notification");
                assert_eq!(params["file"], "test.rs");
                assert_eq!(params["line"], 10);
            }
            _ => panic!("Expected Notification"),
        }
    }

    #[test]
    fn test_jsonrpc_encoding() {
        // Test request encoding
        let msg = JsonRpcMessage::Request {
            id: 123,
            method: "goto_definition".to_string(),
            params: json!({"file": "test.rs"}),
        };
        let encoded = msg.encode();
        let expected = json!([123, {"method": "goto_definition", "params": {"file": "test.rs"}}]);
        assert_eq!(encoded, expected);

        // Test response encoding
        let msg = JsonRpcMessage::Response {
            id: -42,
            result: json!({"location": "test.rs:10:5"}),
        };
        let encoded = msg.encode();
        let expected = json!([-42, {"location": "test.rs:10:5"}]);
        assert_eq!(encoded, expected);
    }
}
