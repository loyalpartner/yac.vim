use anyhow::Result;
use async_trait::async_trait;
use lsp_bridge::LspRegistry;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tracing::debug;
use vim::{Handler, HandlerResult};

use super::common::{with_lsp_file, HasFile};

#[derive(Debug, Deserialize)]
#[allow(dead_code)]
pub struct FoldingRangeRequest {
    pub file: String,
}

impl HasFile for FoldingRangeRequest {
    fn file(&self) -> &str {
        &self.file
    }
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

pub type FoldingRangeResponse = FoldingRangeInfo;

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
    lsp_registry: Arc<LspRegistry>,
}

impl FoldingRangeHandler {
    pub fn new(registry: Arc<LspRegistry>) -> Self {
        Self {
            lsp_registry: registry,
        }
    }
}

#[async_trait]
impl Handler for FoldingRangeHandler {
    type Input = FoldingRangeRequest;
    type Output = FoldingRangeResponse;

    async fn handle(
        &self,
        _vim: &dyn vim::VimContext,
        input: Self::Input,
    ) -> Result<HandlerResult<Self::Output>> {
        with_lsp_file(&self.lsp_registry, input, |ctx, _input| async move {
            let params = lsp_types::FoldingRangeParams {
                text_document: lsp_types::TextDocumentIdentifier { uri: ctx.uri },
                work_done_progress_params: Default::default(),
                partial_result_params: Default::default(),
            };

            let response = match ctx
                .registry
                .request::<lsp_types::request::FoldingRangeRequest>(&ctx.language, params)
                .await
            {
                Ok(response) => response,
                Err(_) => return Ok(HandlerResult::Empty),
            };

            debug!("folding range response: {:?}", response);

            let ranges = match response {
                Some(ranges) if !ranges.is_empty() => ranges,
                _ => return Ok(HandlerResult::Empty),
            };

            let result_ranges: Vec<FoldingRange> = ranges
                .into_iter()
                .map(FoldingRange::from_lsp_folding_range)
                .collect();

            Ok(HandlerResult::Data(FoldingRangeInfo::new(result_ranges)))
        })
        .await
    }
}
