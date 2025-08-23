use anyhow::Result;
use async_trait::async_trait;
use lsp_client::LspClient;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tokio::sync::Mutex;
use tracing::debug;
use vim::Handler;

use super::common::{file_path_to_uri, Location};

#[derive(Debug, Deserialize)]
#[allow(dead_code)]
pub struct ReferencesRequest {
    pub file: String,
    pub line: u32,
    pub column: u32,
    pub include_declaration: Option<bool>,
}

#[derive(Debug, Serialize)]
pub struct ReferencesInfo {
    pub locations: Vec<Location>,
}

// Linus-style: ReferencesInfo 要么完整存在，要么不存在
pub type ReferencesResponse = Option<ReferencesInfo>;

impl ReferencesInfo {
    pub fn new(locations: Vec<Location>) -> Self {
        Self { locations }
    }
}

pub struct ReferencesHandler {
    lsp_client: Arc<Mutex<Option<LspClient>>>,
}

impl ReferencesHandler {
    pub fn new(client: Arc<Mutex<Option<LspClient>>>) -> Self {
        Self { lsp_client: client }
    }
}

#[async_trait]
impl Handler for ReferencesHandler {
    type Input = ReferencesRequest;
    type Output = ReferencesResponse;

    async fn handle(&self, input: Self::Input) -> Result<Option<Self::Output>> {
        let client_lock = self.lsp_client.lock().await;
        let client = client_lock.as_ref().unwrap();

        // Convert file path to URI - 使用通用函数
        let uri = match file_path_to_uri(&input.file) {
            Ok(uri) => uri,
            Err(_) => return Ok(Some(None)), // 处理了请求，但转换失败
        };

        // Make LSP references request
        let params = lsp_types::ReferenceParams {
            text_document_position: lsp_types::TextDocumentPositionParams {
                text_document: lsp_types::TextDocumentIdentifier {
                    uri: lsp_types::Url::parse(&uri)?,
                },
                position: lsp_types::Position {
                    line: input.line,
                    character: input.column,
                },
            },
            context: lsp_types::ReferenceContext {
                include_declaration: input.include_declaration.unwrap_or(false),
            },
            work_done_progress_params: Default::default(),
            partial_result_params: Default::default(),
        };

        let response = match client
            .request::<lsp_types::request::References>(params)
            .await
        {
            Ok(response) => response,
            Err(_) => return Ok(Some(None)), // 处理了请求，但 LSP 错误
        };

        let locations = match response {
            Some(locations) => locations,
            None => return Ok(Some(None)), // 处理了请求，但没找到引用
        };

        debug!("references locations: {:?}", locations);

        if locations.is_empty() {
            return Ok(Some(None)); // 处理了请求，但没找到引用
        }

        // Convert all locations - 使用通用 Location 转换函数
        let mut result_locations = Vec::new();
        for location in locations {
            if let Ok(converted_location) = Location::from_lsp_location(location) {
                result_locations.push(converted_location);
            }
        }

        if result_locations.is_empty() {
            return Ok(Some(None)); // 所有位置都无效
        }

        Ok(Some(Some(ReferencesInfo::new(result_locations))))
    }
}
