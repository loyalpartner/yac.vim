use serde_json::json;
use yac_vim::lsp::protocol::{Position, VimRequest, CompletionContext};

/// Test that demonstrates the completion flow integration
#[cfg(test)]
mod completion_integration_tests {
    use super::*;
    
    #[test]
    fn test_completion_response_parsing() {
        // Test the parse_completion_response function with realistic LSP data
        let mock_lsp_response = json!({
            "items": [
                {
                    "label": "println!",
                    "kind": 15,
                    "detail": "macro",
                    "documentation": "Prints to the standard output, with a newline.",
                    "insertText": "println!",
                    "sortText": "0001"
                },
                {
                    "label": "print!",
                    "kind": 15,
                    "detail": "macro",
                    "documentation": "Prints to the standard output.",
                    "insertText": "print!",
                    "sortText": "0002"
                }
            ],
            "isIncomplete": false
        });
        
        // Call the parsing function directly (it's a static method)
        let result = yac_vim::bridge::server::BridgeServer::parse_completion_response(
            "test_client",
            "test_request_123",
            mock_lsp_response
        );
        
        match result {
            Ok(vim_command) => {
                match vim_command {
                    yac_vim::lsp::protocol::VimCommand::ShowCompletion { request_id, items, incomplete, .. } => {
                        assert_eq!(request_id, "test_request_123");
                        assert_eq!(items.len(), 2);
                        assert_eq!(items[0].label, "println!");
                        assert_eq!(items[1].label, "print!");
                        assert!(!incomplete);
                        println!("✓ Successfully parsed {} completion items", items.len());
                    }
                    _ => panic!("Expected ShowCompletion command"),
                }
            }
            Err(e) => panic!("Failed to parse completion response: {}", e),
        }
    }
    
    #[test]
    fn test_empty_completion_response() {
        let empty_response = json!([]);
        
        let result = yac_vim::bridge::server::BridgeServer::parse_completion_response(
            "test_client",
            "test_request_456",
            empty_response
        );
        
        match result {
            Ok(vim_command) => {
                match vim_command {
                    yac_vim::lsp::protocol::VimCommand::ShowCompletion { items, .. } => {
                        assert_eq!(items.len(), 0);
                        println!("✓ Successfully handled empty completion response");
                    }
                    _ => panic!("Expected ShowCompletion command"),
                }
            }
            Err(e) => panic!("Failed to parse empty completion response: {}", e),
        }
    }
    
    #[test]
    fn test_vim_request_structure() {
        // Test that our VimRequest::Completion structure is properly formed
        let completion_request = VimRequest::Completion {
            uri: "file:///home/user/test.rs".to_string(),
            position: Position { line: 10, character: 5 },
            context: Some(CompletionContext {
                trigger_kind: 1,
                trigger_character: Some(".".to_string()),
            }),
        };
        
        // Verify serialization/deserialization
        let serialized = serde_json::to_string(&completion_request).unwrap();
        let deserialized: VimRequest = serde_json::from_str(&serialized).unwrap();
        
        match deserialized {
            VimRequest::Completion { uri, position, context } => {
                assert_eq!(uri, "file:///home/user/test.rs");
                assert_eq!(position.line, 10);
                assert_eq!(position.character, 5);
                assert!(context.is_some());
                println!("✓ VimRequest structure is correctly serializable");
            }
            _ => panic!("Expected Completion request"),
        }
    }
}