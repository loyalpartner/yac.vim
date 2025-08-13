use crate::lsp::jsonrpc::{JsonRpcMessage, JsonRpcRequest, RequestId};
use crate::lsp::protocol::{ClientCapabilities, ClientInfo, VimCommand, VimEvent, VimRequest};
use crate::lsp::{format_lsp_message, LspMessageParser};
use crate::utils::{config::ResourceLimits, Error, Result};
use serde_json::Value;
use std::collections::HashMap;
use std::sync::Arc;
use tokio::io::{AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpStream;
use tokio::sync::mpsc;
use tracing::{debug, error, info, warn};
use uuid::Uuid;

pub type ClientId = String;

#[derive(Debug)]
pub struct VimClient {
    pub id: ClientId,
    pub info: ClientInfo,
    pub capabilities: ClientCapabilities,
    sender: mpsc::Sender<VimCommand>,
    pub receiver: mpsc::Receiver<Result<JsonRpcMessage>>,
}

pub struct ClientManager {
    clients: HashMap<ClientId, Arc<VimClient>>,
    event_tx: mpsc::Sender<(ClientId, VimEvent)>,
    request_tx: mpsc::Sender<(ClientId, RequestId, VimRequest)>,
    limits: ResourceLimits,
}

impl VimClient {
    pub async fn new(
        stream: TcpStream,
        event_tx: mpsc::Sender<(ClientId, VimEvent)>,
        request_tx: mpsc::Sender<(ClientId, RequestId, VimRequest)>,
        limits: &ResourceLimits,
    ) -> Result<Self> {
        let client_id = Uuid::new_v4().to_string();
        let (reader, writer) = stream.into_split();
        let mut reader = BufReader::new(reader);

        // Create bounded channels for communication
        let (command_tx, mut command_rx) =
            mpsc::channel::<VimCommand>(limits.client_command_queue_size);
        let (message_tx, message_rx) =
            mpsc::channel::<Result<JsonRpcMessage>>(limits.client_message_queue_size);

        let client_id_clone = client_id.clone();
        let event_tx_clone = event_tx.clone();
        let request_tx_clone = request_tx.clone();
        let message_tx_clone = message_tx.clone();

        // Spawn reader task with LSP message parser
        tokio::spawn(async move {
            let mut parser = LspMessageParser::new();
            let mut buffer = vec![0; 4096];

            loop {
                match reader.read(&mut buffer).await {
                    Ok(0) => {
                        debug!("Client {} disconnected", client_id_clone);
                        break;
                    }
                    Ok(n) => {
                        let data = String::from_utf8_lossy(&buffer[..n]);
                        debug!("Received {} bytes from client {}", n, client_id_clone);

                        match parser.parse_messages(&data) {
                            Ok(messages) => {
                                for message in messages {
                                    if let Err(e) = Self::handle_incoming_message(
                                        &client_id_clone,
                                        message,
                                        &event_tx_clone,
                                        &request_tx_clone,
                                    )
                                    .await
                                    {
                                        error!(
                                            "Error handling message from client {}: {}",
                                            client_id_clone, e
                                        );
                                    }
                                }
                            }
                            Err(e) => {
                                error!(
                                    "Failed to parse message from client {}: {}",
                                    client_id_clone, e
                                );
                                // 使用非阻塞发送避免阻塞读取任务
                                if let Err(_) = message_tx_clone.try_send(Err(e)) {
                                    warn!(
                                        "Message queue full for client {}, dropping error",
                                        client_id_clone
                                    );
                                }
                            }
                        }
                    }
                    Err(e) => {
                        error!("Error reading from client {}: {}", client_id_clone, e);
                        break;
                    }
                }
            }
        });

        // Spawn writer task
        let client_id_clone = client_id.clone();
        tokio::spawn(async move {
            let mut writer = writer;
            while let Some(command) = command_rx.recv().await {
                if let Err(e) = Self::send_command_to_writer(&mut writer, command).await {
                    error!("Error sending command to client {}: {}", client_id_clone, e);
                    break;
                }
            }
        });

        // Wait for client connection info
        // For now, create a default client
        let info = ClientInfo {
            name: "vim".to_string(),
            version: "9.0".to_string(),
            pid: 0,
        };

        let capabilities = ClientCapabilities::default();

        Ok(Self {
            id: client_id,
            info,
            capabilities,
            sender: command_tx,
            receiver: message_rx,
        })
    }

    async fn handle_incoming_message(
        client_id: &str,
        message: JsonRpcMessage,
        event_tx: &mpsc::Sender<(ClientId, VimEvent)>,
        request_tx: &mpsc::Sender<(ClientId, RequestId, VimRequest)>,
    ) -> Result<()> {
        match message {
            JsonRpcMessage::Request(req) => {
                debug!("Received request from client {}: {}", client_id, req.method);

                match Self::parse_vim_request(&req) {
                    Ok(vim_request) => {
                        // 使用非阻塞发送避免阻塞整个消息处理循环
                        match request_tx.try_send((client_id.to_string(), req.id, vim_request)) {
                            Ok(_) => {}
                            Err(mpsc::error::TrySendError::Full(_)) => {
                                warn!(
                                    "Request queue full for client {}, dropping request",
                                    client_id
                                );
                            }
                            Err(mpsc::error::TrySendError::Closed(_)) => {
                                warn!("Request channel closed");
                            }
                        }
                    }
                    Err(e) => {
                        warn!("Failed to parse request {}: {}", req.method, e);
                    }
                }
            }
            JsonRpcMessage::Notification(notif) => {
                debug!(
                    "Received notification from client {}: {}",
                    client_id, notif.method
                );

                match Self::parse_vim_event(&notif.method, notif.params) {
                    Ok(event) => {
                        // 使用非阻塞发送避免阻塞整个消息处理循环
                        match event_tx.try_send((client_id.to_string(), event)) {
                            Ok(_) => {}
                            Err(mpsc::error::TrySendError::Full(_)) => {
                                warn!("Event queue full for client {}, dropping event", client_id);
                            }
                            Err(mpsc::error::TrySendError::Closed(_)) => {
                                warn!("Event channel closed");
                            }
                        }
                    }
                    Err(e) => {
                        warn!("Failed to parse event {}: {}", notif.method, e);
                    }
                }
            }
            JsonRpcMessage::Response(_) => {
                debug!("Received response from client {}", client_id);
                // Handle responses if needed
            }
        }

        Ok(())
    }

    fn parse_vim_request(req: &JsonRpcRequest) -> Result<VimRequest> {
        let params = req.params.as_ref().unwrap_or(&Value::Null);

        let vim_request = match req.method.as_str() {
            "completion" => {
                let uri = params["uri"].as_str().unwrap_or("").to_string();
                let position = serde_json::from_value(params["position"].clone())?;
                let context = if params["context"].is_null() {
                    None
                } else {
                    Some(serde_json::from_value(params["context"].clone())?)
                };

                VimRequest::Completion {
                    uri,
                    position,
                    context,
                }
            }
            "hover" => {
                let uri = params["uri"].as_str().unwrap_or("").to_string();
                let position = serde_json::from_value(params["position"].clone())?;

                VimRequest::Hover { uri, position }
            }
            _ => {
                return Err(Error::protocol(format!(
                    "Unknown request method: {}",
                    req.method
                )))
            }
        };

        Ok(vim_request)
    }

    fn parse_vim_event(method: &str, params: Option<Value>) -> Result<VimEvent> {
        let params = params.unwrap_or(Value::Null);

        let event = match method {
            "client_connect" => {
                debug!("Client connecting with info: {:?}", params);
                // 客户端连接事件，暂时创建一个占位事件
                return Ok(VimEvent::FileOpened {
                    uri: "client_connect".to_string(),
                    language_id: "system".to_string(),
                    version: 1,
                    content: "".to_string(),
                });
            }
            "file_opened" => {
                let uri = params["uri"].as_str().unwrap_or("").to_string();
                let language_id = params["language_id"].as_str().unwrap_or("").to_string();
                let version = params["version"].as_i64().unwrap_or(1) as i32;
                let content = params["content"].as_str().unwrap_or("").to_string();

                VimEvent::FileOpened {
                    uri,
                    language_id,
                    version,
                    content,
                }
            }
            "file_changed" => {
                let uri = params["uri"].as_str().unwrap_or("").to_string();
                let version = params["version"].as_i64().unwrap_or(1) as i32;
                let changes = serde_json::from_value(params["changes"].clone())?;

                VimEvent::FileChanged {
                    uri,
                    version,
                    changes,
                }
            }
            _ => return Err(Error::protocol(format!("Unknown event method: {}", method))),
        };

        Ok(event)
    }

    async fn send_command_to_writer(
        writer: &mut tokio::net::tcp::OwnedWriteHalf,
        command: VimCommand,
    ) -> Result<()> {
        let json = serde_json::to_string(&command)?;
        let lsp_message = format_lsp_message(&json);

        debug!("Sending command to client: {} bytes", lsp_message.len());
        writer.write_all(lsp_message.as_bytes()).await?;
        writer.flush().await?;

        Ok(())
    }

    pub async fn send_command(&self, command: VimCommand) -> Result<()> {
        self.sender
            .send(command)
            .await
            .map_err(|_| Error::Internal(anyhow::anyhow!("Client sender channel closed")))
    }
}

impl ClientManager {
    pub fn new(
        limits: ResourceLimits,
    ) -> (
        Self,
        mpsc::Receiver<(ClientId, VimEvent)>,
        mpsc::Receiver<(ClientId, RequestId, VimRequest)>,
    ) {
        let (event_tx, event_rx) = mpsc::channel(limits.event_queue_size);
        let (request_tx, request_rx) = mpsc::channel(limits.event_queue_size);

        let manager = Self {
            clients: HashMap::new(),
            event_tx,
            request_tx,
            limits,
        };

        (manager, event_rx, request_rx)
    }

    pub async fn add_client(&mut self, stream: TcpStream) -> Result<ClientId> {
        // 检查客户端数量限制
        if self.clients.len() >= self.limits.max_concurrent_clients {
            return Err(Error::Internal(anyhow::anyhow!(
                "Maximum number of concurrent clients reached: {}",
                self.limits.max_concurrent_clients
            )));
        }

        let client = VimClient::new(
            stream,
            self.event_tx.clone(),
            self.request_tx.clone(),
            &self.limits,
        )
        .await?;
        let client_id = client.id.clone();

        info!(
            "New client connected: {} (total: {})",
            client_id,
            self.clients.len() + 1
        );
        self.clients.insert(client_id.clone(), Arc::new(client));

        Ok(client_id)
    }

    pub fn remove_client(&mut self, client_id: &str) {
        if self.clients.remove(client_id).is_some() {
            info!("Client {} disconnected", client_id);
        }
    }

    pub fn get_client(&self, client_id: &str) -> Option<Arc<VimClient>> {
        self.clients.get(client_id).cloned()
    }

    pub fn client_count(&self) -> usize {
        self.clients.len()
    }
}
