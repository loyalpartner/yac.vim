use crate::lsp::jsonrpc::{JsonRpcMessage, JsonRpcRequest, JsonRpcResponse, JsonRpcResponseResult, JsonRpcNotification, RequestId};
use crate::utils::{
    config::{LspServerConfig, ResourceLimits},
    Error, Result,
};
use serde_json::Value;
use std::collections::HashMap;
use std::process::Stdio;
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, Command};
use tokio::sync::{mpsc, RwLock};
use tracing::{debug, error, info, warn};
use uuid::Uuid;

#[derive(Debug)]
pub enum LspServerStatus {
    Starting,
    Running,
    Failed,
    Stopped,
}

pub struct LspClient {
    pub server_name: String,
    pub config: LspServerConfig,
    pub status: LspServerStatus,
    process: Option<Child>,
    request_tx: mpsc::Sender<JsonRpcRequest>,
    notification_tx: mpsc::Sender<JsonRpcNotification>,
    response_rx: mpsc::Receiver<JsonRpcResponse>,
    pending_requests: Arc<RwLock<HashMap<RequestId, mpsc::Sender<JsonRpcResponse>>>>,
}

impl LspClient {
    pub async fn new(
        server_name: String,
        config: LspServerConfig,
        limits: &ResourceLimits,
    ) -> Result<Self> {
        info!("Starting LSP server: {}", server_name);

        let mut cmd = Command::new(&config.command[0]);
        if config.command.len() > 1 {
            cmd.args(&config.command[1..]);
        }
        cmd.args(&config.args);

        // Set environment variables
        for (key, value) in &config.env {
            cmd.env(key, value);
        }

        cmd.stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);

        let mut process = cmd.spawn().map_err(|e| {
            Error::process(format!("Failed to start LSP server {}: {}", server_name, e))
        })?;

        let stdin = process
            .stdin
            .take()
            .ok_or_else(|| Error::process("Failed to get stdin of LSP server".to_string()))?;

        let stdout = process
            .stdout
            .take()
            .ok_or_else(|| Error::process("Failed to get stdout of LSP server".to_string()))?;

        let (request_tx, mut request_rx) =
            mpsc::channel::<JsonRpcRequest>(limits.lsp_request_queue_size);
        let (notification_tx, mut notification_rx) =
            mpsc::channel::<JsonRpcNotification>(limits.lsp_request_queue_size);
        let (response_tx, response_rx) =
            mpsc::channel::<JsonRpcResponse>(limits.lsp_response_queue_size);
        
        let pending_requests = Arc::new(RwLock::new(HashMap::<RequestId, mpsc::Sender<JsonRpcResponse>>::new()));

        // Spawn stdin writer task
        let server_name_clone = server_name.clone();
        tokio::spawn(async move {
            let mut stdin = stdin;
            loop {
                tokio::select! {
                    request_opt = request_rx.recv() => {
                        if let Some(request) = request_opt {
                            if let Ok(json) = serde_json::to_string(&request) {
                                let message = format!("Content-Length: {}\r\n\r\n{}", json.len(), json);
                                if let Err(e) = stdin.write_all(message.as_bytes()).await {
                                    error!("Failed to write request to LSP server {}: {}", server_name_clone, e);
                                    break;
                                }
                            } else {
                                error!("Failed to serialize request for server {}", server_name_clone);
                            }
                        } else {
                            break; // Channel closed
                        }
                    }
                    notification_opt = notification_rx.recv() => {
                        if let Some(notification) = notification_opt {
                            if let Ok(json) = serde_json::to_string(&notification) {
                                let message = format!("Content-Length: {}\r\n\r\n{}", json.len(), json);
                                if let Err(e) = stdin.write_all(message.as_bytes()).await {
                                    error!("Failed to write notification to LSP server {}: {}", server_name_clone, e);
                                    break;
                                }
                            } else {
                                error!("Failed to serialize notification for server {}", server_name_clone);
                            }
                        } else {
                            break; // Channel closed
                        }
                    }
                }
            }
        });

        // Spawn stdout reader task
        let server_name_clone = server_name.clone();
        let pending_requests_clone = pending_requests.clone();
        tokio::spawn(async move {
            let mut reader = BufReader::new(stdout);
            let mut headers = HashMap::new();
            let mut content_length = 0;

            loop {
                // Read headers
                headers.clear();
                loop {
                    let mut line = String::new();
                    match reader.read_line(&mut line).await {
                        Ok(0) => {
                            info!("LSP server {} stdout closed", server_name_clone);
                            return;
                        }
                        Ok(_) => {
                            let line = line.trim();
                            if line.is_empty() {
                                break;
                            }

                            if let Some((key, value)) = line.split_once(':') {
                                headers.insert(key.trim().to_lowercase(), value.trim().to_string());
                            }
                        }
                        Err(e) => {
                            error!("Error reading from LSP server {}: {}", server_name_clone, e);
                            return;
                        }
                    }
                }

                // Get content length
                content_length = headers
                    .get("content-length")
                    .and_then(|v| v.parse::<usize>().ok())
                    .unwrap_or(0);

                if content_length == 0 {
                    continue;
                }

                // Read content
                let mut content = vec![0u8; content_length];
                if let Err(e) = tokio::io::AsyncReadExt::read_exact(&mut reader, &mut content).await
                {
                    error!(
                        "Error reading content from LSP server {}: {}",
                        server_name_clone, e
                    );
                    break;
                }

                let content_str = String::from_utf8_lossy(&content);
                debug!(
                    "Received from LSP server {}: {}",
                    server_name_clone, content_str
                );

                // Parse JSON-RPC message
                match serde_json::from_str::<JsonRpcMessage>(&content_str) {
                    Ok(JsonRpcMessage::Response(response)) => {
                        // Route response to the waiting request
                        let response_id = response.id.clone();
                        let mut pending = pending_requests_clone.write().await;
                        if let Some(sender) = pending.remove(&response_id) {
                            if let Err(_) = sender.send(response).await {
                                warn!("Failed to send response for request {}", response_id);
                            } else {
                                debug!("Routed response for request {} to waiting caller", response_id);
                            }
                        } else {
                            warn!("Received response for unknown request {}", response_id);
                        }
                    }
                    Ok(JsonRpcMessage::Notification(notif)) => {
                        debug!(
                            "Received notification from {}: {}",
                            server_name_clone, notif.method
                        );
                        // Handle notifications (diagnostics, etc.)
                    }
                    Ok(JsonRpcMessage::Request(req)) => {
                        debug!(
                            "Received request from {}: {}",
                            server_name_clone, req.method
                        );
                        // Handle server requests if needed
                    }
                    Err(e) => {
                        warn!("Failed to parse message from {}: {}", server_name_clone, e);
                    }
                }
            }
        });

        let mut client = Self {
            server_name,
            config,
            status: LspServerStatus::Starting,
            process: Some(process),
            request_tx,
            notification_tx,
            response_rx,
            pending_requests,
        };

        // Send initialize request
        client.initialize().await?;

        Ok(client)
    }

    async fn initialize(&mut self) -> Result<()> {
        info!("Initializing LSP server: {}", self.server_name);

        let initialize_params = serde_json::json!({
            "processId": std::process::id(),
            "rootUri": format!("file://{}", std::env::current_dir().unwrap().display()),
            "capabilities": {
                "textDocument": {
                    "completion": {
                        "completionItem": {
                            "snippetSupport": false
                        }
                    },
                    "hover": {
                        "contentFormat": ["plaintext", "markdown"]
                    },
                    "definition": {
                        "linkSupport": false
                    }
                }
            },
            "initializationOptions": self.config.initialization_options.clone()
        });

        let request = JsonRpcRequest::new(
            Uuid::new_v4().to_string(),
            "initialize".to_string(),
            Some(initialize_params),
        );

        // Send initialize request and wait for response
        let request_id = request.id.clone();
        let (tx, mut rx) = mpsc::channel(1);
        {
            let mut pending = self.pending_requests.write().await;
            pending.insert(request_id, tx);
        }
        self.send_request_internal(request).await?;

        // Wait for initialize response
        tokio::select! {
            response = rx.recv() => {
                match response {
                    Some(resp) => {
                        match resp.result {
                            JsonRpcResponseResult::Error { error } => {
                                return Err(Error::lsp_server(format!("LSP initialization failed: {:?}", error)));
                            }
                            JsonRpcResponseResult::Success { .. } => {
                                info!("LSP server {} initialization response received", self.server_name);
                            }
                        }
                    }
                    None => {
                        return Err(Error::lsp_server("Initialize response channel closed".to_string()));
                    }
                }
            }
            _ = tokio::time::sleep(tokio::time::Duration::from_secs(30)) => {
                return Err(Error::lsp_server("LSP initialization timeout".to_string()));
            }
        }

        // Send initialized notification (only after successful initialize response)
        // Send initialized notification (required by LSP protocol)
        let initialized_notification = JsonRpcNotification {
            jsonrpc: "2.0".to_string(),
            method: "initialized".to_string(),
            params: Some(serde_json::json!({})),
        };
        
        self.notification_tx.send(initialized_notification).await
            .map_err(|_| Error::lsp_server("Failed to send initialized notification".to_string()))?;

        self.status = LspServerStatus::Running;
        info!("LSP server {} initialized successfully", self.server_name);

        Ok(())
    }

    pub async fn send_request(
        &mut self,
        method: String,
        params: Option<Value>,
    ) -> Result<JsonRpcResponse> {
        let request_id = Uuid::new_v4().to_string();
        let request = JsonRpcRequest::new(request_id.clone(), method, params);

        let (tx, mut rx) = mpsc::channel(1); // 一个请求只需要一个响应
        {
            let mut pending = self.pending_requests.write().await;
            pending.insert(request_id, tx);
        }

        self.send_request_internal(request).await?;

        // Wait for response (with timeout)
        tokio::select! {
            response = rx.recv() => {
                response.ok_or_else(|| Error::Internal(anyhow::anyhow!("Response channel closed")))
            }
            _ = tokio::time::sleep(tokio::time::Duration::from_secs(30)) => {
                Err(Error::Timeout)
            }
        }
    }

    /// 使用指定的请求ID发送LSP请求
    pub async fn send_request_with_id(
        &mut self,
        request_id: String,
        method: String,
        params: Option<Value>,
    ) -> Result<JsonRpcResponse> {
        let request = JsonRpcRequest::new(request_id.clone(), method, params);
        let (tx, mut rx) = mpsc::channel(1); // 一个请求只需要一个响应
        {
            let mut pending = self.pending_requests.write().await;
            pending.insert(request_id, tx);
        }
        self.send_request_internal(request).await?;

        // Wait for response (with timeout)
        tokio::select! {
            response = rx.recv() => {
                response.ok_or_else(|| Error::Internal(anyhow::anyhow!("Response channel closed")))
            }
            _ = tokio::time::sleep(tokio::time::Duration::from_secs(30)) => {
                Err(Error::Timeout)
            }
        }
    }

    async fn send_request_internal(&self, request: JsonRpcRequest) -> Result<()> {
        self.request_tx
            .send(request)
            .await
            .map_err(|_| Error::Internal(anyhow::anyhow!("Request channel closed")))
    }

    pub async fn send_notification(&self, method: String, params: Option<Value>) -> Result<()> {
        let notification = JsonRpcNotification {
            jsonrpc: "2.0".to_string(),
            method: method.clone(),
            params,
        };

        debug!("Sending notification to {}: {}", self.server_name, method);
        self.notification_tx.send(notification).await
            .map_err(|_| Error::lsp_server(format!("Failed to send notification {}", method)))?;
        Ok(())
    }

    pub async fn shutdown(&mut self) -> Result<()> {
        info!("Shutting down LSP server: {}", self.server_name);

        // Send shutdown request
        if matches!(self.status, LspServerStatus::Running) {
            let _ = self.send_request("shutdown".to_string(), None).await;

            // Send exit notification
            let _ = self.send_notification("exit".to_string(), None).await;
        }

        // Kill the process if it's still running
        if let Some(mut process) = self.process.take() {
            let _ = process.kill().await;
            let _ = process.wait().await;
        }

        self.status = LspServerStatus::Stopped;
        info!("LSP server {} shut down", self.server_name);

        Ok(())
    }

    pub fn is_running(&self) -> bool {
        matches!(self.status, LspServerStatus::Running)
    }

    pub fn supports_filetype(&self, filetype: &str) -> bool {
        self.config.filetypes.contains(&filetype.to_string())
    }
}
