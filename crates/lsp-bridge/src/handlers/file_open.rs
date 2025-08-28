use anyhow::Result;
use async_trait::async_trait;
use lsp_bridge::LspRegistry;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use vim::Handler;

use super::common::extract_ssh_path;

#[derive(Debug, Deserialize)]
#[allow(dead_code)]
pub struct FileOpenRequest {
    pub command: String,
    pub file: String,
    pub line: u32,
    pub column: u32,
}

#[derive(Debug, Serialize)]
pub struct FileOpenResponse {
    pub action: String,
    pub message: Option<String>,
}

impl FileOpenResponse {
    pub fn success() -> Self {
        Self {
            action: "none".to_string(),
            message: None,
        }
    }

    pub fn error(message: String) -> Self {
        Self {
            action: "error".to_string(),
            message: Some(message),
        }
    }
}

pub struct FileOpenHandler {
    lsp_registry: Arc<LspRegistry>,
}

impl FileOpenHandler {
    pub fn new(registry: Arc<LspRegistry>) -> Self {
        Self {
            lsp_registry: registry,
        }
    }
}

#[async_trait]
impl Handler for FileOpenHandler {
    type Input = FileOpenRequest;
    type Output = FileOpenResponse;

    async fn handle(
        &self,
        _vim: &dyn vim::VimContext,
        input: Self::Input,
    ) -> Result<Option<Self::Output>> {
        // Extract real file path from SSH path if needed
        let (_, real_path) = extract_ssh_path(&input.file);

        // Open file in appropriate language server using real path
        if let Err(e) = self.lsp_registry.open_file(&real_path).await {
            return Ok(Some(FileOpenResponse::error(format!(
                "Failed to open file: {}",
                e
            ))));
        }

        Ok(Some(FileOpenResponse::success()))
    }
}
