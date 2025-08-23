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
pub struct FoldingRangeRequest {
    pub file: String,
}

#[derive(Debug, Serialize)]
pub struct FoldingRange {
    pub start_line: u32,
    pub end_line: u32,
    pub start_character: Option<u32>,
    pub end_character: Option<u32>,
    pub kind: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct FoldingRangeInfo {
    pub ranges: Vec<FoldingRange>,
}

// Linus-style: FoldingRangeInfo 要么完整存在，要么不存在
pub type FoldingRangeResponse = Option<FoldingRangeInfo>;

impl FoldingRange {
    pub fn new(
        start_line: u32,
        end_line: u32,
        start_character: Option<u32>,
        end_character: Option<u32>,
        kind: Option<String>,
    ) -> Self {
        Self {
            start_line,
            end_line,
            start_character,
            end_character,
            kind,
        }
    }

    pub fn from_lsp_folding_range(range: lsp_types::FoldingRange) -> Self {
        let kind = range.kind.map(|k| match k {
            lsp_types::FoldingRangeKind::Comment => "Comment".to_string(),
            lsp_types::FoldingRangeKind::Imports => "Imports".to_string(),
            lsp_types::FoldingRangeKind::Region => "Region".to_string(),
        });

        Self::new(
            range.start_line,
            range.end_line,
            range.start_character,
            range.end_character,
            kind,
        )
    }
}

impl FoldingRangeInfo {
    pub fn new(ranges: Vec<FoldingRange>) -> Self {
        Self { ranges }
    }
}

pub struct FoldingRangeHandler {
    lsp_client: Arc<Mutex<Option<LspClient>>>,
}

impl FoldingRangeHandler {
    pub fn new(client: Arc<Mutex<Option<LspClient>>>) -> Self {
        Self { lsp_client: client }
    }
}

#[async_trait]
impl Handler for FoldingRangeHandler {
    type Input = FoldingRangeRequest;
    type Output = FoldingRangeResponse;

    async fn handle(
        &self,
        _ctx: &mut dyn vim::VimContext,
        input: Self::Input,
    ) -> Result<Option<Self::Output>> {
        let client_lock = self.lsp_client.lock().await;
        let client = client_lock.as_ref().unwrap();

        // Convert file path to URI
        let uri = match super::common::file_path_to_uri(&input.file) {
            Ok(uri) => uri,
            Err(_) => return Ok(Some(None)), // 处理了请求，但转换失败
        };

        // Make LSP folding range request
        let params = lsp_types::FoldingRangeParams {
            text_document: lsp_types::TextDocumentIdentifier {
                uri: lsp_types::Url::parse(&uri)?,
            },
            work_done_progress_params: Default::default(),
            partial_result_params: Default::default(),
        };

        let response = match client
            .request::<lsp_types::request::FoldingRangeRequest>(params)
            .await
        {
            Ok(response) => response,
            Err(_) => return Ok(Some(None)), // 处理了请求，但 LSP 错误
        };

        debug!("folding range response: {:?}", response);

        let ranges = match response {
            Some(ranges) => ranges,
            None => return Ok(Some(None)), // 处理了请求，但没有折叠范围
        };

        if ranges.is_empty() {
            return Ok(Some(None)); // 处理了请求，但没有折叠范围
        }

        // Convert folding ranges
        let result_ranges: Vec<FoldingRange> = ranges
            .into_iter()
            .map(FoldingRange::from_lsp_folding_range)
            .collect();

        Ok(Some(Some(FoldingRangeInfo::new(result_ranges))))
    }
}
