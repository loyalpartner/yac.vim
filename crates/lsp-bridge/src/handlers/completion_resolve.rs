use anyhow::Result;
use async_trait::async_trait;
use lsp_bridge::LspRegistry;
use serde::Deserialize;
use std::sync::Arc;
use tracing::debug;
use vim::Handler;

use super::completion::{CompletionItem, Position, TextEdit, TextRange};

#[derive(Debug, Deserialize)]
pub struct CompletionResolveRequest {
    pub item: CompletionItem,
    pub file: String,
}

pub type CompletionResolveResponse = Option<CompletionItem>;

pub struct CompletionResolveHandler {
    lsp_registry: Arc<LspRegistry>,
}

impl CompletionResolveHandler {
    pub fn new(registry: Arc<LspRegistry>) -> Self {
        Self {
            lsp_registry: registry,
        }
    }

    fn convert_text_edit(edit: &lsp_types::TextEdit) -> TextEdit {
        TextEdit {
            range: TextRange {
                start: Position {
                    line: edit.range.start.line,
                    character: edit.range.start.character,
                },
                end: Position {
                    line: edit.range.end.line,
                    character: edit.range.end.character,
                },
            },
            new_text: edit.new_text.clone(),
        }
    }
}

#[async_trait]
impl Handler for CompletionResolveHandler {
    type Input = CompletionResolveRequest;
    type Output = CompletionResolveResponse;

    async fn handle(
        &self,
        _ctx: &mut dyn vim::VimContext,
        input: Self::Input,
    ) -> Result<Option<Self::Output>> {
        // Detect language from file
        let language = match self.lsp_registry.detect_language(&input.file) {
            Some(lang) => lang,
            None => return Ok(None),
        };

        // Ensure LSP client exists
        if self
            .lsp_registry
            .get_client(&language, &input.file)
            .await
            .is_err()
        {
            return Ok(None);
        }

        // Check if item has data for resolution
        let data = match &input.item.data {
            Some(data) => data.clone(),
            None => return Ok(Some(Some(input.item))), // No resolution needed
        };

        // Create LSP completion item for resolution
        let lsp_item = lsp_types::CompletionItem {
            label: input.item.label.clone(),
            kind: None, // Kind not needed for resolution
            detail: input.item.detail.clone(),
            documentation: input
                .item
                .documentation
                .as_ref()
                .map(|d| lsp_types::Documentation::String(d.clone())),
            deprecated: None,
            preselect: None,
            sort_text: None,
            filter_text: None,
            insert_text: input.item.insert_text.clone(),
            insert_text_format: None,
            insert_text_mode: None,
            text_edit: None,
            additional_text_edits: None,
            command: None,
            commit_characters: None,
            data: Some(data),
            tags: None,
            label_details: None,
        };

        debug!("Resolving completion item: {:?}", lsp_item.label);

        // Make resolve request to LSP server
        let resolved_item = match self
            .lsp_registry
            .request::<lsp_types::request::ResolveCompletionItem>(&language, lsp_item)
            .await
        {
            Ok(item) => item,
            Err(e) => {
                debug!("Completion resolve failed: {}", e);
                return Ok(Some(Some(input.item))); // Return original item on error
            }
        };

        debug!("Resolved completion item: {:?}", resolved_item);

        // Convert additional text edits
        let additional_text_edits = resolved_item.additional_text_edits.map(|edits| {
            edits
                .into_iter()
                .map(|edit| Self::convert_text_edit(&edit))
                .collect()
        });

        // Update documentation if provided
        let documentation = match resolved_item.documentation {
            Some(lsp_types::Documentation::String(s)) => Some(s),
            Some(lsp_types::Documentation::MarkupContent(markup)) => Some(markup.value),
            None => input.item.documentation,
        };

        // Create resolved completion item
        let resolved = CompletionItem {
            label: input.item.label,
            kind: input.item.kind,
            detail: resolved_item.detail.or(input.item.detail),
            documentation,
            insert_text: resolved_item.insert_text.or(input.item.insert_text),
            data: input.item.data,
            additional_text_edits,
        };

        Ok(Some(Some(resolved)))
    }
}
