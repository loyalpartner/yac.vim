//! Comprehensive Handler trait example
//!
//! This example demonstrates all three Handler patterns in the vim crate:
//! 1. **Method with return value** (main example): `Output = T`, returns `Ok(Some(value))`
//! 2. **Notification without return**: `Output = ()`, returns `Ok(None)`
//! 3. **Optional return value**: `Output = T`, returns `Ok(Some(value))` or `Ok(None)`
//!
//! The unified Handler trait uses `Option<Output>` to eliminate method/notification
//! special cases through better data structures (following Linus philosophy).

use anyhow::Result;
use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use vim::{Handler, Vim, VimContext};

/// Goto definition handler - demonstrates method with return value pattern
///
/// This is the most common LSP handler pattern. For other patterns:
///
/// **Notification pattern** (no return):
/// ```ignore
/// impl Handler for NotificationHandler {
///     type Input = NotificationParams;
///     type Output = (); // Key: use unit type for notifications
///
///     async fn handle(&self, ctx: &mut dyn VimContext, params: Self::Input) -> Result<Option<Self::Output>> {
///         // Do side effect (e.g., open file, send notification to LSP)
///         perform_action(params).await?;
///         Ok(None) // Always return None for notifications
///     }
/// }
/// ```
///
/// **Optional return pattern** (may or may not have value):
/// ```ignore
/// impl Handler for OptionalHandler {
///     type Input = QueryParams;
///     type Output = QueryResult;
///
///     async fn handle(&self, ctx: &mut dyn VimContext, params: Self::Input) -> Result<Option<Self::Output>> {
///         match query_data(params).await {
///             Some(result) => Ok(Some(result)), // Found data
///             None => Ok(None), // No data available (not an error)
///         }
///     }
/// }
/// ```
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
        _ctx: &mut dyn VimContext,
        params: Self::Input,
    ) -> Result<Option<Self::Output>> {
        // Simulate LSP call
        match find_definition(&params.file, params.line, params.column).await {
            Some(location) => Ok(Some(location)),
            None => Ok(None), // Not finding definition is not an error
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
    let mut vim = Vim::new_stdio();
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

        let mut vim = Vim::new_stdio();
        let result = handler.handle(&mut vim, params).await.unwrap();
        assert!(result.is_some());

        let location = result.unwrap();
        assert_eq!(location.file, "src/lib/main.rs");
        assert_eq!(location.line, 20);
    }
}
