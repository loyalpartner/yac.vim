use anyhow::Result;
use async_trait::async_trait;
use lsp_bridge::LspRegistry;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tracing::debug;
use vim::Handler;

#[derive(Debug, Deserialize)]
#[allow(dead_code)]
pub struct DocumentSymbolsRequest {
    pub file: String,
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

// Linus-style: DocumentSymbolsInfo 要么完整存在，要么不存在
pub type DocumentSymbolsResponse = Option<DocumentSymbolsInfo>;

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

#[derive(Clone)]
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
        match kind {
            lsp_types::SymbolKind::FILE => "File".to_string(),
            lsp_types::SymbolKind::MODULE => "Module".to_string(),
            lsp_types::SymbolKind::NAMESPACE => "Namespace".to_string(),
            lsp_types::SymbolKind::PACKAGE => "Package".to_string(),
            lsp_types::SymbolKind::CLASS => "Class".to_string(),
            lsp_types::SymbolKind::METHOD => "Method".to_string(),
            lsp_types::SymbolKind::PROPERTY => "Property".to_string(),
            lsp_types::SymbolKind::FIELD => "Field".to_string(),
            lsp_types::SymbolKind::CONSTRUCTOR => "Constructor".to_string(),
            lsp_types::SymbolKind::ENUM => "Enum".to_string(),
            lsp_types::SymbolKind::INTERFACE => "Interface".to_string(),
            lsp_types::SymbolKind::FUNCTION => "Function".to_string(),
            lsp_types::SymbolKind::VARIABLE => "Variable".to_string(),
            lsp_types::SymbolKind::CONSTANT => "Constant".to_string(),
            lsp_types::SymbolKind::STRING => "String".to_string(),
            lsp_types::SymbolKind::NUMBER => "Number".to_string(),
            lsp_types::SymbolKind::BOOLEAN => "Boolean".to_string(),
            lsp_types::SymbolKind::ARRAY => "Array".to_string(),
            lsp_types::SymbolKind::OBJECT => "Object".to_string(),
            lsp_types::SymbolKind::KEY => "Key".to_string(),
            lsp_types::SymbolKind::NULL => "Null".to_string(),
            lsp_types::SymbolKind::ENUM_MEMBER => "EnumMember".to_string(),
            lsp_types::SymbolKind::STRUCT => "Struct".to_string(),
            lsp_types::SymbolKind::EVENT => "Event".to_string(),
            lsp_types::SymbolKind::OPERATOR => "Operator".to_string(),
            lsp_types::SymbolKind::TYPE_PARAMETER => "TypeParameter".to_string(),
            _ => "Unknown".to_string(),
        }
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
        _ctx: &mut dyn vim::VimContext,
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

        // Make LSP document symbols request
        let params = lsp_types::DocumentSymbolParams {
            text_document: lsp_types::TextDocumentIdentifier {
                uri: lsp_types::Url::parse(&uri)?,
            },
            work_done_progress_params: Default::default(),
            partial_result_params: Default::default(),
        };

        let response = match self
            .lsp_registry
            .request::<lsp_types::request::DocumentSymbolRequest>(&language, params)
            .await
        {
            Ok(response) => response,
            Err(_) => return Ok(Some(None)), // 处理了请求，但 LSP 错误
        };

        debug!("document symbols response: {:?}", response);

        let symbols: Vec<Symbol> = match response {
            Some(lsp_types::DocumentSymbolResponse::Flat(symbol_infos)) => {
                // Convert SymbolInformation to simplified Symbol format
                symbol_infos
                    .into_iter()
                    .map(|info| {
                        Symbol::new(
                            info.name,
                            Self::symbol_kind_to_string(info.kind),
                            Range::from_lsp_range(info.location.range),
                            Range::from_lsp_range(info.location.range), // Use same range for selection
                            None, // SymbolInformation doesn't have detail
                            None, // Flat format doesn't have children
                        )
                    })
                    .collect()
            }
            Some(lsp_types::DocumentSymbolResponse::Nested(document_symbols)) => document_symbols
                .into_iter()
                .map(Self::convert_document_symbol)
                .collect(),
            None => return Ok(Some(None)), // 处理了请求，但没有符号
        };

        if symbols.is_empty() {
            return Ok(Some(None)); // 处理了请求，但没有符号
        }

        Ok(Some(Some(DocumentSymbolsInfo::new(symbols))))
    }
}
