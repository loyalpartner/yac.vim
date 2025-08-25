use anyhow::Result;
use async_trait::async_trait;
use lsp_bridge::LspRegistry;
use serde::Deserialize;
use std::sync::Arc;
use tracing::debug;
use vim::Handler;

#[derive(Debug, Deserialize)]
#[allow(dead_code)]
pub struct DidSaveRequest {
    pub file: String,
    pub text: Option<String>, // Full document text (if server supports it)
}

// Notification pattern - no response data needed
pub type DidSaveResponse = Option<()>;

#[derive(Clone)]
pub struct DidSaveHandler {
    lsp_registry: Arc<LspRegistry>,
}

impl DidSaveHandler {
    pub fn new(registry: Arc<LspRegistry>) -> Self {
        Self {
            lsp_registry: registry,
        }
    }
}

#[async_trait]
impl Handler for DidSaveHandler {
    type Input = DidSaveRequest;
    type Output = DidSaveResponse;

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

        // Send LSP didSave notification
        let params = lsp_types::DidSaveTextDocumentParams {
            text_document: lsp_types::TextDocumentIdentifier {
                uri: lsp_types::Url::parse(&uri)?,
            },
            text: input.text,
        };

        // didSave is a notification, not a request (no response expected)
        match self
            .lsp_registry
            .notify(&language, "textDocument/didSave", params)
            .await
        {
            Ok(_) => {
                debug!("DidSave notification sent for: {}", input.file);
                Ok(None) // Notification pattern - no response needed
            }
            Err(e) => {
                debug!("DidSave notification failed: {:?}", e);
                Ok(None) // Notification pattern - ignore errors
            }
        }
    }
}
