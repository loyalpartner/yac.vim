use anyhow::Result;
use async_trait::async_trait;
use lsp_bridge::LspRegistry;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tracing::debug;
use vim::Handler;

use super::common::{with_lsp_context, HasFilePosition};

#[derive(Debug, Deserialize)]
#[allow(dead_code)]
pub struct InlayHintsRequest {
    pub file: String,
    pub start_line: u32,
    pub end_line: u32,
}

impl HasFilePosition for InlayHintsRequest {
    fn file(&self) -> &str {
        &self.file
    }
    fn line(&self) -> u32 {
        self.start_line
    }
    fn column(&self) -> u32 {
        0
    }
}

#[derive(Debug, Serialize)]
pub struct InlayHint {
    pub line: u32,
    pub column: u32,
    pub label: String,
    pub kind: Option<String>,
    pub tooltip: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct InlayHintsInfo {
    pub hints: Vec<InlayHint>,
}

pub type InlayHintsResponse = Option<InlayHintsInfo>;

impl InlayHint {
    pub fn new(
        line: u32,
        column: u32,
        label: String,
        kind: Option<String>,
        tooltip: Option<String>,
    ) -> Self {
        Self {
            line,
            column,
            label,
            kind,
            tooltip,
        }
    }
}

impl InlayHintsInfo {
    pub fn new(hints: Vec<InlayHint>) -> Self {
        Self { hints }
    }
}

pub struct InlayHintsHandler {
    lsp_registry: Arc<LspRegistry>,
}

impl InlayHintsHandler {
    pub fn new(registry: Arc<LspRegistry>) -> Self {
        Self {
            lsp_registry: registry,
        }
    }
}

fn inlay_hint_kind_to_string(kind: Option<lsp_types::InlayHintKind>) -> Option<String> {
    kind.map(|k| match k {
        lsp_types::InlayHintKind::TYPE => "Type",
        lsp_types::InlayHintKind::PARAMETER => "Parameter",
        _ => "Unknown",
    }
    .to_string())
}

#[async_trait]
impl Handler for InlayHintsHandler {
    type Input = InlayHintsRequest;
    type Output = InlayHintsResponse;

    async fn handle(
        &self,
        _vim: &dyn vim::VimContext,
        input: Self::Input,
    ) -> Result<Option<Self::Output>> {
        with_lsp_context(&self.lsp_registry, input, |ctx, input| async move {
            let params = lsp_types::InlayHintParams {
                text_document: lsp_types::TextDocumentIdentifier { uri: ctx.uri },
                range: lsp_types::Range {
                    start: lsp_types::Position {
                        line: input.start_line,
                        character: 0,
                    },
                    end: lsp_types::Position {
                        line: input.end_line,
                        character: 0,
                    },
                },
                work_done_progress_params: Default::default(),
            };

            let hints = ctx
                .registry
                .request::<lsp_types::request::InlayHintRequest>(&ctx.language, params)
                .await
                .ok()
                .flatten()
                .unwrap_or_default();

            debug!("inlay hints response: {:?}", hints);

            if hints.is_empty() {
                return Ok(Some(None));
            }

            let result_hints: Vec<InlayHint> = hints
                .into_iter()
                .map(|hint| {
                    let label = match hint.label {
                        lsp_types::InlayHintLabel::String(s) => s,
                        lsp_types::InlayHintLabel::LabelParts(parts) => parts
                            .into_iter()
                            .map(|part| part.value)
                            .collect::<Vec<_>>()
                            .join(""),
                    };

                    let tooltip = hint.tooltip.map(|t| match t {
                        lsp_types::InlayHintTooltip::String(s) => s,
                        lsp_types::InlayHintTooltip::MarkupContent(markup) => markup.value,
                    });

                    InlayHint::new(
                        hint.position.line,
                        hint.position.character,
                        label,
                        inlay_hint_kind_to_string(hint.kind),
                        tooltip,
                    )
                })
                .collect();

            Ok(Some(Some(InlayHintsInfo::new(result_hints))))
        })
        .await
    }
}
