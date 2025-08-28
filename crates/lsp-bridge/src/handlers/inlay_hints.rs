use anyhow::Result;
use async_trait::async_trait;
use lsp_bridge::LspRegistry;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tracing::debug;
use vim::Handler;

#[derive(Debug, Deserialize)]
#[allow(dead_code)]
pub struct InlayHintsRequest {
    pub file: String,
    pub start_line: u32,
    pub end_line: u32,
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

// Linus-style: InlayHintsInfo 要么完整存在，要么不存在
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

    fn inlay_hint_kind_to_string(kind: Option<lsp_types::InlayHintKind>) -> Option<String> {
        kind.map(|k| match k {
            lsp_types::InlayHintKind::TYPE => "Type".to_string(),
            lsp_types::InlayHintKind::PARAMETER => "Parameter".to_string(),
            _ => "Unknown".to_string(),
        })
    }
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
        // Detect language
        let language = match self.lsp_registry.detect_language(&input.file) {
            Some(lang) => lang,
            None => return Ok(Some(None)), // Unsupported file type
        };

        // Ensure client exists
        if self
            .lsp_registry
            .get_client(&language, &input.file)
            .await
            .is_err()
        {
            return Ok(Some(None));
        }

        // Convert file path to URI
        let uri = match super::common::file_path_to_uri(&input.file) {
            Ok(uri) => uri,
            Err(_) => return Ok(Some(None)), // 处理了请求，但转换失败
        };

        // Make LSP inlay hints request
        let params = lsp_types::InlayHintParams {
            text_document: lsp_types::TextDocumentIdentifier {
                uri: lsp_types::Url::parse(&uri)?,
            },
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

        let response = match self
            .lsp_registry
            .request::<lsp_types::request::InlayHintRequest>(&language, params)
            .await
        {
            Ok(response) => response,
            Err(_) => return Ok(Some(None)), // 处理了请求，但 LSP 错误
        };

        debug!("inlay hints response: {:?}", response);

        let hints = match response {
            Some(hints) => hints,
            None => return Ok(Some(None)), // 处理了请求，但没有 inlay hints
        };

        if hints.is_empty() {
            return Ok(Some(None)); // 处理了请求，但没有提示
        }

        // Convert inlay hints
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
                    Self::inlay_hint_kind_to_string(hint.kind),
                    tooltip,
                )
            })
            .collect();

        Ok(Some(Some(InlayHintsInfo::new(result_hints))))
    }
}
