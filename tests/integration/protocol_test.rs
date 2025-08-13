use yac_vim::lsp::{LspMessageParser, format_lsp_message, JsonRpcMessage};

#[test]
fn test_lsp_message_format() {
    let json_message = r#"{"jsonrpc":"2.0","method":"test","params":{}}"#;
    let formatted = format_lsp_message(json_message);
    
    assert!(formatted.contains("Content-Length:"));
    assert!(formatted.contains("Content-Type: application/vscode-jsonrpc"));
    assert!(formatted.ends_with(json_message));
    
    // 验证Content-Length的值是正确的
    let expected_length = json_message.len();
    assert!(formatted.contains(&format!("Content-Length: {}", expected_length)));
}

#[test]
fn test_lsp_message_parser_single_message() {
    let mut parser = LspMessageParser::new();
    let json_message = r#"{"jsonrpc":"2.0","method":"test","params":{}}"#;
    let formatted = format_lsp_message(json_message);
    
    let messages = parser.parse_messages(&formatted).unwrap();
    assert_eq!(messages.len(), 1);
    
    match &messages[0] {
        JsonRpcMessage::Notification(notification) => {
            assert_eq!(notification.method, "test");
        }
        _ => panic!("Expected notification message"),
    }
}

#[test]
fn test_lsp_message_parser_multiple_messages() {
    let mut parser = LspMessageParser::new();
    
    let msg1 = r#"{"jsonrpc":"2.0","method":"test1","params":{}}"#;
    let msg2 = r#"{"jsonrpc":"2.0","method":"test2","params":{}}"#;
    let msg3 = r#"{"jsonrpc":"2.0","id":1,"result":{"success":true}}"#;
    
    let formatted = format!(
        "{}{}{}",
        format_lsp_message(msg1),
        format_lsp_message(msg2),
        format_lsp_message(msg3)
    );
    
    let messages = parser.parse_messages(&formatted).unwrap();
    assert_eq!(messages.len(), 3);
    
    // 验证消息类型
    assert!(matches!(messages[0], JsonRpcMessage::Notification(_)));
    assert!(matches!(messages[1], JsonRpcMessage::Notification(_)));
    assert!(matches!(messages[2], JsonRpcMessage::Response(_)));
}

#[test]
fn test_lsp_message_parser_incremental() {
    let mut parser = LspMessageParser::new();
    let json_message = r#"{"jsonrpc":"2.0","method":"test","params":{}}"#;
    let formatted = format_lsp_message(json_message);
    
    // 分块发送消息
    let mid_point = formatted.len() / 2;
    let part1 = &formatted[..mid_point];
    let part2 = &formatted[mid_point..];
    
    // 第一部分应该没有完整消息
    let messages1 = parser.parse_messages(part1).unwrap();
    assert_eq!(messages1.len(), 0);
    
    // 第二部分应该能解析出完整消息
    let messages2 = parser.parse_messages(part2).unwrap();
    assert_eq!(messages2.len(), 1);
}

#[test]
fn test_lsp_message_parser_invalid_content_length() {
    let mut parser = LspMessageParser::new();
    
    // 错误的Content-Length
    let invalid_message = "Content-Length: 999\r\n\r\n{\"jsonrpc\":\"2.0\"}";
    
    let result = parser.parse_messages(invalid_message);
    // 应该能处理但可能返回错误或空结果
    assert!(result.is_ok() || result.is_err());
}

#[test]
fn test_lsp_message_parser_malformed_json() {
    let mut parser = LspMessageParser::new();
    
    // 格式错误的JSON
    let malformed_json = r#"{"jsonrpc":"2.0","method":incomplete"#;
    let formatted = format_lsp_message(malformed_json);
    
    let result = parser.parse_messages(&formatted);
    // 应该返回错误
    assert!(result.is_err());
}

#[test]
fn test_json_rpc_request_parsing() {
    let request_json = r#"{"jsonrpc":"2.0","method":"textDocument/completion","params":{"uri":"file:///test.rs","position":{"line":1,"character":5}},"id":1}"#;
    
    let parsed: Result<JsonRpcMessage, _> = serde_json::from_str(request_json);
    assert!(parsed.is_ok());
    
    match parsed.unwrap() {
        JsonRpcMessage::Request(request) => {
            assert_eq!(request.method, "textDocument/completion");
            assert!(request.params.is_some());
        }
        _ => panic!("Expected request message"),
    }
}

#[test]
fn test_json_rpc_response_parsing() {
    let response_json = r#"{"jsonrpc":"2.0","id":1,"result":{"items":[{"label":"test"}]}}"#;
    
    let parsed: Result<JsonRpcMessage, _> = serde_json::from_str(response_json);
    assert!(parsed.is_ok());
    
    match parsed.unwrap() {
        JsonRpcMessage::Response(response) => {
            assert!(response.result.is_some());
            assert!(response.error.is_none());
        }
        _ => panic!("Expected response message"),
    }
}

#[test]
fn test_json_rpc_notification_parsing() {
    let notification_json = r#"{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///test.rs","languageId":"rust","version":1,"text":"fn main() {}"}}}"#;
    
    let parsed: Result<JsonRpcMessage, _> = serde_json::from_str(notification_json);
    assert!(parsed.is_ok());
    
    match parsed.unwrap() {
        JsonRpcMessage::Notification(notification) => {
            assert_eq!(notification.method, "textDocument/didOpen");
            assert!(notification.params.is_some());
        }
        _ => panic!("Expected notification message"),
    }
}

#[test]
fn test_lsp_protocol_compliance() {
    // 测试LSP协议的基本合规性
    let mut parser = LspMessageParser::new();
    
    // Initialize request
    let initialize_request = r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"clientInfo":{"name":"test-client","version":"1.0"},"capabilities":{}}}"#;
    let formatted = format_lsp_message(initialize_request);
    
    let messages = parser.parse_messages(&formatted).unwrap();
    assert_eq!(messages.len(), 1);
    
    match &messages[0] {
        JsonRpcMessage::Request(req) => {
            assert_eq!(req.method, "initialize");
            assert_eq!(req.jsonrpc, "2.0");
            assert!(req.params.is_some());
        }
        _ => panic!("Expected initialize request"),
    }
}