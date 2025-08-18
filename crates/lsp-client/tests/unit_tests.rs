// 单元测试 - 测试各个组件的独立功能

use lsp_client::*;
use serde_json::json;

#[cfg(test)]
mod message_framer_tests {
    use super::*;

    #[test]
    fn test_frame_message() {
        let mut framer = MessageFramer::new();
        let content = r#"{"jsonrpc":"2.0","id":1,"method":"test"}"#;
        let framed = framer.frame_message(content);
        
        let expected = format!("Content-Length: {}\r\n\r\n{}", content.len(), content);
        assert_eq!(std::str::from_utf8(&framed).unwrap(), expected);
    }

    #[test]
    fn test_parse_single_message() {
        let mut framer = MessageFramer::new();
        let content = r#"{"jsonrpc":"2.0","id":1,"method":"test"}"#;
        let raw_message = format!("Content-Length: {}\r\n\r\n{}", content.len(), content);
        
        let messages = framer.parse_messages(raw_message.as_bytes()).unwrap();
        assert_eq!(messages.len(), 1);
        assert_eq!(messages[0], content);
    }

    #[test]
    fn test_parse_multiple_messages() {
        let mut framer = MessageFramer::new();
        let content1 = r#"{"jsonrpc":"2.0","id":1,"method":"test1"}"#;
        let content2 = r#"{"jsonrpc":"2.0","id":2,"method":"test2"}"#;
        
        let raw_message = format!(
            "Content-Length: {}\r\n\r\n{}Content-Length: {}\r\n\r\n{}",
            content1.len(), content1, content2.len(), content2
        );
        
        let messages = framer.parse_messages(raw_message.as_bytes()).unwrap();
        assert_eq!(messages.len(), 2);
        assert_eq!(messages[0], content1);
        assert_eq!(messages[1], content2);
    }

    #[test]
    fn test_parse_incomplete_message() {
        let mut framer = MessageFramer::new();
        let content = r#"{"jsonrpc":"2.0","id":1,"method":"test"}"#;
        let incomplete = format!("Content-Length: {}\r\n\r\n{}", content.len(), &content[..10]);
        
        let messages = framer.parse_messages(incomplete.as_bytes()).unwrap();
        assert_eq!(messages.len(), 0); // Should wait for complete message
    }
}

#[cfg(test)]
mod request_id_tests {
    use super::*;

    #[test]
    fn test_request_id_from_number() {
        let id: RequestId = 42u32.into();
        assert_eq!(id, RequestId::Number(42));
    }

    #[test]
    fn test_request_id_from_string() {
        let id: RequestId = "test-123".to_string().into();
        assert_eq!(id, RequestId::String("test-123".to_string()));
    }

    #[test]
    fn test_request_id_serialization() {
        let number_id = RequestId::Number(42);
        let string_id = RequestId::String("test".to_string());
        
        let number_json = serde_json::to_value(number_id).unwrap();
        let string_json = serde_json::to_value(string_id).unwrap();
        
        assert_eq!(number_json, json!(42));
        assert_eq!(string_json, json!("test"));
    }
}

#[cfg(test)]
mod json_rpc_message_tests {
    use super::*;

    #[test]
    fn test_request_serialization() {
        let request = JsonRpcRequest {
            jsonrpc: "2.0".to_string(),
            id: RequestId::Number(1),
            method: "initialize".to_string(),
            params: json!({"capabilities": {}}),
        };

        let serialized = serde_json::to_string(&request).unwrap();
        let parsed: JsonRpcRequest = serde_json::from_str(&serialized).unwrap();
        
        assert_eq!(parsed.jsonrpc, "2.0");
        assert_eq!(parsed.id, RequestId::Number(1));
        assert_eq!(parsed.method, "initialize");
    }

    #[test]
    fn test_response_serialization() {
        let response = JsonRpcResponse {
            jsonrpc: "2.0".to_string(),
            id: RequestId::Number(1),
            result: Some(json!({"success": true})),
            error: None,
        };

        let serialized = serde_json::to_string(&response).unwrap();
        let parsed: JsonRpcResponse = serde_json::from_str(&serialized).unwrap();
        
        assert_eq!(parsed.jsonrpc, "2.0");
        assert_eq!(parsed.id, RequestId::Number(1));
        assert!(parsed.result.is_some());
        assert!(parsed.error.is_none());
    }

    #[test]
    fn test_error_response_serialization() {
        let response = JsonRpcResponse {
            jsonrpc: "2.0".to_string(),
            id: RequestId::Number(1),
            result: None,
            error: Some(JsonRpcError {
                code: -32601,
                message: "Method not found".to_string(),
                data: None,
            }),
        };

        let serialized = serde_json::to_string(&response).unwrap();
        let parsed: JsonRpcResponse = serde_json::from_str(&serialized).unwrap();
        
        assert_eq!(parsed.jsonrpc, "2.0");
        assert!(parsed.result.is_none());
        assert!(parsed.error.is_some());
        assert_eq!(parsed.error.unwrap().code, -32601);
    }

    #[test]
    fn test_notification_serialization() {
        let notification = JsonRpcNotification {
            jsonrpc: "2.0".to_string(),
            method: "initialized".to_string(),
            params: json!({}),
        };

        let serialized = serde_json::to_string(&notification).unwrap();
        let parsed: JsonRpcNotification = serde_json::from_str(&serialized).unwrap();
        
        assert_eq!(parsed.jsonrpc, "2.0");
        assert_eq!(parsed.method, "initialized");
    }
}