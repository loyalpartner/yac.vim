use anyhow::Result;
use async_trait::async_trait;
use lsp_bridge::LspRegistry;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tracing::debug;
use vim::{Handler, HandlerResult};

use super::common::{with_lsp_context, HasFile, HasFilePosition, Location};

#[derive(Debug, Deserialize)]
#[allow(dead_code)]
pub struct ReferencesRequest {
    pub file: String,
    pub line: u32,
    pub column: u32,
    pub include_declaration: Option<bool>,
}

impl HasFile for ReferencesRequest {
    fn file(&self) -> &str {
        &self.file
    }
}

impl HasFilePosition for ReferencesRequest {
    fn line(&self) -> u32 {
        self.line
    }
    fn column(&self) -> u32 {
        self.column
    }
}

#[derive(Debug, Serialize)]
pub struct ReferencesInfo {
    pub locations: Vec<Location>,
}

pub type ReferencesResponse = ReferencesInfo;

impl ReferencesInfo {
    pub fn new(locations: Vec<Location>) -> Self {
        Self { locations }
    }
}

pub struct ReferencesHandler {
    lsp_registry: Arc<LspRegistry>,
}

impl ReferencesHandler {
    pub fn new(registry: Arc<LspRegistry>) -> Self {
        Self {
            lsp_registry: registry,
        }
    }
}

#[async_trait]
impl Handler for ReferencesHandler {
    type Input = ReferencesRequest;
    type Output = ReferencesResponse;

    async fn handle(
        &self,
        _vim: &dyn vim::VimContext,
        input: Self::Input,
    ) -> Result<HandlerResult<Self::Output>> {
        with_lsp_context(&self.lsp_registry, input, |ctx, input| async move {
            let params = lsp_types::ReferenceParams {
                text_document_position: lsp_types::TextDocumentPositionParams {
                    text_document: lsp_types::TextDocumentIdentifier { uri: ctx.uri },
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

            let locations = ctx
                .registry
                .request::<lsp_types::request::References>(&ctx.language, params)
                .await
                .ok()
                .flatten()
                .unwrap_or_default();

            debug!("references locations: {:?}", locations);

            if locations.is_empty() {
                return Ok(HandlerResult::Empty);
            }

            let result_locations: Vec<Location> = locations
                .into_iter()
                .filter_map(|loc| Location::from_lsp_location(loc).ok())
                .collect();

            if result_locations.is_empty() {
                return Ok(HandlerResult::Empty);
            }

            Ok(HandlerResult::Data(ReferencesInfo::new(result_locations)))
        })
        .await
    }
}
