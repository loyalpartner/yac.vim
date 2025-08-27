use anyhow::Result;
use async_trait::async_trait;
use lsp_bridge::LspRegistry;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tracing::debug;
use vim::Handler;

#[derive(Debug, Deserialize)]
#[allow(dead_code)]
pub struct CallHierarchyRequest {
    pub file: String,
    pub line: u32,
    pub column: u32,
    pub direction: String, // "incoming" or "outgoing"
}

#[derive(Debug, Serialize)]
pub struct CallHierarchyItem {
    pub name: String,
    pub kind: String,
    pub detail: Option<String>,
    pub file: String,
    pub selection_line: u32,
    pub selection_column: u32,
}

#[derive(Debug, Serialize)]
pub struct CallHierarchyInfo {
    pub items: Vec<CallHierarchyItem>,
}

// Linus-style: CallHierarchyInfo 要么完整存在，要么不存在
pub type CallHierarchyResponse = Option<CallHierarchyInfo>;

impl CallHierarchyItem {
    pub fn new(
        name: String,
        kind: String,
        detail: Option<String>,
        file: String,
        selection_line: u32,
        selection_column: u32,
    ) -> Self {
        Self {
            name,
            kind,
            detail,
            file,
            selection_line,
            selection_column,
        }
    }

    pub fn from_lsp_item(item: lsp_types::CallHierarchyItem) -> Result<Self> {
        let kind = match item.kind {
            lsp_types::SymbolKind::FUNCTION => "Function".to_string(),
            lsp_types::SymbolKind::METHOD => "Method".to_string(),
            lsp_types::SymbolKind::CONSTRUCTOR => "Constructor".to_string(),
            lsp_types::SymbolKind::CLASS => "Class".to_string(),
            lsp_types::SymbolKind::MODULE => "Module".to_string(),
            _ => "Unknown".to_string(),
        };

        // Convert URI to file path
        let file_path = super::common::uri_to_file_path(item.uri.as_ref())?;

        Ok(Self::new(
            item.name,
            kind,
            item.detail,
            file_path,
            item.selection_range.start.line,
            item.selection_range.start.character,
        ))
    }
}

impl CallHierarchyInfo {
    pub fn new(items: Vec<CallHierarchyItem>) -> Self {
        Self { items }
    }
}

pub struct CallHierarchyHandler {
    lsp_registry: Arc<LspRegistry>,
}

impl CallHierarchyHandler {
    pub fn new(registry: Arc<LspRegistry>) -> Self {
        Self {
            lsp_registry: registry,
        }
    }
}

#[async_trait]
impl Handler for CallHierarchyHandler {
    type Input = CallHierarchyRequest;
    type Output = CallHierarchyResponse;

    async fn handle(
        &self,
        _sender: &vim::ChannelCommandSender,
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

        // First, prepare call hierarchy items
        let prepare_params = lsp_types::CallHierarchyPrepareParams {
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

        let prepare_response = match self
            .lsp_registry
            .request::<lsp_types::request::CallHierarchyPrepare>(&language, prepare_params)
            .await
        {
            Ok(response) => response,
            Err(_) => return Ok(Some(None)), // 处理了请求，但 LSP 错误
        };

        let items = match prepare_response {
            Some(items) => items,
            None => return Ok(Some(None)), // 处理了请求，但没有调用层次结构项
        };

        if items.is_empty() {
            return Ok(Some(None)); // 处理了请求，但没有调用层次结构项
        }

        // Use the first item for incoming/outgoing calls
        let item = &items[0];

        let items = match input.direction.as_str() {
            "incoming" => {
                let params = lsp_types::CallHierarchyIncomingCallsParams {
                    item: item.clone(),
                    work_done_progress_params: Default::default(),
                    partial_result_params: Default::default(),
                };

                match self
                    .lsp_registry
                    .request::<lsp_types::request::CallHierarchyIncomingCalls>(&language, params)
                    .await
                {
                    Ok(Some(calls)) => calls
                        .into_iter()
                        .filter_map(|call| CallHierarchyItem::from_lsp_item(call.from).ok())
                        .collect(),
                    _ => Vec::new(),
                }
            }
            "outgoing" => {
                let params = lsp_types::CallHierarchyOutgoingCallsParams {
                    item: item.clone(),
                    work_done_progress_params: Default::default(),
                    partial_result_params: Default::default(),
                };

                match self
                    .lsp_registry
                    .request::<lsp_types::request::CallHierarchyOutgoingCalls>(&language, params)
                    .await
                {
                    Ok(Some(calls)) => calls
                        .into_iter()
                        .filter_map(|call| CallHierarchyItem::from_lsp_item(call.to).ok())
                        .collect(),
                    _ => Vec::new(),
                }
            }
            _ => {
                debug!("Invalid call hierarchy direction: {}", input.direction);
                return Ok(Some(None)); // 处理了请求，但方向无效
            }
        };

        debug!(
            "{} call hierarchy response: {} items",
            input.direction,
            items.len()
        );

        if items.is_empty() {
            return Ok(Some(None)); // 处理了请求，但没有调用
        }

        Ok(Some(Some(CallHierarchyInfo::new(items))))
    }
}
