use anyhow::Result;
use async_trait::async_trait;
use lsp_bridge::LspRegistry;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tracing::debug;
use vim::{Handler, HandlerResult};

use super::common::{with_lsp_file, HasFile, HasFilePosition};

#[derive(Debug, Deserialize)]
#[allow(dead_code)]
pub struct CallHierarchyRequest {
    pub file: String,
    pub line: u32,
    pub column: u32,
    pub direction: String,
}

impl HasFile for CallHierarchyRequest {
    fn file(&self) -> &str {
        &self.file
    }
}

impl HasFilePosition for CallHierarchyRequest {
    fn line(&self) -> u32 {
        self.line
    }
    fn column(&self) -> u32 {
        self.column
    }
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

pub type CallHierarchyResponse = CallHierarchyInfo;

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
        let kind = super::common::symbol_kind_name(item.kind).to_string();

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
        _vim: &dyn vim::VimContext,
        input: Self::Input,
    ) -> Result<HandlerResult<Self::Output>> {
        with_lsp_file(&self.lsp_registry, input, |ctx, input| async move {
            let prepare_params = lsp_types::CallHierarchyPrepareParams {
                text_document_position_params: lsp_types::TextDocumentPositionParams {
                    text_document: lsp_types::TextDocumentIdentifier { uri: ctx.uri },
                    position: lsp_types::Position {
                        line: input.line,
                        character: input.column,
                    },
                },
                work_done_progress_params: Default::default(),
            };

            let prepare_response = match ctx
                .registry
                .request::<lsp_types::request::CallHierarchyPrepare>(&ctx.language, prepare_params)
                .await
            {
                Ok(response) => response,
                Err(_) => return Ok(HandlerResult::Empty),
            };

            let prepared = match prepare_response {
                Some(items) if !items.is_empty() => items,
                _ => return Ok(HandlerResult::Empty),
            };

            let item = &prepared[0];

            let items = match input.direction.as_str() {
                "incoming" => {
                    let params = lsp_types::CallHierarchyIncomingCallsParams {
                        item: item.clone(),
                        work_done_progress_params: Default::default(),
                        partial_result_params: Default::default(),
                    };
                    match ctx
                        .registry
                        .request::<lsp_types::request::CallHierarchyIncomingCalls>(
                            &ctx.language,
                            params,
                        )
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
                    match ctx
                        .registry
                        .request::<lsp_types::request::CallHierarchyOutgoingCalls>(
                            &ctx.language,
                            params,
                        )
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
                    return Ok(HandlerResult::Empty);
                }
            };

            debug!(
                "{} call hierarchy response: {} items",
                input.direction,
                items.len()
            );

            if items.is_empty() {
                return Ok(HandlerResult::Empty);
            }

            Ok(HandlerResult::Data(CallHierarchyInfo::new(items)))
        })
        .await
    }
}
