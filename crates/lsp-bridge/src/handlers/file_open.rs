use anyhow::Result;
use async_trait::async_trait;
use lsp_bridge::LspRegistry;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use vim::Handler;

#[derive(Debug, Deserialize)]
#[allow(dead_code)]
pub struct FileOpenRequest {
    pub command: String,
    pub file: String,
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
        _ctx: &mut dyn vim::VimContext,
        input: Self::Input,
    ) -> Result<Option<Self::Output>> {
        // Open file in appropriate language server
        if let Err(e) = self.lsp_registry.open_file(&input.file).await {
            return Ok(Some(FileOpenResponse::error(format!(
                "Failed to open file: {}",
                e
            ))));
        }

        Ok(Some(FileOpenResponse::success()))
    }
}
