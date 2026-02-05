use anyhow::Result;
use async_trait::async_trait;
use lsp_bridge::LspRegistry;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tracing::debug;
use vim::{Handler, HandlerResult};

use super::common::{with_lsp_context, HasFile, HasFilePosition};

#[derive(Debug, Deserialize)]
#[allow(dead_code)]
pub struct HoverRequest {
    pub file: String,
    pub line: u32,
    pub column: u32,
}

impl HasFile for HoverRequest {
    fn file(&self) -> &str {
        &self.file
    }
}

impl HasFilePosition for HoverRequest {
    fn line(&self) -> u32 {
        self.line
    }
    fn column(&self) -> u32 {
        self.column
    }
}

#[derive(Debug, Serialize)]
pub struct HoverInfo {
    pub content: String,
}

pub type HoverResponse = HoverInfo;

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
        _vim: &dyn vim::VimContext,
        input: Self::Input,
    ) -> Result<HandlerResult<Self::Output>> {
        with_lsp_context(&self.lsp_registry, input, |ctx, input| async move {
            // Make LSP hover request
            let params = lsp_types::HoverParams {
                text_document_position_params: lsp_types::TextDocumentPositionParams {
                    text_document: lsp_types::TextDocumentIdentifier { uri: ctx.uri },
                    position: lsp_types::Position {
                        line: input.line,
                        character: input.column,
                    },
                },
                work_done_progress_params: Default::default(),
            };

            let response = ctx
                .registry
                .request::<lsp_types::request::HoverRequest>(&ctx.language, params)
                .await
                .ok()
                .flatten();

            let hover = match response {
                Some(hover) => hover,
                None => return Ok(HandlerResult::Empty),
            };

            debug!("hover response: {:?}", hover);

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

            Ok(HandlerResult::Data(HoverInfo::new(content)))
        })
        .await
    }
}
