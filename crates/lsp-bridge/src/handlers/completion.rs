use anyhow::Result;
use async_trait::async_trait;
use lsp_bridge::LspRegistry;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tracing::debug;
use vim::{Handler, HandlerResult};

use super::common::{with_lsp_context, HasFilePosition};

#[derive(Debug, Deserialize)]
#[allow(dead_code)]
pub struct CompletionRequest {
    pub file: String,
    pub line: u32,
    pub column: u32,
    pub trigger_character: Option<String>,
}

impl HasFilePosition for CompletionRequest {
    fn file(&self) -> &str {
        &self.file
    }
    fn line(&self) -> u32 {
        self.line
    }
    fn column(&self) -> u32 {
        self.column
    }
}

#[derive(Debug, Serialize)]
pub struct CompletionItem {
    pub label: String,
    pub kind: Option<String>,
    pub detail: Option<String>,
    pub documentation: Option<String>,
    pub insert_text: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct CompletionInfo {
    pub items: Vec<CompletionItem>,
    pub is_incomplete: bool,
}

pub type CompletionResponse = CompletionInfo;

impl CompletionItem {
    pub fn new(
        label: String,
        kind: Option<String>,
        detail: Option<String>,
        documentation: Option<String>,
        insert_text: Option<String>,
    ) -> Self {
        Self {
            label,
            kind,
            detail,
            documentation,
            insert_text,
        }
    }
}

impl CompletionInfo {
    pub fn new(items: Vec<CompletionItem>, is_incomplete: bool) -> Self {
        Self {
            items,
            is_incomplete,
        }
    }
}

pub struct CompletionHandler {
    lsp_registry: Arc<LspRegistry>,
}

impl CompletionHandler {
    pub fn new(registry: Arc<LspRegistry>) -> Self {
        Self {
            lsp_registry: registry,
        }
    }
}

fn completion_kind_to_string(kind: Option<lsp_types::CompletionItemKind>) -> Option<String> {
    kind.map(|k| {
        match k {
            lsp_types::CompletionItemKind::TEXT => "Text",
            lsp_types::CompletionItemKind::METHOD => "Method",
            lsp_types::CompletionItemKind::FUNCTION => "Function",
            lsp_types::CompletionItemKind::CONSTRUCTOR => "Constructor",
            lsp_types::CompletionItemKind::FIELD => "Field",
            lsp_types::CompletionItemKind::VARIABLE => "Variable",
            lsp_types::CompletionItemKind::CLASS => "Class",
            lsp_types::CompletionItemKind::INTERFACE => "Interface",
            lsp_types::CompletionItemKind::MODULE => "Module",
            lsp_types::CompletionItemKind::PROPERTY => "Property",
            lsp_types::CompletionItemKind::UNIT => "Unit",
            lsp_types::CompletionItemKind::VALUE => "Value",
            lsp_types::CompletionItemKind::ENUM => "Enum",
            lsp_types::CompletionItemKind::KEYWORD => "Keyword",
            lsp_types::CompletionItemKind::SNIPPET => "Snippet",
            lsp_types::CompletionItemKind::COLOR => "Color",
            lsp_types::CompletionItemKind::FILE => "File",
            lsp_types::CompletionItemKind::REFERENCE => "Reference",
            lsp_types::CompletionItemKind::FOLDER => "Folder",
            lsp_types::CompletionItemKind::ENUM_MEMBER => "EnumMember",
            lsp_types::CompletionItemKind::CONSTANT => "Constant",
            lsp_types::CompletionItemKind::STRUCT => "Struct",
            lsp_types::CompletionItemKind::EVENT => "Event",
            lsp_types::CompletionItemKind::OPERATOR => "Operator",
            lsp_types::CompletionItemKind::TYPE_PARAMETER => "TypeParameter",
            _ => "Unknown",
        }
        .to_string()
    })
}

#[async_trait]
impl Handler for CompletionHandler {
    type Input = CompletionRequest;
    type Output = CompletionResponse;

    async fn handle(
        &self,
        _vim: &dyn vim::VimContext,
        input: Self::Input,
    ) -> Result<HandlerResult<Self::Output>> {
        with_lsp_context(&self.lsp_registry, input, |ctx, input| async move {
            let mut params = lsp_types::CompletionParams {
                text_document_position: lsp_types::TextDocumentPositionParams {
                    text_document: lsp_types::TextDocumentIdentifier { uri: ctx.uri },
                    position: lsp_types::Position {
                        line: input.line,
                        character: input.column,
                    },
                },
                work_done_progress_params: Default::default(),
                partial_result_params: Default::default(),
                context: None,
            };

            if let Some(trigger_char) = input.trigger_character {
                params.context = Some(lsp_types::CompletionContext {
                    trigger_kind: lsp_types::CompletionTriggerKind::TRIGGER_CHARACTER,
                    trigger_character: Some(trigger_char),
                });
            }

            let response = ctx
                .registry
                .request::<lsp_types::request::Completion>(&ctx.language, params)
                .await
                .ok()
                .flatten();

            debug!("completion response: {:?}", response);

            let (items, is_incomplete) = match response {
                Some(lsp_types::CompletionResponse::Array(items)) => (items, false),
                Some(lsp_types::CompletionResponse::List(list)) => (list.items, list.is_incomplete),
                None => return Ok(HandlerResult::Empty),
            };

            if items.is_empty() {
                return Ok(HandlerResult::Empty);
            }

            let result_items: Vec<CompletionItem> = items
                .into_iter()
                .map(|item| {
                    let documentation = match item.documentation {
                        Some(lsp_types::Documentation::String(s)) => Some(s),
                        Some(lsp_types::Documentation::MarkupContent(markup)) => Some(markup.value),
                        None => None,
                    };

                    let insert_text = item.insert_text.or_else(|| Some(item.label.clone()));

                    CompletionItem::new(
                        item.label,
                        completion_kind_to_string(item.kind),
                        item.detail,
                        documentation,
                        insert_text,
                    )
                })
                .collect();

            Ok(HandlerResult::Data(CompletionInfo::new(
                result_items,
                is_incomplete,
            )))
        })
        .await
    }
}
