use anyhow::Result;
use async_trait::async_trait;
use lsp_bridge::LspRegistry;
use serde::{Deserialize, Serialize};
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

#[derive(Debug, Serialize)]
pub struct DidChangeResult {
    pub success: bool,
}

// Linus-style: DidChangeResult 要么完整存在，要么不存在
pub type DidChangeResponse = Option<DidChangeResult>;

impl DidChangeResult {
    pub fn new(success: bool) -> Self {
        Self { success }
    }
}

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
            None => return Ok(Some(Some(DidChangeResult::new(false)))), // Unsupported file type
        };

        // Ensure client exists
        if let Err(_) = self.lsp_registry.get_client(&language, &input.file).await {
            return Ok(Some(Some(DidChangeResult::new(false))));
        }

        // Convert file path to URI
        let uri = match super::common::file_path_to_uri(&input.file) {
            Ok(uri) => uri,
            Err(_) => return Ok(Some(Some(DidChangeResult::new(false)))), // 处理了请求，但转换失败
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
                Ok(Some(Some(DidChangeResult::new(true))))
            }
            Err(e) => {
                debug!("DidChange notification failed: {:?}", e);
                Ok(Some(Some(DidChangeResult::new(false))))
            }
        }
    }
}
