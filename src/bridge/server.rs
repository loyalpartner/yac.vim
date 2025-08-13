use crate::bridge::event::{Event, EventBus, EventSender};
use crate::bridge::correlation::RequestCorrelationManager;
use crate::bridge::ClientManager;
use crate::file::FileManager;
use crate::lsp::LspServerManager;
use crate::utils::{Config, Error, Result};
use std::net::SocketAddr;
use std::sync::Arc;
use tokio::net::TcpListener;
use tokio::sync::RwLock;
use tracing::{debug, error, info, instrument, warn};

pub struct BridgeServer {
    config: Config,
    listener: TcpListener,
    client_manager: Arc<RwLock<ClientManager>>,
    lsp_manager: Arc<RwLock<LspServerManager>>,
    file_manager: Arc<RwLock<FileManager>>,
    event_bus: Arc<EventBus>,
    event_sender: EventSender,
    correlation_manager: Arc<RequestCorrelationManager>,
}

impl BridgeServer {
    #[instrument(skip(config))]
    pub async fn new(config: Config) -> Result<Self> {
        let addr: SocketAddr = format!("{}:{}", config.server.host, config.server.port)
            .parse()
            .map_err(|e| Error::config(format!("Invalid server address: {}", e)))?;

        info!("Binding to address: {}", addr);
        let listener = TcpListener::bind(addr).await?;

        let (client_manager, event_rx, request_rx) =
            ClientManager::new(config.server.resource_limits.clone());
        let lsp_manager = LspServerManager::new_with_limits(
            config.lsp_servers.clone(),
            config.server.resource_limits.clone(),
        );
        let file_manager = FileManager::new();

        // 创建新的事件总线
        let event_bus = Arc::new(EventBus::new(&config.server.resource_limits));
        let event_sender = event_bus.get_sender();

        let correlation_manager = Arc::new(RequestCorrelationManager::new());
        // 启动关联管理器的清理任务
        correlation_manager.start_cleanup_task().await;

        let server = Self {
            config,
            listener,
            client_manager: Arc::new(RwLock::new(client_manager)),
            lsp_manager: Arc::new(RwLock::new(lsp_manager)),
            file_manager: Arc::new(RwLock::new(file_manager)),
            event_bus: event_bus.clone(),
            event_sender: event_sender.clone(),
            correlation_manager,
        };

        // 启动事件分发器
        event_bus.start_dispatcher().await?;

        // 启动客户端事件收集任务
        let event_sender_clone = event_sender.clone();
        tokio::spawn(async move {
            let mut event_rx = event_rx;
            let mut request_rx = request_rx;

            loop {
                tokio::select! {
                    Some((client_id, event)) = event_rx.recv() => {
                        let event = Event::vim_event(client_id, event);
                        if let Err(e) = event_sender_clone.emit(event).await {
                            error!("Failed to emit vim event: {}", e);
                        }
                    }
                    Some((client_id, request_id, request)) = request_rx.recv() => {
                        let event = Event::vim_request(client_id, request_id, request);
                        if let Err(e) = event_sender_clone.emit(event).await {
                            error!("Failed to emit vim request: {}", e);
                        }
                    }
                    else => break,
                }
            }
        });

        Ok(server)
    }

    /// 运行事件循环
    async fn run_event_loop(&self) {
        let mut event_handler = self.event_bus.create_handler();
        info!("Event handler started");

        loop {
            match event_handler.handle_next().await {
                Ok(Some(event)) => {
                    if let Err(e) = self.handle_event(event).await {
                        error!("Failed to handle event: {}", e);
                    }
                }
                Ok(None) => {
                    debug!("No more events to handle");
                    tokio::time::sleep(tokio::time::Duration::from_millis(10)).await;
                }
                Err(e) => {
                    error!("Error handling events: {}", e);
                    break;
                }
            }
        }

        warn!("Event handler stopped");
    }

    // 事件处理逻辑
    async fn handle_event(
        &self,
        event: Event,
    ) -> Result<()> {
        match event {
            Event::ClientConnected {
                client_id,
                event_id,
            } => {
                info!("Processing client connected: {} ({})", client_id, event_id);
                // 客户端连接时的初始化已在ClientManager中处理
                // 这里可以添加额外的状态跟踪或通知其他组件
            }

            Event::ClientDisconnected {
                client_id,
                event_id,
            } => {
                info!(
                    "Processing client disconnected: {} ({})",
                    client_id, event_id
                );
                // 清理该客户端相关的状态和资源
                // 这里可以通知LSP服务器关闭相关文档
            }

            Event::VimEvent {
                client_id,
                event: vim_event,
                event_id,
            } => {
                debug!(
                    "Processing vim event from {}: {:?} ({})",
                    client_id, vim_event, event_id
                );
                self.handle_vim_event(vim_event).await?;
            }

            Event::VimRequest {
                client_id,
                request_id,
                request,
                event_id,
            } => {
                info!(
                    "Processing vim request from {}: {:?} ({})",
                    client_id, request, event_id
                );
                self.handle_vim_request(client_id, request_id, request).await?;
            }

            Event::LspResponse {
                server_id,
                response,
                event_id,
            } => {
                debug!(
                    "Processing LSP response from {}: {:?} ({})",
                    server_id, response, event_id
                );
                // LSP响应的转发处理 - 需要根据请求ID找到对应的客户端
                self.handle_lsp_response(server_id, response, event_id).await?;
            }

            Event::LspNotification {
                server_id,
                method,
                params,
                event_id,
            } => {
                debug!(
                    "Processing LSP notification from {}: {} ({})",
                    server_id, method, event_id
                );
                // 处理LSP通知，如诊断信息等
                Self::handle_lsp_notification(server_id, method, params, event_id).await?;
            }
        }

        Ok(())
    }

    // 处理Vim事件
    async fn handle_vim_event(
        &self,
        vim_event: crate::lsp::protocol::VimEvent,
    ) -> Result<()> {
        use crate::lsp::protocol::VimEvent;

        match vim_event {
            VimEvent::FileOpened {
                uri,
                language_id,
                version,
                content,
            } => {
                info!("File opened: {} ({})", uri, language_id);

                // 启动适当的LSP服务器
                let mut lsp_manager = lsp_manager.write().await;
                if let Ok(server_id) = lsp_manager.find_server_for_filetype(&language_id).await {
                    info!("Found LSP server {} for {}", server_id, language_id);

                    // 发送didOpen通知到LSP服务器
                    let did_open_params = serde_json::json!({
                        "textDocument": {
                            "uri": uri,
                            "languageId": language_id,
                            "version": version,
                            "text": content
                        }
                    });

                    if let Err(e) = lsp_manager
                        .send_notification(
                            &server_id,
                            "textDocument/didOpen".to_string(),
                            Some(did_open_params),
                        )
                        .await
                    {
                        warn!("Failed to send didOpen to server {}: {}", server_id, e);
                    }
                } else {
                    warn!("No LSP server available for language: {}", language_id);
                }
            }

            VimEvent::FileChanged {
                uri,
                version,
                changes,
            } => {
                debug!("File changed: {} (v{})", uri, version);

                // 查找对应的LSP服务器
                let mut lsp_manager = lsp_manager.write().await;
                if let Ok(server_id) = lsp_manager.find_server_for_file(&uri).await {
                    let did_change_params = serde_json::json!({
                        "textDocument": {
                            "uri": uri,
                            "version": version
                        },
                        "contentChanges": changes
                    });

                    if let Err(e) = lsp_manager
                        .send_notification(
                            &server_id,
                            "textDocument/didChange".to_string(),
                            Some(did_change_params),
                        )
                        .await
                    {
                        warn!("Failed to send didChange to server {}: {}", server_id, e);
                    }
                }
            }

            VimEvent::FileSaved { uri } => {
                info!("File saved: {}", uri);

                // 发送didSave通知
                let mut lsp_manager = lsp_manager.write().await;
                if let Ok(server_id) = lsp_manager.find_server_for_file(&uri).await {
                    let did_save_params = serde_json::json!({
                        "textDocument": {
                            "uri": uri
                        }
                    });

                    if let Err(e) = lsp_manager
                        .send_notification(
                            &server_id,
                            "textDocument/didSave".to_string(),
                            Some(did_save_params),
                        )
                        .await
                    {
                        warn!("Failed to send didSave to server {}: {}", server_id, e);
                    }
                }
            }

            VimEvent::FileClosed { uri } => {
                info!("File closed: {}", uri);

                // 发送didClose通知
                let mut lsp_manager = lsp_manager.write().await;
                if let Ok(server_id) = lsp_manager.find_server_for_file(&uri).await {
                    let did_close_params = serde_json::json!({
                        "textDocument": {
                            "uri": uri
                        }
                    });

                    if let Err(e) = lsp_manager
                        .send_notification(
                            &server_id,
                            "textDocument/didClose".to_string(),
                            Some(did_close_params),
                        )
                        .await
                    {
                        warn!("Failed to send didClose to server {}: {}", server_id, e);
                    }
                }
            }

            VimEvent::CursorMoved { uri, position } => {
                debug!(
                    "Cursor moved in {}: {}:{}",
                    uri, position.line, position.character
                );
                // 通常不需要发送到LSP服务器
            }

            _ => {
                debug!("Unhandled vim event: {:?}", vim_event);
            }
        }

        Ok(())
    }

    // 处理Vim请求
    async fn handle_vim_request(
        &self,
        client_id: String,
        request_id: crate::lsp::jsonrpc::RequestId,
        vim_request: crate::lsp::protocol::VimRequest,
    ) -> Result<()> {
        use crate::lsp::protocol::VimRequest;

        match vim_request {
            VimRequest::Completion {
                uri,
                position,
                context,
            } => {
                info!(
                    "Completion request for {} at {}:{}",
                    uri, position.line, position.character
                );

                // 找到适当的LSP服务器并转发请求
                let lsp_manager = self.lsp_manager.read().await;
                if let Ok(server_id) = lsp_manager.find_server_for_file(&uri).await {
                    let completion_params = serde_json::json!({
                        "textDocument": {
                            "uri": uri
                        },
                        "position": {
                            "line": position.line,
                            "character": position.character
                        },
                        "context": context
                    });

                    // 使用新的关联机制发送请求
                    if let Err(e) = self.send_lsp_request_with_correlation(
                        &client_id,
                        Some(request_id), // Completion 请求可能需要Vim请求ID用于响应
                        &server_id,
                        "textDocument/completion".to_string(),
                        Some(completion_params),
                    ).await {
                        error!("Failed to send completion request with correlation: {}", e);
                    }
                } else {
                    warn!("No LSP server available for file: {}", uri);
                }
            }

            VimRequest::Hover { uri, position } => {
                info!(
                    "Hover request for {} at {}:{}",
                    uri, position.line, position.character
                );

                let mut lsp_manager = lsp_manager.write().await;
                if let Ok(server_id) = lsp_manager.find_server_for_file(&uri).await {
                    let hover_params = serde_json::json!({
                        "textDocument": {
                            "uri": uri
                        },
                        "position": {
                            "line": position.line,
                            "character": position.character
                        }
                    });

                    match lsp_manager
                        .send_request(
                            &server_id,
                            "textDocument/hover".to_string(),
                            Some(hover_params),
                        )
                        .await
                    {
                        Ok(response) => {
                            let result_value = match response.result {
                                crate::lsp::jsonrpc::JsonRpcResponseResult::Success { result } => {
                                    result
                                }
                                crate::lsp::jsonrpc::JsonRpcResponseResult::Error { .. } => {
                                    serde_json::Value::Null
                                }
                            };
                            let event = Event::lsp_response(server_id, result_value);
                            if let Err(e) = event_sender.emit(event).await {
                                error!("Failed to emit hover response event: {}", e);
                            }
                        }
                        Err(e) => {
                            warn!("Hover request failed for server {}: {}", server_id, e);
                        }
                    }
                } else {
                    warn!("No LSP server available for file: {}", uri);
                }
            }

            VimRequest::GotoDefinition { uri, position } => {
                info!(
                    "Go to definition request for {} at {}:{}",
                    uri, position.line, position.character
                );

                let mut lsp_manager = lsp_manager.write().await;
                if let Ok(server_id) = lsp_manager.find_server_for_file(&uri).await {
                    let definition_params = serde_json::json!({
                        "textDocument": {
                            "uri": uri
                        },
                        "position": {
                            "line": position.line,
                            "character": position.character
                        }
                    });

                    match lsp_manager
                        .send_request(
                            &server_id,
                            "textDocument/definition".to_string(),
                            Some(definition_params),
                        )
                        .await
                    {
                        Ok(response) => {
                            let result_value = match response.result {
                                crate::lsp::jsonrpc::JsonRpcResponseResult::Success { result } => {
                                    result
                                }
                                crate::lsp::jsonrpc::JsonRpcResponseResult::Error { .. } => {
                                    serde_json::Value::Null
                                }
                            };
                            let event = Event::lsp_response(server_id, result_value);
                            if let Err(e) = event_sender.emit(event).await {
                                error!("Failed to emit definition response event: {}", e);
                            }
                        }
                        Err(e) => {
                            warn!("Definition request failed for server {}: {}", server_id, e);
                        }
                    }
                } else {
                    warn!("No LSP server available for file: {}", uri);
                }
            }

            VimRequest::References {
                uri,
                position,
                context,
            } => {
                info!(
                    "Find references request for {} at {}:{}",
                    uri, position.line, position.character
                );

                let mut lsp_manager = lsp_manager.write().await;
                if let Ok(server_id) = lsp_manager.find_server_for_file(&uri).await {
                    let references_params = serde_json::json!({
                        "textDocument": {
                            "uri": uri
                        },
                        "position": {
                            "line": position.line,
                            "character": position.character
                        },
                        "context": context
                    });

                    match lsp_manager
                        .send_request(
                            &server_id,
                            "textDocument/references".to_string(),
                            Some(references_params),
                        )
                        .await
                    {
                        Ok(response) => {
                            let result_value = match response.result {
                                crate::lsp::jsonrpc::JsonRpcResponseResult::Success { result } => {
                                    result
                                }
                                crate::lsp::jsonrpc::JsonRpcResponseResult::Error { .. } => {
                                    serde_json::Value::Null
                                }
                            };
                            let event = Event::lsp_response(server_id, result_value);
                            if let Err(e) = event_sender.emit(event).await {
                                error!("Failed to emit references response event: {}", e);
                            }
                        }
                        Err(e) => {
                            warn!("References request failed for server {}: {}", server_id, e);
                        }
                    }
                } else {
                    warn!("No LSP server available for file: {}", uri);
                }
            }
        }

        Ok(())
    }

    // 处理LSP响应
    async fn handle_lsp_response(
        &self,
        server_id: String,
        response: serde_json::Value,
        event_id: crate::bridge::event::EventId,
    ) -> Result<()> {
        info!(
            "Handling LSP response from server {} ({})",
            server_id, event_id
        );

        // 从响应中提取请求ID
        if let Some(request_id) = response.get("id").and_then(|id| id.as_str()) {
            // 查找关联信息
            if let Some(correlation) = self.correlation_manager.take_correlation(&request_id.to_string()).await {
                debug!(
                    "Found correlation for request {}: client {}",
                    request_id, correlation.client_id
                );

                // 获取客户端管理器并转发响应
                let client_manager = self.client_manager.read().await;
                if let Some(client) = client_manager.get_client(&correlation.client_id) {
                    // 构造Vim响应消息
                    let vim_response = if let Some(vim_req_id) = correlation.vim_request_id {
                        // 如果有Vim请求ID，构造完整的响应
                        serde_json::json!({
                            "id": vim_req_id,
                            "result": response.get("result").unwrap_or(&serde_json::Value::Null),
                            "error": response.get("error")
                        })
                    } else {
                        // 否则直接转发结果
                        response.get("result").unwrap_or(&serde_json::Value::Null).clone()
                    };

                    // 发送响应给客户端（这里需要实现客户端的响应发送机制）
                    info!(
                        "Forwarding LSP response to client {} for method {}",
                        correlation.client_id, correlation.method
                    );

                    // 注意：这里需要根据实际的客户端通信机制来发送响应
                    // 可能需要通过TCP连接发送或者通过其他机制
                } else {
                    warn!("Client {} not found for LSP response", correlation.client_id);
                }
            } else {
                warn!(
                    "No correlation found for LSP request ID: {}. Response may be orphaned.",
                    request_id
                );
            }
        } else {
            warn!("LSP response missing request ID, cannot correlate: {:?}", response);
        }

        Ok(())
    }

    // 处理LSP通知
    async fn handle_lsp_notification(
        server_id: String,
        method: String,
        params: Option<serde_json::Value>,
        event_id: crate::bridge::event::EventId,
    ) -> Result<()> {
        debug!(
            "Handling LSP notification {} from server {} ({})",
            method, server_id, event_id
        );

        match method.as_str() {
            "textDocument/publishDiagnostics" => {
                // 处理诊断信息
                if let Some(params) = params {
                    info!(
                        "Received diagnostics from server {}: {:?}",
                        server_id, params
                    );
                    // TODO: 转发诊断信息给客户端
                }
            }
            "window/showMessage" => {
                // 处理服务器消息
                if let Some(params) = params {
                    info!("Server {} message: {:?}", server_id, params);
                    // TODO: 显示消息给用户
                }
            }
            "window/logMessage" => {
                // 处理日志消息
                if let Some(params) = params {
                    debug!("Server {} log: {:?}", server_id, params);
                }
            }
            _ => {
                debug!("Unhandled LSP notification: {}", method);
            }
        }

        Ok(())
    }

    #[instrument(skip(self))]
    pub async fn run(&mut self) -> Result<()> {
        info!(
            "LSP Bridge server listening on {}:{}",
            self.config.server.host, self.config.server.port
        );

        // 启动事件循环
        let server_ref = self as *const Self;
        tokio::spawn(async move {
            // SAFETY: 我们知道server在整个run期间都是有效的
            let server = unsafe { &*server_ref };
            server.run_event_loop().await;
        });

        loop {
            tokio::select! {
                // Handle new client connections
                result = self.listener.accept() => {
                    match result {
                        Ok((stream, addr)) => {
                            info!("New connection from: {}", addr);
                            self.handle_new_client(stream).await;
                        }
                        Err(e) => {
                            error!("Failed to accept connection: {}", e);
                        }
                    }
                }

                // Handle graceful shutdown signal (Ctrl+C)
                _ = tokio::signal::ctrl_c() => {
                    info!("Received shutdown signal, closing server...");
                    break;
                }
            }
        }

        self.shutdown().await?;
        Ok(())
    }

    async fn handle_new_client(&self, stream: tokio::net::TcpStream) {
        let client_manager = self.client_manager.clone();
        let event_sender = self.event_sender.clone();

        tokio::spawn(async move {
            let mut client_manager = client_manager.write().await;
            match client_manager.add_client(stream).await {
                Ok(client_id) => {
                    let event = Event::client_connected(client_id.clone());
                    if let Err(e) = event_sender.emit(event).await {
                        error!("Failed to emit client connected event: {}", e);
                    }
                    info!("Client {} connected successfully", client_id);
                }
                Err(e) => {
                    error!("Failed to add client: {}", e);
                }
            }
        });
    }

    pub async fn shutdown(&mut self) -> Result<()> {
        info!("Shutting down LSP Bridge server...");

        // Stop all LSP servers
        let mut lsp_manager = self.lsp_manager.write().await;
        lsp_manager.shutdown_all().await?;

        info!("LSP Bridge server shutdown complete");
        Ok(())
    }

    pub async fn get_client_count(&self) -> usize {
        let client_manager = self.client_manager.read().await;
        client_manager.client_count()
    }

    /// 发送LSP请求并建立关联
    async fn send_lsp_request_with_correlation(
        &self,
        client_id: &str,
        vim_request_id: Option<String>,
        server_id: &str,
        method: String,
        params: Option<serde_json::Value>,
    ) -> Result<()> {
        // 生成LSP请求ID
        let lsp_request_id = RequestCorrelationManager::generate_request_id();
        
        // 添加关联信息
        self.correlation_manager
            .add_correlation(
                lsp_request_id.clone(),
                client_id.to_string(),
                vim_request_id,
                server_id.to_string(),
                method.clone(),
                params.clone(),
            )
            .await?;

        debug!(
            "Sending LSP request {} to server {} for client {}",
            lsp_request_id, server_id, client_id
        );

        // 发送异步请求（不等待响应）
        let lsp_manager = self.lsp_manager.clone();
        let server_id_clone = server_id.to_string();
        let event_sender = self.event_sender.clone();
        let correlation_manager = self.correlation_manager.clone();

        tokio::spawn(async move {
            let result = {
                let mut manager = lsp_manager.write().await;
                manager.send_request_with_id(&server_id_clone, lsp_request_id.clone(), method.clone(), params).await
            };

            match result {
                Ok(response) => {
                    // 发送LSP响应事件
                    let event = Event::lsp_response(server_id_clone, serde_json::json!({
                        "id": lsp_request_id,
                        "result": match response.result {
                            crate::lsp::jsonrpc::JsonRpcResponseResult::Success { result } => result,
                            crate::lsp::jsonrpc::JsonRpcResponseResult::Error { error } => {
                                serde_json::json!({ "error": error })
                            }
                        }
                    }));

                    if let Err(e) = event_sender.emit(event).await {
                        error!("Failed to emit LSP response event: {}", e);
                    }
                }
                Err(e) => {
                    warn!("LSP request {} failed for server {} method {}: {}", 
                          lsp_request_id, server_id_clone, method, e);
                    
                    // 移除失败的关联
                    correlation_manager.take_correlation(&lsp_request_id).await;
                }
            }
        });

        Ok(())
    }
}
