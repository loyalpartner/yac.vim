use anyhow::Result;
use async_trait::async_trait;
use lsp_bridge::LspRegistry;
use serde::Deserialize;
use std::sync::Arc;
use tracing::debug;
use vim::{Handler, HandlerResult};

use super::common::{with_lsp_file, HasFile};

#[derive(Debug, Deserialize)]
#[allow(dead_code)]
pub struct DidChangeRequest {
    pub file: String,
    pub version: u32,
    pub changes: Vec<TextDocumentContentChangeEvent>,
}

impl HasFile for DidChangeRequest {
    fn file(&self) -> &str {
        &self.file
    }
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

pub type DidChangeResponse = ();

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
        _vim: &dyn vim::VimContext,
        input: Self::Input,
    ) -> Result<HandlerResult<Self::Output>> {
        with_lsp_file(&self.lsp_registry, input, |ctx, input| async move {
            let content_changes: Vec<lsp_types::TextDocumentContentChangeEvent> = input
                .changes
                .into_iter()
                .map(|change| change.to_lsp_change_event())
                .collect();

            let params = lsp_types::DidChangeTextDocumentParams {
                text_document: lsp_types::VersionedTextDocumentIdentifier {
                    uri: ctx.uri,
                    version: input.version as i32,
                },
                content_changes,
            };

            match ctx
                .registry
                .notify(&ctx.language, "textDocument/didChange", params)
                .await
            {
                Ok(_) => debug!(
                    "DidChange notification sent for: {} (version {})",
                    input.file, input.version
                ),
                Err(e) => debug!("DidChange notification failed: {:?}", e),
            }
            Ok(HandlerResult::Empty)
        })
        .await
    }
}
