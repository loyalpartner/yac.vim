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
pub struct WillSaveRequest {
    pub file: String,
    pub reason: String, // "Manual", "AfterDelay", "FocusOut"
}

#[derive(Debug, Serialize)]
pub struct WillSaveResult {
    pub success: bool,
}

// Linus-style: WillSaveResult 要么完整存在，要么不存在
pub type WillSaveResponse = Option<WillSaveResult>;

impl WillSaveResult {
    pub fn new(success: bool) -> Self {
        Self { success }
    }
}

pub struct WillSaveHandler {
    lsp_client: Arc<Mutex<Option<LspClient>>>,
}

impl WillSaveHandler {
    pub fn new(client: Arc<Mutex<Option<LspClient>>>) -> Self {
        Self { lsp_client: client }
    }

    fn reason_to_lsp(&self, reason: &str) -> lsp_types::TextDocumentSaveReason {
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

    async fn handle(&self, input: Self::Input) -> Result<Option<Self::Output>> {
        let client_lock = self.lsp_client.lock().await;
        let client = client_lock.as_ref().unwrap();

        // Convert file path to URI
        let uri = match super::common::file_path_to_uri(&input.file) {
            Ok(uri) => uri,
            Err(_) => return Ok(Some(Some(WillSaveResult::new(false)))), // 处理了请求，但转换失败
        };

        // Send LSP willSave notification
        let params = lsp_types::WillSaveTextDocumentParams {
            text_document: lsp_types::TextDocumentIdentifier {
                uri: lsp_types::Url::parse(&uri)?,
            },
            reason: self.reason_to_lsp(&input.reason),
        };

        // willSave is a notification, not a request (no response expected)
        match client.notify("textDocument/willSave", params).await {
            Ok(_) => {
                debug!(
                    "WillSave notification sent for: {} (reason: {})",
                    input.file, input.reason
                );
                Ok(Some(Some(WillSaveResult::new(true))))
            }
            Err(e) => {
                debug!("WillSave notification failed: {:?}", e);
                Ok(Some(Some(WillSaveResult::new(false))))
            }
        }
    }
}
