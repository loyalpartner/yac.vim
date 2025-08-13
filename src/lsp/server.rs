use crate::lsp::client::LspClient;
use crate::lsp::jsonrpc::JsonRpcResponse;
use crate::utils::{
    config::{LspServerConfig, ResourceLimits},
    Error, Result,
};
use serde_json::Value;
use std::collections::HashMap;
use tracing::{debug, error, info, warn};

pub type ServerId = String;

pub struct LspServerManager {
    servers: HashMap<ServerId, LspClient>,
    configs: HashMap<String, LspServerConfig>,
    limits: ResourceLimits,
}

impl LspServerManager {
    pub fn new(configs: HashMap<String, LspServerConfig>) -> Self {
        Self {
            servers: HashMap::new(),
            configs,
            limits: ResourceLimits::default(),
        }
    }

    pub fn new_with_limits(
        configs: HashMap<String, LspServerConfig>,
        limits: ResourceLimits,
    ) -> Self {
        Self {
            servers: HashMap::new(),
            configs,
            limits,
        }
    }

    pub async fn start_server(&mut self, server_name: &str) -> Result<ServerId> {
        // 检查并发LSP服务器数量限制
        if self.servers.len() >= self.limits.max_concurrent_lsp_servers {
            return Err(Error::Internal(anyhow::anyhow!(
                "Maximum number of concurrent LSP servers reached: {}",
                self.limits.max_concurrent_lsp_servers
            )));
        }

        if let Some(existing_server) = self.servers.values().find(|s| s.server_name == server_name)
        {
            if existing_server.is_running() {
                debug!("LSP server {} is already running", server_name);
                return Ok(existing_server.server_name.clone());
            }
        }

        let config = self
            .configs
            .get(server_name)
            .ok_or_else(|| {
                Error::config(format!(
                    "No configuration found for server: {}",
                    server_name
                ))
            })?
            .clone();

        let client = LspClient::new(server_name.to_string(), config, &self.limits).await?;
        let server_id = client.server_name.clone();

        self.servers.insert(server_id.clone(), client);
        info!(
            "LSP server {} started with ID: {} (total: {})",
            server_name,
            server_id,
            self.servers.len()
        );

        Ok(server_id)
    }

    pub async fn stop_server(&mut self, server_id: &ServerId) -> Result<()> {
        if let Some(mut client) = self.servers.remove(server_id) {
            client.shutdown().await?;
            info!("LSP server {} stopped", server_id);
        } else {
            warn!("Attempted to stop non-existent server: {}", server_id);
        }
        Ok(())
    }

    pub async fn send_request(
        &mut self,
        server_id: &ServerId,
        method: String,
        params: Option<Value>,
    ) -> Result<JsonRpcResponse> {
        let client = self
            .servers
            .get_mut(server_id)
            .ok_or_else(|| Error::lsp_server(format!("Server not found: {}", server_id)))?;

        if !client.is_running() {
            return Err(Error::lsp_server(format!(
                "Server {} is not running",
                server_id
            )));
        }

        client.send_request(method, params).await
    }

    pub async fn send_notification(
        &self,
        server_id: &ServerId,
        method: String,
        params: Option<Value>,
    ) -> Result<()> {
        let client = self
            .servers
            .get(server_id)
            .ok_or_else(|| Error::lsp_server(format!("Server not found: {}", server_id)))?;

        if !client.is_running() {
            return Err(Error::lsp_server(format!(
                "Server {} is not running",
                server_id
            )));
        }

        client.send_notification(method, params).await
    }

    pub async fn find_server_for_filetype(&mut self, filetype: &str) -> Result<ServerId> {
        // Check if we already have a running server for this filetype
        for (server_id, client) in &self.servers {
            if client.is_running() && client.supports_filetype(filetype) {
                debug!(
                    "Found existing server {} for filetype {}",
                    server_id, filetype
                );
                return Ok(server_id.clone());
            }
        }

        // Find a configuration that supports this filetype
        let server_name = self
            .configs
            .iter()
            .find(|(_, config)| config.filetypes.contains(&filetype.to_string()))
            .map(|(name, _)| name.clone())
            .ok_or_else(|| {
                Error::config(format!(
                    "No LSP server configured for filetype: {}",
                    filetype
                ))
            })?;

        // Start the server
        info!(
            "Starting new LSP server {} for filetype {}",
            server_name, filetype
        );
        self.start_server(&server_name).await
    }

    pub async fn find_server_for_file(&mut self, file_uri: &str) -> Result<ServerId> {
        let filetype = self.detect_filetype(file_uri);
        self.find_server_for_filetype(&filetype).await
    }

    fn detect_filetype(&self, file_uri: &str) -> String {
        // Simple filetype detection based on file extension
        if let Some(extension) = file_uri.rsplit('.').next() {
            match extension {
                "rs" => "rust".to_string(),
                "py" => "python".to_string(),
                "js" | "jsx" => "javascript".to_string(),
                "ts" | "tsx" => "typescript".to_string(),
                "go" => "go".to_string(),
                "c" | "h" => "c".to_string(),
                "cpp" | "cc" | "cxx" | "hpp" => "cpp".to_string(),
                "java" => "java".to_string(),
                _ => "text".to_string(),
            }
        } else {
            "text".to_string()
        }
    }

    pub async fn broadcast_notification(
        &self,
        method: String,
        params: Option<Value>,
    ) -> Result<()> {
        for (server_id, client) in &self.servers {
            if client.is_running() {
                if let Err(e) = client
                    .send_notification(method.clone(), params.clone())
                    .await
                {
                    error!("Failed to send notification to server {}: {}", server_id, e);
                }
            }
        }
        Ok(())
    }

    pub async fn shutdown_all(&mut self) -> Result<()> {
        info!("Shutting down all LSP servers");

        let server_ids: Vec<ServerId> = self.servers.keys().cloned().collect();
        for server_id in server_ids {
            if let Err(e) = self.stop_server(&server_id).await {
                error!("Error stopping server {}: {}", server_id, e);
            }
        }

        self.servers.clear();
        info!("All LSP servers shut down");
        Ok(())
    }

    pub fn get_server_count(&self) -> usize {
        self.servers.len()
    }

    pub fn get_running_servers(&self) -> Vec<&ServerId> {
        self.servers
            .iter()
            .filter(|(_, client)| client.is_running())
            .map(|(id, _)| id)
            .collect()
    }

    pub fn get_server_status(
        &self,
        server_id: &ServerId,
    ) -> Option<&crate::lsp::client::LspServerStatus> {
        self.servers.get(server_id).map(|client| &client.status)
    }
}
