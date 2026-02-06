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
pub struct WillSaveRequest {
    pub file: String,
    pub reason: String,
}

impl HasFile for WillSaveRequest {
    fn file(&self) -> &str {
        &self.file
    }
}

pub type WillSaveResponse = ();

pub struct WillSaveHandler {
    lsp_registry: Arc<LspRegistry>,
}

impl WillSaveHandler {
    pub fn new(registry: Arc<LspRegistry>) -> Self {
        Self {
            lsp_registry: registry,
        }
    }

    fn reason_to_lsp(reason: &str) -> lsp_types::TextDocumentSaveReason {
        match reason {
            "Manual" => lsp_types::TextDocumentSaveReason::MANUAL,
            "AfterDelay" => lsp_types::TextDocumentSaveReason::AFTER_DELAY,
            "FocusOut" => lsp_types::TextDocumentSaveReason::FOCUS_OUT,
            _ => lsp_types::TextDocumentSaveReason::MANUAL,
        }
    }
}

#[async_trait]
impl Handler for WillSaveHandler {
    type Input = WillSaveRequest;
    type Output = WillSaveResponse;

    async fn handle(
        &self,
        _vim: &dyn vim::VimContext,
        input: Self::Input,
    ) -> Result<HandlerResult<Self::Output>> {
        with_lsp_file(&self.lsp_registry, input, |ctx, input| async move {
            let params = lsp_types::WillSaveTextDocumentParams {
                text_document: lsp_types::TextDocumentIdentifier { uri: ctx.uri },
                reason: Self::reason_to_lsp(&input.reason),
            };
            match ctx
                .registry
                .notify(&ctx.language, "textDocument/willSave", params)
                .await
            {
                Ok(_) => debug!(
                    "WillSave notification sent for: {} (reason: {})",
                    input.file, input.reason
                ),
                Err(e) => debug!("WillSave notification failed: {:?}", e),
            }
            Ok(HandlerResult::Empty)
        })
        .await
    }
}
