use anyhow::Result;
use async_trait::async_trait;
use lsp_bridge::LspRegistry;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tracing::debug;
use vim::Handler;

#[derive(Debug, Deserialize)]
#[allow(dead_code)]
pub struct DidCloseRequest {
    pub file: String,
}

#[derive(Debug, Serialize)]
pub struct DidCloseResult {
    pub success: bool,
}

// Linus-style: DidCloseResult 要么完整存在，要么不存在
pub type DidCloseResponse = Option<DidCloseResult>;

impl DidCloseResult {
    pub fn new(success: bool) -> Self {
        Self { success }
    }
}

pub struct DidCloseHandler {
    lsp_registry: Arc<LspRegistry>,
}

impl DidCloseHandler {
    pub fn new(registry: Arc<LspRegistry>) -> Self {
        Self {
            lsp_registry: registry,
        }
    }
}

#[async_trait]
impl Handler for DidCloseHandler {
    type Input = DidCloseRequest;
    type Output = DidCloseResponse;

    async fn handle(
        &self,
        _ctx: &mut dyn vim::VimContext,
        input: Self::Input,
    ) -> Result<Option<Self::Output>> {
        // Detect language
        let language = match self.lsp_registry.detect_language(&input.file) {
            Some(lang) => lang,
            None => return Ok(Some(Some(DidCloseResult::new(false)))), // Unsupported file type
        };

        // Ensure client exists
        if self.lsp_registry.get_client(&language, &input.file).await.is_err() {
            return Ok(Some(Some(DidCloseResult::new(false))));
        }

        // Convert file path to URI
        let uri = match super::common::file_path_to_uri(&input.file) {
            Ok(uri) => uri,
            Err(_) => return Ok(Some(Some(DidCloseResult::new(false)))), // 处理了请求，但转换失败
        };

        // Send LSP didClose notification
        let params = lsp_types::DidCloseTextDocumentParams {
            text_document: lsp_types::TextDocumentIdentifier {
                uri: lsp_types::Url::parse(&uri)?,
            },
        };

        // didClose is a notification, not a request (no response expected)
        match self
            .lsp_registry
            .notify(&language, "textDocument/didClose", params)
            .await
        {
            Ok(_) => {
                debug!("DidClose notification sent for: {}", input.file);
                Ok(Some(Some(DidCloseResult::new(true))))
            }
            Err(e) => {
                debug!("DidClose notification failed: {:?}", e);
                Ok(Some(Some(DidCloseResult::new(false))))
            }
        }
    }
}
