use crate::bridge::event::{Event, EventBus, EventSender};
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

        let server = Self {
            config,
            listener,
            client_manager: Arc::new(RwLock::new(client_manager)),
            lsp_manager: Arc::new(RwLock::new(lsp_manager)),
            file_manager: Arc::new(RwLock::new(file_manager)),
            event_bus: event_bus.clone(),
            event_sender: event_sender.clone(),
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

        // 启动事件处理任务
        let mut event_handler = event_bus.create_handler();
        let lsp_manager_clone = server.lsp_manager.clone();
        let file_manager_clone = server.file_manager.clone();
        let event_sender_clone = event_sender.clone();

        tokio::spawn(async move {
            info!("Event handler started");

            loop {
                match event_handler.handle_next().await {
                    Ok(Some(event)) => {
                        if let Err(e) = Self::handle_event(
                            event,
                            &lsp_manager_clone,
                            &file_manager_clone,
                            &event_sender_clone,
                        )
                        .await
                        {
                            error!("Failed to handle event: {}", e);
                        }
                    }
                    Ok(None) => {
                        info!("Event handler shutting down");
                        break;
                    }
                    Err(e) => {
                        error!("Error in event handler: {}", e);
                        break;
                    }
                }
            }
        });

        Ok(server)
    }

    // 事件处理逻辑
    async fn handle_event(
        event: Event,
        lsp_manager: &Arc<RwLock<LspServerManager>>,
        file_manager: &Arc<RwLock<FileManager>>,
        event_sender: &EventSender,
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
                Self::handle_vim_event(vim_event, lsp_manager, file_manager, event_sender).await?;
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
                Self::handle_vim_request(client_id, request_id, request, lsp_manager, event_sender)
                    .await?;
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
                Self::handle_lsp_response(server_id, response, event_id).await?;
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
        vim_event: crate::lsp::protocol::VimEvent,
        lsp_manager: &Arc<RwLock<LspServerManager>>,
        file_manager: &Arc<RwLock<FileManager>>,
        event_sender: &EventSender,
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
        client_id: String,
        request_id: crate::lsp::jsonrpc::RequestId,
        vim_request: crate::lsp::protocol::VimRequest,
        lsp_manager: &Arc<RwLock<LspServerManager>>,
        event_sender: &EventSender,
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
                let mut lsp_manager = lsp_manager.write().await;
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

                    match lsp_manager
                        .send_request(
                            &server_id,
                            "textDocument/completion".to_string(),
                            Some(completion_params),
                        )
                        .await
                    {
                        Ok(response) => {
                            info!("Received completion response from server: {}", server_id);
                            // 需要将响应转发回客户端 - 这里可以发送事件
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
                                error!("Failed to emit LSP response event: {}", e);
                            }
                        }
                        Err(e) => {
                            warn!("Completion request failed for server {}: {}", server_id, e);
                        }
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
        server_id: String,
        response: serde_json::Value,
        event_id: crate::bridge::event::EventId,
    ) -> Result<()> {
        // TODO: 根据请求ID找到对应的客户端并转发响应
        // 这需要维护请求ID到客户端ID的映射
        info!(
            "Handling LSP response from server {} ({})",
            server_id, event_id
        );

        // 解析响应并转发给对应的客户端
        // 这里需要实现请求-响应的关联机制

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
}
