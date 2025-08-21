//! FileOpen handler example
//!
//! Demonstrates implementing a notification handler that doesn't return a value.

use anyhow::Result;
use async_trait::async_trait;
use serde::Deserialize;
use vim::{Handler, Vim};

/// File open handler - notification type
pub struct FileOpenHandler;

#[derive(Deserialize)]
pub struct FileOpenParams {
    pub file: String,
}

#[async_trait]
impl Handler for FileOpenHandler {
    type Input = FileOpenParams;
    type Output = (); // notification doesn't use Output

    async fn handle(&self, params: Self::Input) -> Result<Option<Self::Output>> {
        // Open file in LSP server
        open_file_in_lsp(&params.file).await?;
        Ok(None) // notification returns no value
    }
}

async fn open_file_in_lsp(file: &str) -> Result<()> {
    // Simulate sending textDocument/didOpen notification to LSP server
    println!("Opening file in LSP: {}", file);
    Ok(())
}

#[tokio::main]
async fn main() -> Result<()> {
    let mut vim = Vim::new_stdio();
    vim.add_handler("file_open", FileOpenHandler);
    vim.run().await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_file_open_handler() {
        let handler = FileOpenHandler;
        let params = FileOpenParams {
            file: "src/lib.rs".to_string(),
        };

        let result = handler.handle(params).await.unwrap();
        assert!(result.is_none()); // notification returns None
    }
}
