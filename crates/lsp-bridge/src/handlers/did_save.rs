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
pub struct DidSaveRequest {
    pub file: String,
    pub text: Option<String>,
}

impl HasFile for DidSaveRequest {
    fn file(&self) -> &str {
        &self.file
    }
}

pub type DidSaveResponse = ();

pub struct DidSaveHandler {
    lsp_registry: Arc<LspRegistry>,
}

impl DidSaveHandler {
    pub fn new(registry: Arc<LspRegistry>) -> Self {
        Self {
            lsp_registry: registry,
        }
    }
}

#[async_trait]
impl Handler for DidSaveHandler {
    type Input = DidSaveRequest;
    type Output = DidSaveResponse;

    async fn handle(
        &self,
        _vim: &dyn vim::VimContext,
        input: Self::Input,
    ) -> Result<HandlerResult<Self::Output>> {
        with_lsp_file(&self.lsp_registry, input, |ctx, input| async move {
            let params = lsp_types::DidSaveTextDocumentParams {
                text_document: lsp_types::TextDocumentIdentifier { uri: ctx.uri },
                text: input.text,
            };
            match ctx
                .registry
                .notify(&ctx.language, "textDocument/didSave", params)
                .await
            {
                Ok(_) => debug!("DidSave notification sent for: {}", input.file),
                Err(e) => debug!("DidSave notification failed: {:?}", e),
            }
            Ok(HandlerResult::Empty)
        })
        .await
    }
}
