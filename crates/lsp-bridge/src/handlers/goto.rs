use anyhow::Result;
use async_trait::async_trait;
use lsp_client::LspClient;
use serde::Deserialize;
use std::sync::Arc;
use tokio::sync::Mutex;
use tracing::debug;
use vim::Handler;

use super::common::Location;

// Base request structure that Vim sends
#[derive(Debug, Deserialize)]
#[allow(dead_code)]
pub struct GotoRequest {
    pub file: String,
    pub line: u32,
    pub column: u32,
    // command field is ignored but might be present from vim
    #[serde(default)]
    pub command: Option<String>,
}

// Linus-style: 简单的字符串，直接对应LSP方法
#[derive(Debug, Clone)]
pub enum GotoType {
    Definition,
    Declaration,
    TypeDefinition,
    Implementation,
}

impl GotoType {
    fn from_method(method: &str) -> Option<Self> {
        match method {
            "goto_definition" => Some(Self::Definition),
            "goto_declaration" => Some(Self::Declaration),
            "goto_type_definition" => Some(Self::TypeDefinition),
            "goto_implementation" => Some(Self::Implementation),
            _ => None,
        }
    }
}

// Linus-style: Location 要么完整存在，要么不存在
pub type GotoResponse = Option<Location>;

#[derive(Clone)]
pub struct GotoHandler {
    lsp_client: Arc<Mutex<Option<LspClient>>>,
    goto_type: GotoType,
}

impl GotoHandler {
    pub fn new(client: Arc<Mutex<Option<LspClient>>>, method: &str) -> Option<Self> {
        GotoType::from_method(method).map(|goto_type| Self {
            lsp_client: client,
            goto_type,
        })
    }
}

#[async_trait]
impl Handler for GotoHandler {
    type Input = GotoRequest;
    type Output = GotoResponse;

    async fn handle(&self, input: Self::Input) -> Result<Option<Self::Output>> {
        let client_lock = self.lsp_client.lock().await;
        let client = client_lock.as_ref().unwrap();

        // Convert file path to URI - 使用通用函数
        let uri = match super::common::file_path_to_uri(&input.file) {
            Ok(uri) => uri,
            Err(_) => return Ok(Some(None)), // 处理了请求，但转换失败
        };

        let lsp_uri = lsp_types::Url::parse(&uri)?;

        let text_document_position = lsp_types::TextDocumentPositionParams {
            text_document: lsp_types::TextDocumentIdentifier { uri: lsp_uri },
            position: lsp_types::Position {
                line: input.line,
                character: input.column,
            },
        };

        // Make appropriate LSP request based on handler type
        let response = match self.goto_type {
            GotoType::Definition => {
                let params = lsp_types::GotoDefinitionParams {
                    text_document_position_params: text_document_position,
                    work_done_progress_params: Default::default(),
                    partial_result_params: Default::default(),
                };
                client
                    .request::<lsp_types::request::GotoDefinition>(params)
                    .await
            }
            GotoType::Declaration => {
                let params = lsp_types::GotoDefinitionParams {
                    text_document_position_params: text_document_position,
                    work_done_progress_params: Default::default(),
                    partial_result_params: Default::default(),
                };
                client
                    .request::<lsp_types::request::GotoDeclaration>(params)
                    .await
            }
            GotoType::TypeDefinition => {
                let params = lsp_types::request::GotoTypeDefinitionParams {
                    text_document_position_params: text_document_position,
                    work_done_progress_params: Default::default(),
                    partial_result_params: Default::default(),
                };
                client
                    .request::<lsp_types::request::GotoTypeDefinition>(params)
                    .await
            }
            GotoType::Implementation => {
                let params = lsp_types::request::GotoImplementationParams {
                    text_document_position_params: text_document_position,
                    work_done_progress_params: Default::default(),
                    partial_result_params: Default::default(),
                };
                client
                    .request::<lsp_types::request::GotoImplementation>(params)
                    .await
            }
        };

        let location_result = match response {
            Ok(Some(goto_response)) => {
                // Handle different response types from LSP
                match goto_response {
                    lsp_types::GotoDefinitionResponse::Scalar(location) => Some(location),
                    lsp_types::GotoDefinitionResponse::Array(locations) => {
                        locations.first().cloned()
                    }
                    lsp_types::GotoDefinitionResponse::Link(links) => {
                        links.first().map(|link| lsp_types::Location {
                            uri: link.target_uri.clone(),
                            range: link.target_selection_range,
                        })
                    }
                }
            }
            Ok(None) => None,
            Err(_) => return Ok(Some(None)), // 处理了请求，但 LSP 错误
        };

        debug!("{:?} response: {:?}", self.goto_type, location_result);

        match location_result {
            Some(lsp_location) => {
                match Location::from_lsp_location(lsp_location) {
                    Ok(location) => Ok(Some(Some(location))),
                    Err(_) => Ok(Some(None)), // 转换失败
                }
            }
            None => Ok(Some(None)), // 没找到位置
        }
    }
}
