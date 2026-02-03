use anyhow::Result;
use async_trait::async_trait;
use lsp_bridge::LspRegistry;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tracing::debug;
use vim::{Handler, HandlerResult};

#[derive(Debug, Deserialize)]
#[allow(dead_code)]
pub struct ExecuteCommandRequest {
    pub command: String,
    pub arguments: Option<Vec<serde_json::Value>>,
    pub language: String, // Specify which language server to use
}

#[derive(Debug, Serialize)]
pub struct ExecuteCommandResult {
    pub result: Option<serde_json::Value>,
}

pub type ExecuteCommandResponse = ExecuteCommandResult;

impl ExecuteCommandResult {
    pub fn new(result: Option<serde_json::Value>) -> Self {
        Self { result }
    }
}

pub struct ExecuteCommandHandler {
    lsp_registry: Arc<LspRegistry>,
}

impl ExecuteCommandHandler {
    pub fn new(registry: Arc<LspRegistry>) -> Self {
        Self {
            lsp_registry: registry,
        }
    }
}

#[async_trait]
impl Handler for ExecuteCommandHandler {
    type Input = ExecuteCommandRequest;
    type Output = ExecuteCommandResponse;

    async fn handle(
        &self,
        _vim: &dyn vim::VimContext,
        input: Self::Input,
    ) -> Result<HandlerResult<Self::Output>> {
        // Check if the language server exists
        if !self.lsp_registry.get_existing_client(&input.language).await {
            return Ok(HandlerResult::Empty);
        }

        // Make LSP execute command request
        let params = lsp_types::ExecuteCommandParams {
            command: input.command.clone(),
            arguments: input.arguments.unwrap_or_default(),
            work_done_progress_params: Default::default(),
        };

        let response = match self
            .lsp_registry
            .request::<lsp_types::request::ExecuteCommand>(&input.language, params)
            .await
        {
            Ok(response) => response,
            Err(e) => {
                debug!("Execute command error: {:?}", e);
                return Ok(HandlerResult::Empty);
            }
        };

        debug!("execute command response: {:?}", response);

        // ExecuteCommand can return any JSON value or None
        Ok(HandlerResult::Data(ExecuteCommandResult::new(response)))
    }
}
