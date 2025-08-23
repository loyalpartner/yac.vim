use anyhow::Result;
use async_trait::async_trait;
use lsp_client::LspClient;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tokio::sync::Mutex;
use tracing::debug;
use vim::Handler;

#[derive(Debug, Deserialize)]
#[allow(dead_code)]
pub struct CompletionRequest {
    pub file: String,
    pub line: u32,
    pub column: u32,
    pub trigger_character: Option<String>,
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

// Linus-style: CompletionInfo 要么完整存在，要么不存在
pub type CompletionResponse = Option<CompletionInfo>;

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
    lsp_client: Arc<Mutex<Option<LspClient>>>,
}

impl CompletionHandler {
    pub fn new(client: Arc<Mutex<Option<LspClient>>>) -> Self {
        Self { lsp_client: client }
    }

    fn completion_kind_to_string(kind: Option<lsp_types::CompletionItemKind>) -> Option<String> {
        kind.map(|k| match k {
            lsp_types::CompletionItemKind::TEXT => "Text".to_string(),
            lsp_types::CompletionItemKind::METHOD => "Method".to_string(),
            lsp_types::CompletionItemKind::FUNCTION => "Function".to_string(),
            lsp_types::CompletionItemKind::CONSTRUCTOR => "Constructor".to_string(),
            lsp_types::CompletionItemKind::FIELD => "Field".to_string(),
            lsp_types::CompletionItemKind::VARIABLE => "Variable".to_string(),
            lsp_types::CompletionItemKind::CLASS => "Class".to_string(),
            lsp_types::CompletionItemKind::INTERFACE => "Interface".to_string(),
            lsp_types::CompletionItemKind::MODULE => "Module".to_string(),
            lsp_types::CompletionItemKind::PROPERTY => "Property".to_string(),
            lsp_types::CompletionItemKind::UNIT => "Unit".to_string(),
            lsp_types::CompletionItemKind::VALUE => "Value".to_string(),
            lsp_types::CompletionItemKind::ENUM => "Enum".to_string(),
            lsp_types::CompletionItemKind::KEYWORD => "Keyword".to_string(),
            lsp_types::CompletionItemKind::SNIPPET => "Snippet".to_string(),
            lsp_types::CompletionItemKind::COLOR => "Color".to_string(),
            lsp_types::CompletionItemKind::FILE => "File".to_string(),
            lsp_types::CompletionItemKind::REFERENCE => "Reference".to_string(),
            lsp_types::CompletionItemKind::FOLDER => "Folder".to_string(),
            lsp_types::CompletionItemKind::ENUM_MEMBER => "EnumMember".to_string(),
            lsp_types::CompletionItemKind::CONSTANT => "Constant".to_string(),
            lsp_types::CompletionItemKind::STRUCT => "Struct".to_string(),
            lsp_types::CompletionItemKind::EVENT => "Event".to_string(),
            lsp_types::CompletionItemKind::OPERATOR => "Operator".to_string(),
            lsp_types::CompletionItemKind::TYPE_PARAMETER => "TypeParameter".to_string(),
            _ => "Unknown".to_string(),
        })
    }
}

#[async_trait]
impl Handler for CompletionHandler {
    type Input = CompletionRequest;
    type Output = CompletionResponse;

    async fn handle(&self, input: Self::Input) -> Result<Option<Self::Output>> {
        let client_lock = self.lsp_client.lock().await;
        let client = client_lock.as_ref().unwrap();

        // Convert file path to URI
        let uri = match super::common::file_path_to_uri(&input.file) {
            Ok(uri) => uri,
            Err(_) => return Ok(Some(None)), // 处理了请求，但转换失败
        };

        // Make LSP completion request
        let mut params = lsp_types::CompletionParams {
            text_document_position: lsp_types::TextDocumentPositionParams {
                text_document: lsp_types::TextDocumentIdentifier {
                    uri: lsp_types::Url::parse(&uri)?,
                },
                position: lsp_types::Position {
                    line: input.line,
                    character: input.column,
                },
            },
            work_done_progress_params: Default::default(),
            partial_result_params: Default::default(),
            context: None,
        };

        // Set trigger context if provided
        if let Some(trigger_char) = input.trigger_character {
            params.context = Some(lsp_types::CompletionContext {
                trigger_kind: lsp_types::CompletionTriggerKind::TRIGGER_CHARACTER,
                trigger_character: Some(trigger_char),
            });
        }

        let response = match client
            .request::<lsp_types::request::Completion>(params)
            .await
        {
            Ok(response) => response,
            Err(_) => return Ok(Some(None)), // 处理了请求，但 LSP 错误
        };

        debug!("completion response: {:?}", response);

        let (items, is_incomplete) = match response {
            Some(lsp_types::CompletionResponse::Array(items)) => (items, false),
            Some(lsp_types::CompletionResponse::List(list)) => (list.items, list.is_incomplete),
            None => return Ok(Some(None)), // 处理了请求，但没有补全
        };

        if items.is_empty() {
            return Ok(Some(None)); // 处理了请求，但没有补全项
        }

        // Convert completion items
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
                    Self::completion_kind_to_string(item.kind),
                    item.detail,
                    documentation,
                    insert_text,
                )
            })
            .collect();

        Ok(Some(Some(CompletionInfo::new(result_items, is_incomplete))))
    }
}
