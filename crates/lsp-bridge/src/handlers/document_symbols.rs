use anyhow::Result;
use async_trait::async_trait;
use lsp_bridge::LspRegistry;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tracing::debug;
use vim::{Handler, HandlerResult};

use super::common::{symbol_kind_name, with_lsp_file, HasFile};

#[derive(Debug, Deserialize)]
#[allow(dead_code)]
pub struct DocumentSymbolsRequest {
    pub file: String,
}

impl HasFile for DocumentSymbolsRequest {
    fn file(&self) -> &str {
        &self.file
    }
}

#[derive(Debug, Serialize)]
pub struct Symbol {
    pub name: String,
    pub kind: String,
    pub range: Range,
    pub selection_range: Range,
    pub detail: Option<String>,
    pub children: Option<Vec<Symbol>>,
}

#[derive(Debug, Serialize)]
pub struct Range {
    pub start_line: u32,
    pub start_column: u32,
    pub end_line: u32,
    pub end_column: u32,
}

#[derive(Debug, Serialize)]
pub struct DocumentSymbolsInfo {
    pub symbols: Vec<Symbol>,
}

pub type DocumentSymbolsResponse = DocumentSymbolsInfo;

impl Range {
    pub fn new(start_line: u32, start_column: u32, end_line: u32, end_column: u32) -> Self {
        Self {
            start_line,
            start_column,
            end_line,
            end_column,
        }
    }

    pub fn from_lsp_range(range: lsp_types::Range) -> Self {
        Self::new(
            range.start.line,
            range.start.character,
            range.end.line,
            range.end.character,
        )
    }
}

impl Symbol {
    pub fn new(
        name: String,
        kind: String,
        range: Range,
        selection_range: Range,
        detail: Option<String>,
        children: Option<Vec<Symbol>>,
    ) -> Self {
        Self {
            name,
            kind,
            range,
            selection_range,
            detail,
            children,
        }
    }
}

impl DocumentSymbolsInfo {
    pub fn new(symbols: Vec<Symbol>) -> Self {
        Self { symbols }
    }
}

pub struct DocumentSymbolsHandler {
    lsp_registry: Arc<LspRegistry>,
}

impl DocumentSymbolsHandler {
    pub fn new(registry: Arc<LspRegistry>) -> Self {
        Self {
            lsp_registry: registry,
        }
    }

    fn symbol_kind_to_string(kind: lsp_types::SymbolKind) -> String {
        symbol_kind_name(kind).to_string()
    }

    fn convert_document_symbol(symbol: lsp_types::DocumentSymbol) -> Symbol {
        let children = symbol.children.map(|children| {
            children
                .into_iter()
                .map(Self::convert_document_symbol)
                .collect()
        });

        Symbol::new(
            symbol.name,
            Self::symbol_kind_to_string(symbol.kind),
            Range::from_lsp_range(symbol.range),
            Range::from_lsp_range(symbol.selection_range),
            symbol.detail,
            children,
        )
    }
}

#[async_trait]
impl Handler for DocumentSymbolsHandler {
    type Input = DocumentSymbolsRequest;
    type Output = DocumentSymbolsResponse;

    async fn handle(
        &self,
        _vim: &dyn vim::VimContext,
        input: Self::Input,
    ) -> Result<HandlerResult<Self::Output>> {
        with_lsp_file(&self.lsp_registry, input, |ctx, _input| async move {
            let params = lsp_types::DocumentSymbolParams {
                text_document: lsp_types::TextDocumentIdentifier { uri: ctx.uri },
                work_done_progress_params: Default::default(),
                partial_result_params: Default::default(),
            };

            let response = match ctx
                .registry
                .request::<lsp_types::request::DocumentSymbolRequest>(&ctx.language, params)
                .await
            {
                Ok(response) => response,
                Err(_) => return Ok(HandlerResult::Empty),
            };

            debug!("document symbols response: {:?}", response);

            let symbols: Vec<Symbol> = match response {
                Some(lsp_types::DocumentSymbolResponse::Flat(symbol_infos)) => symbol_infos
                    .into_iter()
                    .map(|info| {
                        Symbol::new(
                            info.name,
                            DocumentSymbolsHandler::symbol_kind_to_string(info.kind),
                            Range::from_lsp_range(info.location.range),
                            Range::from_lsp_range(info.location.range),
                            None,
                            None,
                        )
                    })
                    .collect(),
                Some(lsp_types::DocumentSymbolResponse::Nested(document_symbols)) => {
                    document_symbols
                        .into_iter()
                        .map(DocumentSymbolsHandler::convert_document_symbol)
                        .collect()
                }
                None => return Ok(HandlerResult::Empty),
            };

            if symbols.is_empty() {
                return Ok(HandlerResult::Empty);
            }

            Ok(HandlerResult::Data(DocumentSymbolsInfo::new(symbols)))
        })
        .await
    }
}
