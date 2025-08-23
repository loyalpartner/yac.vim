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
pub struct DidCloseRequest {
    pub file: String,
}

#[derive(Debug, Serialize)]
pub struct DidCloseResult {
    pub success: bool,
}

// Linus-style: DidCloseResult 要么完整存在，要么不存在
pub type DidCloseResponse = Option<DidCloseResult>;

impl DidCloseResult {
    pub fn new(success: bool) -> Self {
        Self { success }
    }
}

pub struct DidCloseHandler {
    lsp_client: Arc<Mutex<Option<LspClient>>>,
}

impl DidCloseHandler {
    pub fn new(client: Arc<Mutex<Option<LspClient>>>) -> Self {
        Self { lsp_client: client }
    }
}

#[async_trait]
impl Handler for DidCloseHandler {
    type Input = DidCloseRequest;
    type Output = DidCloseResponse;

    async fn handle(&self, input: Self::Input) -> Result<Option<Self::Output>> {
        let client_lock = self.lsp_client.lock().await;
        let client = client_lock.as_ref().unwrap();

        // Convert file path to URI
        let uri = match super::common::file_path_to_uri(&input.file) {
            Ok(uri) => uri,
            Err(_) => return Ok(Some(Some(DidCloseResult::new(false)))), // 处理了请求，但转换失败
        };

        // Send LSP didClose notification
        let params = lsp_types::DidCloseTextDocumentParams {
            text_document: lsp_types::TextDocumentIdentifier {
                uri: lsp_types::Url::parse(&uri)?,
            },
        };

        // didClose is a notification, not a request (no response expected)
        match client.notify("textDocument/didClose", params).await {
            Ok(_) => {
                debug!("DidClose notification sent for: {}", input.file);
                Ok(Some(Some(DidCloseResult::new(true))))
            }
            Err(e) => {
                debug!("DidClose notification failed: {:?}", e);
                Ok(Some(Some(DidCloseResult::new(false))))
            }
        }
    }
}
