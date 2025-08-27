use anyhow::{Error, Result};
use async_trait::async_trait;
use serde::{de::DeserializeOwned, Serialize};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::Arc;
use tracing::error;

use crate::protocol::{JsonRpcMessage, VimProtocol};
use crate::sender::ChannelCommandSender;
use crate::transport::MessageTransport;

/// Handler trait - unified interface for request/notification processing
/// Option<Output> perfectly expresses return semantics: None=notification, Some=response
#[async_trait]
pub trait Handler: Send + Sync {
    type Input: DeserializeOwned;
    type Output: Serialize;

    async fn handle(
        &self,
        sender: &ChannelCommandSender,
        input: Self::Input,
    ) -> Result<Option<Self::Output>>;
}

/// Type-erased dispatcher - compile-time type safety to runtime dispatch
#[async_trait]
trait HandlerDispatch: Send + Sync {
    async fn dispatch(&self, sender: &ChannelCommandSender, params: Value)
        -> Result<Option<Value>>;
}

/// Auto implementation - converts type-safe Handler to runtime dispatch version
#[async_trait]
impl<H: Handler> HandlerDispatch for H {
    async fn dispatch(
        &self,
        sender: &ChannelCommandSender,
        params: Value,
    ) -> Result<Option<Value>> {
        let input: H::Input = serde_json::from_value(params)?;
        let result = self.handle(sender, input).await?;

        match result {
            Some(output) => Ok(Some(serde_json::to_value(output)?)),
            None => Ok(None),
        }
    }
}

/// Handler registry - manages method name to handler mapping
pub struct HandlerRegistry {
    handlers: HashMap<String, Arc<dyn HandlerDispatch>>,
}

impl Default for HandlerRegistry {
    fn default() -> Self {
        Self::new()
    }
}

impl HandlerRegistry {
    pub fn new() -> Self {
        Self {
            handlers: HashMap::new(),
        }
    }

    /// Type-safe handler registration - compile-time checks
    pub fn add_handler<H: Handler + 'static>(&mut self, method: &str, handler: H) {
        self.handlers.insert(method.to_string(), Arc::new(handler));
    }

    /// Dispatch method call to appropriate handler
    pub async fn dispatch(
        &self,
        method: &str,
        sender: &ChannelCommandSender,
        params: Value,
    ) -> Result<Option<Value>> {
        if let Some(handler) = self.handlers.get(method) {
            handler.dispatch(sender, params).await
        } else {
            Err(Error::msg(format!("Unknown method: {}", method)))
        }
    }
}

/// Message receiver - handles incoming JSON-RPC messages and responses
pub struct MessageReceiver {
    transport: Arc<dyn MessageTransport>,
    handlers: HandlerRegistry,
}

impl MessageReceiver {
    pub fn new(transport: Arc<dyn MessageTransport>) -> Self {
        Self {
            transport,
            handlers: HandlerRegistry::new(),
        }
    }

    /// Add handler for a specific method
    pub fn add_handler<H: Handler + 'static>(&mut self, method: &str, handler: H) {
        self.handlers.add_handler(method, handler);
    }

    /// Main message processing loop - unified handling for all message types
    pub async fn run(&mut self, sender: &ChannelCommandSender) -> Result<()> {
        loop {
            match self.transport.recv().await {
                Ok(msg) => {
                    if let Err(e) = self.handle_message(msg, sender).await {
                        error!("Message handling error: {}", e);
                    }
                }
                Err(e) => {
                    error!("Transport error: {}", e);
                    break;
                }
            }
        }
        Ok(())
    }

    /// Unified message handling - no special cases
    async fn handle_message(&self, msg: VimProtocol, sender: &ChannelCommandSender) -> Result<()> {
        match msg {
            VimProtocol::JsonRpc(rpc_msg) => match rpc_msg {
                JsonRpcMessage::Request { id, method, params } => {
                    self.handle_request(id, method, params, sender).await
                }
                JsonRpcMessage::Response { id, result } => sender.handle_response(id, result).await,
                JsonRpcMessage::Notification { method, params } => {
                    self.handle_notification(method, params, sender).await
                }
            },
            VimProtocol::Channel(_cmd) => {
                // Channel commands are outgoing (client-to-vim), receiving them is unexpected
                error!("Warning: Received outgoing channel command, ignoring");
                Ok(())
            }
        }
    }

    /// Handle requests from vim
    async fn handle_request(
        &self,
        id: u64,
        method: String,
        params: Value,
        sender: &ChannelCommandSender,
    ) -> Result<()> {
        tracing::debug!("Handling request: method={}, params={}", method, params);

        match self.handlers.dispatch(&method, sender, params).await {
            Ok(Some(result)) => {
                // Has return value - send response
                let response = JsonRpcMessage::Response {
                    id: id as i64,
                    result,
                };
                self.transport.send(&VimProtocol::JsonRpc(response)).await?;
            }
            Ok(None) => {
                // notification - no reply
            }
            Err(e) => {
                // Unified error handling
                let response = JsonRpcMessage::Response {
                    id: id as i64,
                    result: json!({"error": e.to_string()}),
                };
                self.transport.send(&VimProtocol::JsonRpc(response)).await?;
            }
        }
        Ok(())
    }

    /// Handle notifications
    async fn handle_notification(
        &self,
        method: String,
        params: Value,
        sender: &ChannelCommandSender,
    ) -> Result<()> {
        // notification processing same as request - just no response sent
        let _ = self.handlers.dispatch(&method, sender, params).await;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::transport::MockTransport;
    use serde_json::json;

    // Test handler implementation
    struct TestHandler;

    #[async_trait]
    impl Handler for TestHandler {
        type Input = Value;
        type Output = String;

        async fn handle(
            &self,
            _sender: &ChannelCommandSender,
            input: Self::Input,
        ) -> Result<Option<Self::Output>> {
            Ok(Some(format!("processed: {}", input)))
        }
    }

    // Test notification handler (returns None)
    struct NotificationHandler;

    #[async_trait]
    impl Handler for NotificationHandler {
        type Input = Value;
        type Output = String;

        async fn handle(
            &self,
            _sender: &ChannelCommandSender,
            _input: Self::Input,
        ) -> Result<Option<Self::Output>> {
            Ok(None) // Notification, no response
        }
    }

    #[tokio::test]
    async fn test_handler_registry() {
        let mut registry = HandlerRegistry::new();
        registry.add_handler("test_method", TestHandler);

        let transport = Arc::new(MockTransport::new());
        let sender = ChannelCommandSender::new(transport.clone());

        let result = registry
            .dispatch("test_method", &sender, json!("test_data"))
            .await
            .unwrap();

        assert_eq!(result, Some(json!("processed: \"test_data\"")));
    }

    #[tokio::test]
    async fn test_message_receiver_setup() {
        let transport = Arc::new(MockTransport::new());
        let mut receiver = MessageReceiver::new(transport.clone());

        receiver.add_handler("test_method", TestHandler);
        receiver.add_handler("notification", NotificationHandler);

        // Verify handlers are registered
        assert!(receiver.handlers.handlers.contains_key("test_method"));
        assert!(receiver.handlers.handlers.contains_key("notification"));
    }
}
