use anyhow::Result;
use async_trait::async_trait;
use lsp_bridge::LspRegistry;
use serde::Deserialize;
use std::sync::Arc;
use tracing::debug;
use vim::{Handler, HandlerResult};

use super::common::{with_lsp_file, HasFile};

#[derive(Debug, Deserialize)]
#[allow(dead_code)]
pub struct DidCloseRequest {
    pub file: String,
}

impl HasFile for DidCloseRequest {
    fn file(&self) -> &str {
        &self.file
    }
}

pub type DidCloseResponse = ();

pub struct DidCloseHandler {
    lsp_registry: Arc<LspRegistry>,
}

impl DidCloseHandler {
    pub fn new(registry: Arc<LspRegistry>) -> Self {
        Self {
            lsp_registry: registry,
        }
    }
}

#[async_trait]
impl Handler for DidCloseHandler {
    type Input = DidCloseRequest;
    type Output = DidCloseResponse;

    async fn handle(
        &self,
        _vim: &dyn vim::VimContext,
        input: Self::Input,
    ) -> Result<HandlerResult<Self::Output>> {
        with_lsp_file(&self.lsp_registry, input, |ctx, input| async move {
            let params = lsp_types::DidCloseTextDocumentParams {
                text_document: lsp_types::TextDocumentIdentifier { uri: ctx.uri },
            };
            match ctx
                .registry
                .notify(&ctx.language, "textDocument/didClose", params)
                .await
            {
                Ok(_) => debug!("DidClose notification sent for: {}", input.file),
                Err(e) => debug!("DidClose notification failed: {:?}", e),
            }
            Ok(HandlerResult::Empty)
        })
        .await
    }
}
