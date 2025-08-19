//! Mock LSP server for testing

use crate::{JsonRpcMessage, JsonRpcRequest, JsonRpcResponse, LspError, Result};
use serde_json::Value;
use std::collections::HashMap;
use tokio::sync::mpsc;

/// A mock LSP server that can be programmed to respond to specific requests
pub struct MockLspServer {
    handlers: HashMap<String, Box<dyn Fn(&JsonRpcRequest) -> Result<Value> + Send + Sync>>,
    message_tx: mpsc::Sender<String>,
    message_rx: mpsc::Receiver<String>,
}

impl MockLspServer {
    pub fn new() -> (Self, MockLspClient) {
        let (server_tx, server_rx) = mpsc::channel(100);
        let (client_tx, client_rx) = mpsc::channel(100);

        let server = MockLspServer {
            handlers: HashMap::new(),
            message_tx: client_tx,
            message_rx: server_rx,
        };

        let client = MockLspClient {
            message_tx: server_tx,
            message_rx: client_rx,
        };

        (server, client)
    }

    /// Register a handler for a specific LSP method
    pub fn on_request<F>(&mut self, method: &str, handler: F)
    where
        F: Fn(&JsonRpcRequest) -> Result<Value> + Send + Sync + 'static,
    {
        self.handlers.insert(method.to_string(), Box::new(handler));
    }

    /// Register a simple handler that returns a fixed response
    pub fn on_request_simple(&mut self, method: &str, response: Value) {
        let response = response.clone();
        self.on_request(method, move |_| Ok(response.clone()));
    }

    /// Run the mock server, processing incoming requests
    pub async fn run(&mut self) -> Result<()> {
        while let Some(message) = self.message_rx.recv().await {
            if let Ok(msg) = serde_json::from_str::<JsonRpcMessage>(&message) {
                match msg {
                    JsonRpcMessage::Request(request) => {
                        let response = if let Some(handler) = self.handlers.get(&request.method) {
                            match handler(&request) {
                                Ok(result) => JsonRpcResponse {
                                    jsonrpc: "2.0".to_string(),
                                    id: request.id.clone(),
                                    result: Some(result),
                                    error: None,
                                },
                                Err(e) => JsonRpcResponse {
                                    jsonrpc: "2.0".to_string(),
                                    id: request.id.clone(),
                                    result: None,
                                    error: Some(crate::JsonRpcError {
                                        code: -1,
                                        message: e.to_string(),
                                        data: None,
                                    }),
                                },
                            }
                        } else {
                            JsonRpcResponse {
                                jsonrpc: "2.0".to_string(),
                                id: request.id.clone(),
                                result: None,
                                error: Some(crate::JsonRpcError {
                                    code: -32601,
                                    message: format!("Method not found: {}", request.method),
                                    data: None,
                                }),
                            }
                        };

                        let response_msg = JsonRpcMessage::Response(response);
                        let response_str =
                            serde_json::to_string(&response_msg).map_err(|e| LspError::Json(e))?;

                        let _ = self.message_tx.send(response_str).await;
                    }
                    _ => {
                        // Ignore notifications and responses
                    }
                }
            }
        }
        Ok(())
    }
}

/// Mock client handle for testing
pub struct MockLspClient {
    message_tx: mpsc::Sender<String>,
    message_rx: mpsc::Receiver<String>,
}

impl MockLspClient {
    /// Send a message to the mock server
    pub async fn send_message(&self, message: &str) -> Result<()> {
        self.message_tx
            .send(message.to_string())
            .await
            .map_err(|_| LspError::ChannelClosed)?;
        Ok(())
    }

    /// Receive a message from the mock server
    pub async fn receive_message(&mut self) -> Result<Option<String>> {
        Ok(self.message_rx.recv().await)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{JsonRpcRequest, RequestId};
    use serde_json::json;

    #[tokio::test]
    async fn test_mock_server() {
        let (mut server, client) = MockLspServer::new();

        // Setup a simple handler
        server.on_request_simple(
            "initialize",
            json!({
                "capabilities": {},
                "serverInfo": {
                    "name": "mock-server",
                    "version": "1.0.0"
                }
            }),
        );

        // Start the server in background
        let server_handle = tokio::spawn(async move { server.run().await });

        // Send a request
        let request = JsonRpcRequest {
            jsonrpc: "2.0".to_string(),
            id: RequestId::Number(1),
            method: "initialize".to_string(),
            params: json!({}),
        };

        let request_str = serde_json::to_string(&JsonRpcMessage::Request(request)).unwrap();
        client.send_message(&request_str).await.unwrap();

        // The test would continue but we'll keep it simple for now
        server_handle.abort(); // Stop the background task
    }
}
