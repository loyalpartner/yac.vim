use anyhow::Result;
use async_trait::async_trait;
use lsp_bridge::LspRegistry;
use serde::Deserialize;
use std::sync::Arc;
use tracing::debug;
use vim::Handler;

#[derive(Debug, Deserialize)]
#[allow(dead_code)]
pub struct DidCloseRequest {
    pub file: String,
}

// Notification pattern - no response data needed
pub type DidCloseResponse = Option<()>;

#[derive(Clone)]
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
            None => return Ok(None), // Unsupported file type - notification ignores errors
        };

        // Ensure client exists
        if self
            .lsp_registry
            .get_client(&language, &input.file)
            .await
            .is_err()
        {
            return Ok(None); // No client available - notification ignores errors
        }

        // Convert file path to URI
        let uri = match super::common::file_path_to_uri(&input.file) {
            Ok(uri) => uri,
            Err(_) => return Ok(None), // URI conversion failed - notification ignores errors
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
                Ok(None) // Notification pattern - no response needed
            }
            Err(e) => {
                debug!("DidClose notification failed: {:?}", e);
                Ok(None) // Notification pattern - ignore errors
            }
        }
    }
}
