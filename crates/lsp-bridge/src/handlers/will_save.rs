use anyhow::Result;
use async_trait::async_trait;
use lsp_bridge::LspRegistry;
use serde::Deserialize;
use std::sync::Arc;
use tracing::debug;
use vim::{Handler, HandlerResult};

#[derive(Debug, Deserialize)]
#[allow(dead_code)]
pub struct WillSaveRequest {
    pub file: String,
    pub reason: String, // "Manual", "AfterDelay", "FocusOut"
}

// Notification pattern - unit type for no data
pub type WillSaveResponse = ();

pub struct WillSaveHandler {
    lsp_registry: Arc<LspRegistry>,
}

impl WillSaveHandler {
    pub fn new(registry: Arc<LspRegistry>) -> Self {
        Self {
            lsp_registry: registry,
        }
    }

    fn reason_to_lsp(&self, reason: &str) -> lsp_types::TextDocumentSaveReason {
        match reason {
            "Manual" => lsp_types::TextDocumentSaveReason::MANUAL,
            "AfterDelay" => lsp_types::TextDocumentSaveReason::AFTER_DELAY,
            "FocusOut" => lsp_types::TextDocumentSaveReason::FOCUS_OUT,
            _ => lsp_types::TextDocumentSaveReason::MANUAL,
        }
    }
}

#[async_trait]
impl Handler for WillSaveHandler {
    type Input = WillSaveRequest;
    type Output = WillSaveResponse;

    async fn handle(
        &self,
        _vim: &dyn vim::VimContext,
        input: Self::Input,
    ) -> Result<HandlerResult<Self::Output>> {
        // Detect language
        let language = match self.lsp_registry.detect_language(&input.file) {
            Some(lang) => lang,
            None => return Ok(HandlerResult::Empty),
        };

        // Ensure client exists
        if self
            .lsp_registry
            .get_client(&language, &input.file)
            .await
            .is_err()
        {
            return Ok(HandlerResult::Empty);
        }

        // Convert file path to URI
        let uri = match super::common::file_path_to_uri(&input.file) {
            Ok(uri) => uri,
            Err(_) => return Ok(HandlerResult::Empty),
        };

        // Send LSP willSave notification
        let params = lsp_types::WillSaveTextDocumentParams {
            text_document: lsp_types::TextDocumentIdentifier {
                uri: lsp_types::Url::parse(&uri)?,
            },
            reason: self.reason_to_lsp(&input.reason),
        };

        // willSave is a notification, not a request (no response expected)
        match self
            .lsp_registry
            .notify(&language, "textDocument/willSave", params)
            .await
        {
            Ok(_) => {
                debug!(
                    "WillSave notification sent for: {} (reason: {})",
                    input.file, input.reason
                );
            }
            Err(e) => {
                debug!("WillSave notification failed: {:?}", e);
            }
        }
        Ok(HandlerResult::Empty)
    }
}
