use crate::bridge::event::{Event, EventBus, EventSender};
use crate::bridge::correlation::RequestCorrelationManager;
use crate::bridge::ClientManager;
use crate::file::FileManager;
use crate::lsp::LspServerManager;
use crate::lsp::jsonrpc::RequestId;
use crate::utils::{Config, Error, Result};
use crate::utils::security::SecurityManager;
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
    security_manager: Arc<SecurityManager>,
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

        // 创建安全管理器
        let rate_config = crate::utils::security::RateLimitConfig::default();
        let validator = crate::utils::security::InputValidator::default();
        let security_manager = Arc::new(SecurityManager::new(rate_config, validator));

        let server = Self {
            config,
            listener,
            client_manager: Arc::new(RwLock::new(client_manager)),
            lsp_manager: Arc::new(RwLock::new(lsp_manager)),
            file_manager: Arc::new(RwLock::new(file_manager)),
            event_bus: event_bus.clone(),
            event_sender: event_sender.clone(),
            correlation_manager,
            security_manager,
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

    /// 静态事件处理方法 - 用于tokio任务
    async fn handle_event_static(
        event: Event,
        lsp_manager: &Arc<RwLock<LspServerManager>>,
        client_manager: &Arc<RwLock<ClientManager>>,
        file_manager: &Arc<RwLock<FileManager>>,
        event_sender: &EventSender,
        correlation_manager: &Arc<RequestCorrelationManager>,
        security_manager: &Arc<SecurityManager>,
    ) -> Result<()> {
        match event {
            Event::ClientConnected {
                client_id,
                event_id,
            } => {
                info!(
                    "Client {} connected ({})",
                    client_id, event_id
                );
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
                Self::handle_vim_event_static(vim_event, lsp_manager, client_manager, file_manager, event_sender, correlation_manager, security_manager).await?;
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
                Self::handle_vim_request_static(
                    client_id, 
                    request_id, 
                    request, 
                    lsp_manager, 
                    client_manager,
                    file_manager,
                    event_sender, 
                    correlation_manager,
                    security_manager
                ).await?;
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
                Self::handle_lsp_response_static(
                    server_id, 
                    response, 
                    event_id, 
                    client_manager, 
                    correlation_manager
                ).await?;
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
                let notification = serde_json::json!({
                    "method": method,
                    "params": params
                });
                Self::handle_lsp_notification_static(server_id, notification, event_id, client_manager).await?;
            }

            _ => {
                debug!("Unhandled event: {:?}", event);
            }
        }

        Ok(())
    }

    // 事件处理逻辑
    async fn handle_event(
        &self,
        event: Event,
    ) -> Result<()> {
        // Clone shared resources for static method calls
        let lsp_manager_clone = self.lsp_manager.clone();
        let client_manager_clone = self.client_manager.clone();
        let file_manager_clone = self.file_manager.clone();
        let event_sender_clone = self.event_sender.clone();
        let correlation_manager_clone = self.correlation_manager.clone();
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
                // Handle vim event using static method  
                Self::handle_vim_event_static(
                    vim_event,
                    &lsp_manager_clone,
                    &client_manager_clone,
                    &file_manager_clone,
                    &event_sender_clone,
                    &correlation_manager_clone,
                    &self.security_manager
                ).await?;
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
                // Handle vim request using static method
                Self::handle_vim_request_static(
                    client_id,
                    request_id,
                    request,
                    &lsp_manager_clone,
                    &client_manager_clone,
                    &file_manager_clone,
                    &event_sender_clone,
                    &correlation_manager_clone,
                    &self.security_manager
                ).await?;
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
                debug!("Processing LSP response for server: {}", server_id);
                Self::handle_lsp_response_static(
                    server_id, 
                    response, 
                    event_id, 
                    &self.client_manager, 
                    &self.correlation_manager
                ).await?;
                debug!("LSP response processing completed");
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


    // 处理Vim事件（静态版本）
    async fn handle_vim_event_static(
        vim_event: crate::lsp::protocol::VimEvent,
        lsp_manager: &Arc<RwLock<LspServerManager>>,
        _client_manager: &Arc<RwLock<ClientManager>>,
        _file_manager: &Arc<RwLock<FileManager>>,
        _event_sender: &EventSender,
        _correlation_manager: &Arc<RequestCorrelationManager>,
        security_manager: &Arc<SecurityManager>,
    ) -> Result<()> {
        use crate::lsp::protocol::VimEvent;

        match vim_event {
            VimEvent::FileOpened {
                uri,
                language_id,
                version,
                content,
            } => {
                info!("📥 [v->b] File opened: {} ({})", uri, language_id);
                debug!("📥 [v->b] File content preview: {:?}", content.chars().take(100).collect::<String>());

                // 根据文件路径确定工作区根目录
                let workspace_root = crate::utils::workspace::find_workspace_root(&uri);
                debug!("📍 Workspace root for {}: {:?}", uri, workspace_root);

                // 启动适当的LSP服务器
                let mut lsp_manager = lsp_manager.write().await;
                
                // 先尝试查找现有服务器
                let server_result = if workspace_root.is_some() {
                    // 如果有特定的工作区根目录，启动带有自定义根目录的服务器
                    lsp_manager.start_server_with_root(&format!("{}-analyzer", language_id), workspace_root).await
                } else {
                    // 否则使用默认的服务器启动方式
                    lsp_manager.find_server_for_filetype(&language_id).await
                };
                
                if let Ok(server_id) = server_result {
                    info!("✅ Found/Started LSP server {} for {} with workspace root", server_id, language_id);

                    // 发送didOpen通知到LSP服务器
                    let did_open_params = serde_json::json!({
                        "textDocument": {
                            "uri": uri,
                            "languageId": language_id,
                            "version": version,
                            "text": content
                        }
                    });

                    info!("📤 [b->l] Sending textDocument/didOpen to {}", server_id);
                    debug!("📤 [b->l] didOpen params: {}", serde_json::to_string_pretty(&did_open_params).unwrap_or_default());

                    if let Err(e) = lsp_manager
                        .send_notification(
                            &server_id,
                            "textDocument/didOpen".to_string(),
                            Some(did_open_params),
                        )
                        .await
                    {
                        warn!("❌ Failed to send didOpen to server {}: {}", server_id, e);
                    } else {
                        info!("✅ Successfully sent didOpen to server {}", server_id);
                    }
                } else {
                    warn!("⚠️ No LSP server available for language: {}", language_id);
                }
            }

            VimEvent::FileChanged { uri, version, changes } => {
                info!("📥 [v->b] File changed: {} (version {})", uri, version);
                debug!("📥 [v->b] File changes: {:?}", changes);

                // 发送didChange通知到所有相关的LSP服务器
                let mut lsp_manager = lsp_manager.write().await;
                if let Ok(server_id) = lsp_manager.find_server_for_file(&uri).await {
                    let did_change_params = serde_json::json!({
                        "textDocument": {
                            "uri": uri,
                            "version": version
                        },
                        "contentChanges": changes
                    });

                    info!("📤 [b->l] Sending textDocument/didChange to {}", server_id);
                    debug!("📤 [b->l] didChange params: {}", serde_json::to_string_pretty(&did_change_params).unwrap_or_default());

                    if let Err(e) = lsp_manager
                        .send_notification(
                            &server_id,
                            "textDocument/didChange".to_string(),
                            Some(did_change_params),
                        )
                        .await
                    {
                        warn!("❌ Failed to send didChange to server {}: {}", server_id, e);
                    } else {
                        info!("✅ Successfully sent didChange to server {}", server_id);
                    }
                } else {
                    warn!("⚠️ No LSP server found for file: {}", uri);
                }
            }

            VimEvent::FileClosed { uri } => {
                info!("File closed: {}", uri);

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

    // 处理Vim请求（静态版本）
    async fn handle_vim_request_static(
        client_id: String,
        request_id: crate::lsp::jsonrpc::RequestId,
        vim_request: crate::lsp::protocol::VimRequest,
        lsp_manager: &Arc<RwLock<LspServerManager>>,
        client_manager: &Arc<RwLock<ClientManager>>,
        _file_manager: &Arc<RwLock<FileManager>>,
        _event_sender: &EventSender,
        correlation_manager: &Arc<RequestCorrelationManager>,
        security_manager: &Arc<SecurityManager>,
    ) -> Result<()> {
        use crate::lsp::protocol::VimRequest;

        match vim_request {
            VimRequest::Completion {
                uri,
                position,
                context,
            } => {
                // 安全检查：请求速率限制
                if let Err(e) = security_manager.check_request_rate(&client_id, "completion").await {
                    warn!("Completion request from {} rejected due to rate limiting: {}", client_id, e);
                    return Ok(());
                }

                // 安全检查：输入验证
                if let Err(e) = security_manager.validate_uri(&uri) {
                    warn!("Invalid URI in completion request from {}: {}", client_id, e);
                    return Ok(());
                }
                if let Err(e) = security_manager.validate_position(&position) {
                    warn!("Invalid position in completion request from {}: {}", client_id, e);
                    return Ok(());
                }

                info!(
                    "📥 [v->b] Completion request for {} at {}:{} from client {}",
                    uri, position.line, position.character, client_id
                );
                debug!("📥 [v->b] Completion context: {:?}", context);

                // 找到适当的LSP服务器并转发请求
                let server_id = {
                    let mut lsp_manager_guard = lsp_manager.write().await;
                    lsp_manager_guard.find_server_for_file(&uri).await
                };
                
                if let Ok(server_id) = server_id {
                    info!("✅ Found LSP server {} for completion request", server_id);
                    
                    let mut completion_params = serde_json::json!({
                        "textDocument": {
                            "uri": uri
                        },
                        "position": {
                            "line": position.line,
                            "character": position.character
                        }
                    });
                    
                    // 添加context，转换为LSP协议的camelCase格式
                    if let Some(ctx) = context {
                        completion_params["context"] = serde_json::json!({
                            "triggerKind": ctx.trigger_kind,
                            "triggerCharacter": ctx.trigger_character
                        });
                    }

                    info!("📤 [b->l] Sending textDocument/completion request to {}", server_id);
                    debug!("📤 [b->l] Completion params: {}", serde_json::to_string_pretty(&completion_params).unwrap_or_default());

                    // 使用新的关联机制发送请求
                    if let Err(e) = Self::send_lsp_request_with_correlation_static(
                        &client_id,
                        Some(request_id.to_string()), // Completion 请求需要Vim请求ID用于响应
                        &server_id,
                        "textDocument/completion".to_string(),
                        Some(completion_params),
                        lsp_manager,
                        correlation_manager,
                        _event_sender,
                    ).await {
                        error!("❌ Failed to send completion request with correlation: {}", e);
                    } else {
                        info!("✅ Successfully sent completion request to server {}", server_id);
                    }
                } else {
                    warn!("⚠️ No LSP server available for file: {}", uri);
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
                            if let Err(e) = _event_sender.emit(event).await {
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
                            if let Err(e) = _event_sender.emit(event).await {
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
                            if let Err(e) = _event_sender.emit(event).await {
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
            "📥 [b<-l] Handling LSP response from server {} ({})",
            server_id, event_id
        );
        debug!("📥 [b<-l] LSP response content: {}", serde_json::to_string_pretty(&response).unwrap_or_default());

        // 从响应中提取请求ID
        if let Some(request_id_value) = response.get("id") {
            // 将 JSON Value 转换为 RequestId
            let request_id = if let Some(s) = request_id_value.as_str() {
                RequestId::String(s.to_string())
            } else if let Some(n) = request_id_value.as_i64() {
                RequestId::Number(n)
            } else {
                warn!("Invalid request ID format in response: {:?}", request_id_value);
                return Ok(());
            };
            
            // 查找关联信息
            if let Some(correlation) = self.correlation_manager.take_correlation(&request_id).await {
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
                        "📤 [v<-b] Forwarding LSP response to client {} for method {}",
                        correlation.client_id, correlation.method
                    );
                    debug!("📤 [v<-b] Vim response content: {}", serde_json::to_string_pretty(&vim_response).unwrap_or_default());

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

        // 启动事件循环 - 使用Arc来安全地共享
        let event_bus = self.event_bus.clone();
        let lsp_manager = self.lsp_manager.clone();
        let client_manager = self.client_manager.clone();
        let file_manager = self.file_manager.clone();
        let event_sender = self.event_sender.clone();
        let correlation_manager = self.correlation_manager.clone();
        let security_manager = self.security_manager.clone();
        
        tokio::spawn(async move {
            let mut event_handler = event_bus.create_handler();
            info!("Event handler started");

            loop {
                match event_handler.handle_next().await {
                    Ok(Some(event)) => {
                        if let Err(e) = Self::handle_event_static(
                            event,
                            &lsp_manager,
                            &client_manager,
                            &file_manager,
                            &event_sender,
                            &correlation_manager,
                            &security_manager,
                        ).await {
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
        let security_manager = self.security_manager.clone();

        tokio::spawn(async move {
            // 获取客户端地址用于安全检查
            let peer_addr = match stream.peer_addr() {
                Ok(addr) => addr.ip().to_string(),
                Err(e) => {
                    error!("Failed to get client address: {}", e);
                    return;
                }
            };

            // 安全检查：速率限制
            if let Err(e) = security_manager.check_connection_rate(&peer_addr).await {
                warn!("Connection from {} rejected due to rate limiting: {}", peer_addr, e);
                return;
            }

            let mut client_manager = client_manager.write().await;
            match client_manager.add_client(stream).await {
                Ok(client_id) => {
                    let event = Event::client_connected(client_id.clone());
                    if let Err(e) = event_sender.emit(event).await {
                        error!("Failed to emit client connected event: {}", e);
                    }
                    info!("Client {} connected successfully from {}", client_id, peer_addr);
                }
                Err(e) => {
                    error!("Failed to add client from {}: {}", peer_addr, e);
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

    /// 发送LSP请求并建立关联（静态版本）
    async fn send_lsp_request_with_correlation_static(
        client_id: &str,
        vim_request_id: Option<String>,
        server_id: &str,
        method: String,
        params: Option<serde_json::Value>,
        lsp_manager: &Arc<RwLock<LspServerManager>>,
        correlation_manager: &Arc<RequestCorrelationManager>,
        event_sender: &EventSender,
    ) -> Result<()> {
        // 生成LSP请求ID
        let lsp_request_id = RequestCorrelationManager::generate_request_id();
        
        // 添加关联信息
        correlation_manager
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
        let lsp_manager = lsp_manager.clone();
        let server_id_clone = server_id.to_string();
        let event_sender = event_sender.clone();
        let correlation_manager = correlation_manager.clone();

        tokio::spawn(async move {
            let result = {
                let mut manager = lsp_manager.write().await;
                manager.send_request_with_id(&server_id_clone, lsp_request_id.to_string(), method.clone(), params).await
            };

            match result {
                Ok(response) => {
                    // 发送LSP响应事件
                    let response_json = match response.result {
                        crate::lsp::jsonrpc::JsonRpcResponseResult::Success { result } => {
                            serde_json::json!({
                                "jsonrpc": "2.0",
                                "id": lsp_request_id,
                                "result": result
                            })
                        }
                        crate::lsp::jsonrpc::JsonRpcResponseResult::Error { error } => {
                            serde_json::json!({
                                "jsonrpc": "2.0", 
                                "id": lsp_request_id,
                                "error": error
                            })
                        }
                    };
                    
                    let event = Event::lsp_response(server_id_clone, response_json);

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
                manager.send_request_with_id(&server_id_clone, lsp_request_id.to_string(), method.clone(), params).await
            };

            match result {
                Ok(response) => {
                    // 发送LSP响应事件
                    let response_json = match response.result {
                        crate::lsp::jsonrpc::JsonRpcResponseResult::Success { result } => {
                            serde_json::json!({
                                "jsonrpc": "2.0",
                                "id": lsp_request_id,
                                "result": result
                            })
                        }
                        crate::lsp::jsonrpc::JsonRpcResponseResult::Error { error } => {
                            serde_json::json!({
                                "jsonrpc": "2.0", 
                                "id": lsp_request_id,
                                "error": error
                            })
                        }
                    };
                    
                    let event = Event::lsp_response(server_id_clone, response_json);

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

    /// 处理LSP响应（静态版本）
    async fn handle_lsp_response_static(
        server_id: String,
        response: serde_json::Value,
        _event_id: crate::bridge::event::EventId,
        client_manager: &Arc<RwLock<ClientManager>>,
        correlation_manager: &Arc<RequestCorrelationManager>,
    ) -> Result<()> {
        info!(
            "Handling LSP response from server {}",
            server_id
        );

        // 从响应中提取请求ID
        if let Some(request_id_value) = response.get("id") {
            // 将 JSON Value 转换为 RequestId
            let request_id = if let Some(s) = request_id_value.as_str() {
                RequestId::String(s.to_string())
            } else if let Some(n) = request_id_value.as_i64() {
                RequestId::Number(n)
            } else {
                warn!("Invalid request ID format in response: {:?}", request_id_value);
                return Ok(());
            };
            
            // 查找关联信息
            if let Some(correlation) = correlation_manager.take_correlation(&request_id).await {
                debug!(
                    "Found correlation for request {}: client {}",
                    request_id, correlation.client_id
                );

                // 获取客户端管理器并转发响应
                let client_manager = client_manager.read().await;
                if let Some(client) = client_manager.get_client(&correlation.client_id) {
                    // 根据请求方法处理不同类型的响应
                    match correlation.method.as_str() {
                        "textDocument/completion" => {
                            let vim_req_id = correlation.vim_request_id.clone().unwrap_or_default();
                            if let Some(result) = response.get("result") {
                                // 解析LSP completion响应并转换为Vim命令
                                match Self::parse_completion_response(&correlation.client_id, &vim_req_id, result.clone()) {
                                    Ok(vim_command) => {
                                        if let Err(e) = client.send_command(vim_command).await {
                                            error!("Failed to send completion to client {}: {}", correlation.client_id, e);
                                        } else {
                                            info!("Successfully sent completion to client {}", correlation.client_id);
                                        }
                                    }
                                    Err(e) => {
                                        warn!("Failed to parse completion response: {}", e);
                                        // 发送空的completion作为fallback
                                        let empty_completion = crate::lsp::protocol::VimCommand::ShowCompletion {
                                            request_id: vim_req_id,
                                            position: crate::lsp::protocol::Position { line: 0, character: 0 },
                                            items: vec![],
                                            incomplete: false,
                                        };
                                        let _ = client.send_command(empty_completion).await;
                                    }
                                }
                            }
                        }
                        _ => {
                            // 对于其他类型的请求，使用通用响应处理
                            info!(
                                "Forwarding LSP response to client {} for method {}",
                                correlation.client_id, correlation.method
                            );
                            // TODO: 实现其他类型响应的处理
                        }
                    }
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

    /// 处理LSP通知（静态版本）
    async fn handle_lsp_notification_static(
        server_id: String,
        notification: serde_json::Value,
        _event_id: crate::bridge::event::EventId,
        _client_manager: &Arc<RwLock<ClientManager>>,
    ) -> Result<()> {
        info!(
            "Handling LSP notification from server {}: {:?}",
            server_id, notification
        );

        // 处理LSP通知，例如诊断信息
        // TODO: 转发诊断信息给客户端
        if let Some(method) = notification.get("method").and_then(|m| m.as_str()) {
            match method {
                "textDocument/publishDiagnostics" => {
                    debug!("Received diagnostics from server {}", server_id);
                    // TODO: 转发诊断信息给客户端
                }
                "window/showMessage" => {
                    debug!("Received message from server {}", server_id);
                    // TODO: 显示消息给用户
                }
                _ => {
                    debug!("Unhandled LSP notification method: {}", method);
                }
            }
        }

        Ok(())
    }

    /// 解析LSP completion响应并转换为VimCommand
    pub fn parse_completion_response(
        _client_id: &str,
        request_id: &str,
        result: serde_json::Value,
    ) -> Result<crate::lsp::protocol::VimCommand> {
        // 解析completion items
        let items = if result.is_array() {
            // CompletionItem[]
            result.as_array().unwrap().clone()
        } else if result.is_object() && result.get("items").is_some() {
            // CompletionList
            result["items"].as_array().unwrap().clone()
        } else {
            return Ok(crate::lsp::protocol::VimCommand::ShowCompletion {
                request_id: request_id.to_string(),
                position: crate::lsp::protocol::Position { line: 0, character: 0 },
                items: vec![],
                incomplete: false,
            });
        };

        let mut completion_items = Vec::new();

        for (index, item) in items.iter().enumerate() {
            let label = item["label"].as_str().unwrap_or("").to_string();
            if label.is_empty() {
                continue;
            }

            let kind = item["kind"].as_i64().unwrap_or(1) as i32;
            let detail = item["detail"].as_str().map(|s| s.to_string());
            let documentation = item["documentation"]
                .as_str()
                .or_else(|| item["documentation"]["value"].as_str())
                .map(|s| s.to_string());

            let insert_text = item["insertText"]
                .as_str()
                .or_else(|| item["textEdit"]["newText"].as_str())
                .unwrap_or(&label)
                .to_string();

            let sort_text = item["sortText"]
                .as_str()
                .unwrap_or(&format!("{:04}", index))
                .to_string();

            let completion_item = crate::lsp::protocol::CompletionItem {
                id: format!("completion_item_{}", index),
                label,
                kind,
                detail,
                documentation,
                insert_text: Some(insert_text),
                sort_text: Some(sort_text),
            };

            completion_items.push(completion_item);
        }

        // 按sort_text排序
        completion_items.sort_by(|a, b| {
            let a_sort = a.sort_text.as_ref().unwrap_or(&a.label);
            let b_sort = b.sort_text.as_ref().unwrap_or(&b.label);
            a_sort.cmp(b_sort)
        });

        let incomplete = result.get("isIncomplete").and_then(|v| v.as_bool()).unwrap_or(false);

        debug!("Parsed {} completion items", completion_items.len());

        Ok(crate::lsp::protocol::VimCommand::ShowCompletion {
            request_id: request_id.to_string(),
            position: crate::lsp::protocol::Position { line: 0, character: 0 }, // TODO: Get actual position
            items: completion_items,
            incomplete,
        })
    }
}
