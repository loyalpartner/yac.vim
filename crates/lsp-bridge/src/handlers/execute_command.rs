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
pub struct ExecuteCommandRequest {
    pub command: String,
    pub arguments: Option<Vec<serde_json::Value>>,
}

#[derive(Debug, Serialize)]
pub struct ExecuteCommandResult {
    pub result: Option<serde_json::Value>,
}

// Linus-style: ExecuteCommandResult 要么完整存在，要么不存在
pub type ExecuteCommandResponse = Option<ExecuteCommandResult>;

impl ExecuteCommandResult {
    pub fn new(result: Option<serde_json::Value>) -> Self {
        Self { result }
    }
}

pub struct ExecuteCommandHandler {
    lsp_client: Arc<Mutex<Option<LspClient>>>,
}

impl ExecuteCommandHandler {
    pub fn new(client: Arc<Mutex<Option<LspClient>>>) -> Self {
        Self { lsp_client: client }
    }
}

#[async_trait]
impl Handler for ExecuteCommandHandler {
    type Input = ExecuteCommandRequest;
    type Output = ExecuteCommandResponse;

    async fn handle(&self, input: Self::Input) -> Result<Option<Self::Output>> {
        let client_lock = self.lsp_client.lock().await;
        let client = client_lock.as_ref().unwrap();

        // Make LSP execute command request
        let params = lsp_types::ExecuteCommandParams {
            command: input.command.clone(),
            arguments: input.arguments.unwrap_or_default(),
            work_done_progress_params: Default::default(),
        };

        let response = match client
            .request::<lsp_types::request::ExecuteCommand>(params)
            .await
        {
            Ok(response) => response,
            Err(e) => {
                debug!("Execute command error: {:?}", e);
                return Ok(Some(None)); // 处理了请求，但命令执行失败
            }
        };

        debug!("execute command response: {:?}", response);

        // ExecuteCommand can return any JSON value or None
        Ok(Some(Some(ExecuteCommandResult::new(response))))
    }
}
