//! Comprehensive Handler trait example
//!
//! This example demonstrates Handler patterns in the vim crate:
//! 1. **Method with return value**: `Output = T`, returns `Ok(HandlerResult::Data(value))`
//! 2. **Empty result**: returns `Ok(HandlerResult::Empty)` when no data available
//!
//! The Handler returns result, dispatcher decides whether to send response
//! based on JSON-RPC protocol (request vs notification).

use anyhow::Result;
use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use vim::{Handler, HandlerResult, VimClient, VimContext};

/// Goto definition handler - demonstrates method with return value pattern
///
/// This is the most common LSP handler pattern:
/// - `HandlerResult::Data(value)`: Return data to caller
/// - `HandlerResult::Empty`: No data available (not an error)
///
/// The dispatcher decides whether to send response based on message type
/// (request vs notification), not on handler return value.
pub struct GotoDefinitionHandler;

#[derive(Deserialize)]
pub struct GotoDefinitionParams {
    pub file: String,
    pub line: u32,
    pub column: u32,
}

/// LSP location result type
#[derive(Serialize)]
pub struct Location {
    pub file: String,
    pub line: u32,
    pub column: u32,
}

#[async_trait]
impl Handler for GotoDefinitionHandler {
    type Input = GotoDefinitionParams;
    type Output = Location;

    async fn handle(
        &self,
        _vim: &dyn VimContext,
        params: Self::Input,
    ) -> Result<HandlerResult<Self::Output>> {
        // Simulate LSP call
        match find_definition(&params.file, params.line, params.column).await {
            Some(location) => Ok(HandlerResult::Data(location)),
            None => Ok(HandlerResult::Empty), // Not finding definition is not an error
        }
    }
}

async fn find_definition(file: &str, line: u32, column: u32) -> Option<Location> {
    // Simulate LSP call to rust-analyzer
    // Actual implementation would use LSP protocol
    if file.ends_with(".rs") && line > 0 {
        Some(Location {
            file: file.replace("src/", "src/lib/"),
            line: line + 10,
            column,
        })
    } else {
        None
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    let mut vim = VimClient::new_stdio();
    vim.add_handler("goto_definition", GotoDefinitionHandler);
    vim.run().await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_goto_definition_handler() {
        let handler = GotoDefinitionHandler;
        let params = GotoDefinitionParams {
            file: "src/main.rs".to_string(),
            line: 10,
            column: 5,
        };

        // Create a mock context for testing
        struct MockVimContext;
        impl VimContext for MockVimContext {}

        let ctx = MockVimContext;
        let result = handler.handle(&ctx, params).await.unwrap();

        match result {
            HandlerResult::Data(location) => {
                assert_eq!(location.file, "src/lib/main.rs");
                assert_eq!(location.line, 20);
            }
            HandlerResult::Empty => panic!("Expected Data, got Empty"),
        }
    }
}
