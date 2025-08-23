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
pub struct DidSaveRequest {
    pub file: String,
    pub text: Option<String>, // Full document text (if server supports it)
}

#[derive(Debug, Serialize)]
pub struct DidSaveResult {
    pub success: bool,
}

// Linus-style: DidSaveResult 要么完整存在，要么不存在
pub type DidSaveResponse = Option<DidSaveResult>;

impl DidSaveResult {
    pub fn new(success: bool) -> Self {
        Self { success }
    }
}

pub struct DidSaveHandler {
    lsp_client: Arc<Mutex<Option<LspClient>>>,
}

impl DidSaveHandler {
    pub fn new(client: Arc<Mutex<Option<LspClient>>>) -> Self {
        Self { lsp_client: client }
    }
}

#[async_trait]
impl Handler for DidSaveHandler {
    type Input = DidSaveRequest;
    type Output = DidSaveResponse;

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
            Err(_) => return Ok(Some(Some(DidSaveResult::new(false)))), // 处理了请求，但转换失败
        };

        // Send LSP didSave notification
        let params = lsp_types::DidSaveTextDocumentParams {
            text_document: lsp_types::TextDocumentIdentifier {
                uri: lsp_types::Url::parse(&uri)?,
            },
            text: input.text,
        };

        // didSave is a notification, not a request (no response expected)
        match client.notify("textDocument/didSave", params).await {
            Ok(_) => {
                debug!("DidSave notification sent for: {}", input.file);
                Ok(Some(Some(DidSaveResult::new(true))))
            }
            Err(e) => {
                debug!("DidSave notification failed: {:?}", e);
                Ok(Some(Some(DidSaveResult::new(false))))
            }
        }
    }
}
