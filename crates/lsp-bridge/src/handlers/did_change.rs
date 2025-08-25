use anyhow::Result;
use async_trait::async_trait;
use lsp_bridge::LspRegistry;
use serde::Deserialize;
use std::sync::Arc;
use tracing::debug;
use vim::Handler;

#[derive(Debug, Deserialize)]
#[allow(dead_code)]
pub struct DidChangeRequest {
    pub file: String,
    pub version: u32,
    pub changes: Vec<TextDocumentContentChangeEvent>,
}

#[derive(Debug, Deserialize)]
pub struct TextDocumentContentChangeEvent {
    pub range: Option<Range>,
    pub range_length: Option<u32>,
    pub text: String,
}

#[derive(Debug, Deserialize)]
pub struct Range {
    pub start_line: u32,
    pub start_column: u32,
    pub end_line: u32,
    pub end_column: u32,
}

// Notification pattern - no response data needed
pub type DidChangeResponse = Option<()>;

impl Range {
    pub fn to_lsp_range(&self) -> lsp_types::Range {
        lsp_types::Range {
            start: lsp_types::Position {
                line: self.start_line,
                character: self.start_column,
            },
            end: lsp_types::Position {
                line: self.end_line,
                character: self.end_column,
            },
        }
    }
}

impl TextDocumentContentChangeEvent {
    pub fn to_lsp_change_event(&self) -> lsp_types::TextDocumentContentChangeEvent {
        lsp_types::TextDocumentContentChangeEvent {
            range: self.range.as_ref().map(|r| r.to_lsp_range()),
            range_length: self.range_length,
            text: self.text.clone(),
        }
    }
}

pub struct DidChangeHandler {
    lsp_registry: Arc<LspRegistry>,
}

impl DidChangeHandler {
    pub fn new(registry: Arc<LspRegistry>) -> Self {
        Self {
            lsp_registry: registry,
        }
    }
}

#[async_trait]
impl Handler for DidChangeHandler {
    type Input = DidChangeRequest;
    type Output = DidChangeResponse;

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

        // Convert changes to LSP format
        let content_changes: Vec<lsp_types::TextDocumentContentChangeEvent> = input
            .changes
            .into_iter()
            .map(|change| change.to_lsp_change_event())
            .collect();

        // Send LSP didChange notification
        let params = lsp_types::DidChangeTextDocumentParams {
            text_document: lsp_types::VersionedTextDocumentIdentifier {
                uri: lsp_types::Url::parse(&uri)?,
                version: input.version as i32,
            },
            content_changes,
        };

        // didChange is a notification, not a request (no response expected)
        match self
            .lsp_registry
            .notify(&language, "textDocument/didChange", params)
            .await
        {
            Ok(_) => {
                debug!(
                    "DidChange notification sent for: {} (version {})",
                    input.file, input.version
                );
                Ok(None) // Notification pattern - no response needed
            }
            Err(e) => {
                debug!("DidChange notification failed: {:?}", e);
                Ok(None) // Notification pattern - ignore errors
            }
        }
    }
}
