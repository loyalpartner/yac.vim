// 集成测试 - 测试 LspClient 与 Mock LSP server 的交互

use lsp_client::{mock::MockLspServer, *};
use serde_json::json;

#[cfg(test)]
mod lsp_client_integration_tests {
    use super::*;

    #[tokio::test]
    async fn test_mock_server_basic_request_response() {
        let (mut server, mut client) = MockLspServer::new();
        
        // Setup handler for initialize request
        server.on_request_simple("initialize", json!({
            "capabilities": {
                "definitionProvider": true,
                "hoverProvider": true
            },
            "serverInfo": {
                "name": "mock-lsp",
                "version": "1.0.0"
            }
        }));

        // Start server in background
        let server_handle = tokio::spawn(async move {
            server.run().await.unwrap();
        });

        // Send initialize request
        let request = JsonRpcRequest {
            jsonrpc: "2.0".to_string(),
            id: RequestId::Number(1),
            method: "initialize".to_string(),
            params: json!({
                "capabilities": {}
            }),
        };

        let request_str = serde_json::to_string(&JsonRpcMessage::Request(request)).unwrap();
        client.send_message(&request_str).await.unwrap();

        // Receive response
        let response = client.receive_message().await.unwrap();
        assert!(response.is_some());
        
        let response_str = response.unwrap();
        let response_msg: JsonRpcMessage = serde_json::from_str(&response_str).unwrap();
        
        match response_msg {
            JsonRpcMessage::Response(response) => {
                assert_eq!(response.id, RequestId::Number(1));
                assert!(response.result.is_some());
                assert!(response.error.is_none());
                
                let result = response.result.unwrap();
                assert_eq!(result["serverInfo"]["name"], "mock-lsp");
            }
            _ => panic!("Expected response message"),
        }

        server_handle.abort();
    }

    #[tokio::test]
    async fn test_mock_server_method_not_found() {
        let (mut server, mut client) = MockLspServer::new();
        
        // Start server without any handlers
        let server_handle = tokio::spawn(async move {
            server.run().await.unwrap();
        });

        // Send request for unhandled method
        let request = JsonRpcRequest {
            jsonrpc: "2.0".to_string(),
            id: RequestId::Number(1),
            method: "nonexistent".to_string(),
            params: json!({}),
        };

        let request_str = serde_json::to_string(&JsonRpcMessage::Request(request)).unwrap();
        client.send_message(&request_str).await.unwrap();

        // Should receive error response
        let response = client.receive_message().await.unwrap();
        assert!(response.is_some());
        
        let response_str = response.unwrap();
        let response_msg: JsonRpcMessage = serde_json::from_str(&response_str).unwrap();
        
        match response_msg {
            JsonRpcMessage::Response(response) => {
                assert_eq!(response.id, RequestId::Number(1));
                assert!(response.result.is_none());
                assert!(response.error.is_some());
                
                let error = response.error.unwrap();
                assert_eq!(error.code, -32601); // Method not found
                assert!(error.message.contains("Method not found"));
            }
            _ => panic!("Expected response message"),
        }

        server_handle.abort();
    }

    #[tokio::test] 
    async fn test_mock_server_goto_definition() {
        let (mut server, mut client) = MockLspServer::new();
        
        // Setup handler for textDocument/definition
        server.on_request_simple("textDocument/definition", json!([
            {
                "uri": "file:///test.rs",
                "range": {
                    "start": {"line": 10, "character": 5},
                    "end": {"line": 10, "character": 15}
                }
            }
        ]));

        let server_handle = tokio::spawn(async move {
            server.run().await.unwrap();
        });

        // Send goto definition request
        let request = JsonRpcRequest {
            jsonrpc: "2.0".to_string(),
            id: RequestId::Number(2),
            method: "textDocument/definition".to_string(),
            params: json!({
                "textDocument": {
                    "uri": "file:///test.rs"
                },
                "position": {
                    "line": 5,
                    "character": 10
                }
            }),
        };

        let request_str = serde_json::to_string(&JsonRpcMessage::Request(request)).unwrap();
        client.send_message(&request_str).await.unwrap();

        // Receive definition response
        let response = client.receive_message().await.unwrap();
        assert!(response.is_some());
        
        let response_str = response.unwrap();
        let response_msg: JsonRpcMessage = serde_json::from_str(&response_str).unwrap();
        
        match response_msg {
            JsonRpcMessage::Response(response) => {
                assert_eq!(response.id, RequestId::Number(2));
                assert!(response.result.is_some());
                assert!(response.error.is_none());
                
                let result = response.result.unwrap();
                assert!(result.is_array());
                let definitions = result.as_array().unwrap();
                assert_eq!(definitions.len(), 1);
                
                let definition = &definitions[0];
                assert_eq!(definition["uri"], "file:///test.rs");
                assert_eq!(definition["range"]["start"]["line"], 10);
            }
            _ => panic!("Expected response message"),
        }

        server_handle.abort();
    }

    #[tokio::test]
    async fn test_mock_server_notifications() {
        let (mut server, mut client) = MockLspServer::new();
        
        let server_handle = tokio::spawn(async move {
            server.run().await.unwrap();
        });

        // Send notification (should not get response)
        let notification = JsonRpcNotification {
            jsonrpc: "2.0".to_string(),
            method: "textDocument/didOpen".to_string(),
            params: json!({
                "textDocument": {
                    "uri": "file:///test.rs",
                    "languageId": "rust",
                    "version": 1,
                    "text": "fn main() {}"
                }
            }),
        };

        let notification_str = serde_json::to_string(&JsonRpcMessage::Notification(notification)).unwrap();
        client.send_message(&notification_str).await.unwrap();

        // Should not receive any response for notification
        tokio::time::sleep(tokio::time::Duration::from_millis(100)).await;
        let response = tokio::time::timeout(
            tokio::time::Duration::from_millis(50),
            client.receive_message()
        ).await;
        
        // Should timeout (no response expected)
        assert!(response.is_err());

        server_handle.abort();
    }
}