//! Hover handler example
//!
//! Demonstrates implementing a handler that may or may not return a value.

use anyhow::Result;
use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use vim::{Handler, Vim};

/// Hover handler - method that may have return value
pub struct HoverHandler;

#[derive(Deserialize)]
pub struct HoverParams {
    pub file: String,
    pub line: u32,
    pub column: u32,
}

#[derive(Serialize)]
pub struct HoverResult {
    pub content: String,
}

#[async_trait]
impl Handler for HoverHandler {
    type Input = HoverParams;
    type Output = HoverResult;

    async fn handle(&self, params: Self::Input) -> Result<Option<Self::Output>> {
        match get_hover_info(&params.file, params.line, params.column).await {
            Some(content) => Ok(Some(HoverResult { content })),
            None => Ok(None), // No hover info available
        }
    }
}

async fn get_hover_info(file: &str, line: u32, column: u32) -> Option<String> {
    // Simulate LSP hover request
    if file.ends_with(".rs") {
        Some(format!("Type information for {}:{}:{}", file, line, column))
    } else {
        None
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    let mut vim = Vim::new_stdio();
    vim.add_handler("hover", HoverHandler);
    vim.run().await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_hover_handler() {
        let handler = HoverHandler;
        let params = HoverParams {
            file: "src/main.rs".to_string(),
            line: 5,
            column: 10,
        };

        let result = handler.handle(params).await.unwrap();
        assert!(result.is_some());

        let hover_result = result.unwrap();
        assert!(hover_result.content.contains("Type information"));
    }
}
