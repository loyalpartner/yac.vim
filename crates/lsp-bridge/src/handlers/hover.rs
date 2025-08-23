use anyhow::Result;
use async_trait::async_trait;
use lsp_bridge::LspRegistry;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tracing::debug;
use vim::Handler;

use super::common;

#[derive(Debug, Deserialize)]
#[allow(dead_code)]
pub struct HoverRequest {
    pub file: String,
    pub line: u32,
    pub column: u32,
}

#[derive(Debug, Serialize)]
pub struct HoverInfo {
    pub content: String,
}

// Linus-style: HoverInfo 要么完整存在，要么不存在
pub type HoverResponse = Option<HoverInfo>;

impl HoverInfo {
    pub fn new(content: String) -> Self {
        Self { content }
    }
}

pub struct HoverHandler {
    lsp_registry: Arc<LspRegistry>,
}

impl HoverHandler {
    pub fn new(registry: Arc<LspRegistry>) -> Self {
        Self {
            lsp_registry: registry,
        }
    }
}

#[async_trait]
impl Handler for HoverHandler {
    type Input = HoverRequest;
    type Output = HoverResponse;

    async fn handle(
        &self,
        _ctx: &mut dyn vim::VimContext,
        input: Self::Input,
    ) -> Result<Option<Self::Output>> {
        // Detect language
        let language = match self.lsp_registry.detect_language(&input.file) {
            Some(lang) => lang,
            None => return Ok(None), // Unsupported file type
        };

        // Ensure client exists
        if let Err(_) = self.lsp_registry.get_client(&language, &input.file).await {
            return Ok(None);
        }

        // Convert file path to URI
        let uri = match common::file_path_to_uri(&input.file) {
            Ok(uri) => uri,
            Err(_) => return Ok(None),
        };

        // Make LSP hover request
        let params = lsp_types::HoverParams {
            text_document_position_params: lsp_types::TextDocumentPositionParams {
                text_document: lsp_types::TextDocumentIdentifier {
                    uri: lsp_types::Url::parse(&uri)?,
                },
                position: lsp_types::Position {
                    line: input.line,
                    character: input.column,
                },
            },
            work_done_progress_params: Default::default(),
        };

        let response = match self
            .lsp_registry
            .request::<lsp_types::request::HoverRequest>(&language, params)
            .await
        {
            Ok(response) => response,
            Err(_) => return Ok(None),
        };

        debug!("hover response: {:?}", response);

        let hover = match response {
            Some(hover) => hover,
            None => return Ok(None), // No hover information
        };

        // Extract content from hover response
        let content = match hover.contents {
            lsp_types::HoverContents::Scalar(marked_string) => match marked_string {
                lsp_types::MarkedString::String(s) => s,
                lsp_types::MarkedString::LanguageString(lang_string) => lang_string.value,
            },
            lsp_types::HoverContents::Array(marked_strings) => marked_strings
                .into_iter()
                .map(|ms| match ms {
                    lsp_types::MarkedString::String(s) => s,
                    lsp_types::MarkedString::LanguageString(lang_string) => lang_string.value,
                })
                .collect::<Vec<_>>()
                .join("\n"),
            lsp_types::HoverContents::Markup(markup) => markup.value,
        };

        Ok(Some(Some(HoverInfo::new(content))))
    }
}
