use anyhow::{Error, Result};
use async_trait::async_trait;
use serde_json::Value;
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::{mpsc, oneshot, Mutex};
use tracing::{debug, error};

use crate::protocol::VimProtocol;
use crate::receiver::VimContext;
use crate::sender::ChannelCommandSender;

/// Type alias for request receiver to reduce complexity
type RequestReceiver = Arc<Mutex<mpsc::UnboundedReceiver<(String, Value, Option<u64>)>>>;

/// Response dispatcher - manages pending call responses
/// Thread-safe, handles response routing from I/O loop to waiting callers
pub struct ResponseDispatcher {
    pending_calls: Arc<Mutex<HashMap<i64, oneshot::Sender<Value>>>>,
}

impl ResponseDispatcher {
    pub fn new() -> Self {
        Self {
            pending_calls: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    /// Register a pending call with response channel
    pub async fn register(&self, id: i64, sender: oneshot::Sender<Value>) {
        let mut pending = self.pending_calls.lock().await;
        pending.insert(id, sender);
        debug!("Registered pending call: {}", id);
    }

    /// Dispatch response to waiting caller
    pub async fn dispatch_response(&self, id: i64, result: Value) -> Result<()> {
        let mut pending = self.pending_calls.lock().await;
        if let Some(sender) = pending.remove(&id) {
            debug!("Dispatching response for call: {}", id);
            let _ = sender.send(result); // Ignore send errors (receiver may have timed out)
        } else {
            error!("Received response for unknown call id: {}", id);
        }
        Ok(())
    }

    /// Get count of pending calls (for debugging/monitoring)
    pub async fn pending_count(&self) -> usize {
        self.pending_calls.lock().await.len()
    }
}

impl Default for ResponseDispatcher {
    fn default() -> Self {
        Self::new()
    }
}

/// Message queue - central hub for all vim protocol messages
/// Decouples I/O from business logic, enables non-blocking operation
pub struct MessageQueue {
    /// Outgoing message channel - all messages to vim go through here
    pub outgoing_tx: mpsc::UnboundedSender<VimProtocol>,
    pub outgoing_rx: Arc<Mutex<mpsc::UnboundedReceiver<VimProtocol>>>,

    /// Request dispatch channel - incoming requests from vim
    pub request_tx: mpsc::UnboundedSender<(String, Value, Option<u64>)>, // method, params, optional_id
    pub request_rx: RequestReceiver,

    /// Response dispatcher - handles call responses
    pub response_dispatcher: Arc<ResponseDispatcher>,
}

impl MessageQueue {
    pub fn new() -> Self {
        let (outgoing_tx, outgoing_rx) = mpsc::unbounded_channel();
        let (request_tx, request_rx) = mpsc::unbounded_channel();

        Self {
            outgoing_tx,
            outgoing_rx: Arc::new(Mutex::new(outgoing_rx)),
            request_tx,
            request_rx: Arc::new(Mutex::new(request_rx)),
            response_dispatcher: Arc::new(ResponseDispatcher::new()),
        }
    }

    /// Send message to vim (non-blocking)
    pub async fn send_to_vim(&self, msg: VimProtocol) -> Result<()> {
        self.outgoing_tx
            .send(msg)
            .map_err(|_| Error::msg("Failed to queue outgoing message"))
    }

    /// Queue incoming request for handler processing
    pub async fn queue_request(
        &self,
        method: String,
        params: Value,
        id: Option<u64>,
    ) -> Result<()> {
        self.request_tx
            .send((method, params, id))
            .map_err(|_| Error::msg("Failed to queue request"))
    }

    /// Handle response from vim
    pub async fn handle_response(&self, id: i64, result: Value) -> Result<()> {
        self.response_dispatcher.dispatch_response(id, result).await
    }

    /// Get clone of response dispatcher for sharing with sender
    pub fn response_dispatcher(&self) -> Arc<ResponseDispatcher> {
        self.response_dispatcher.clone()
    }

    /// Get outgoing sender for sharing with sender components
    pub fn outgoing_sender(&self) -> mpsc::UnboundedSender<VimProtocol> {
        self.outgoing_tx.clone()
    }
}

impl Default for MessageQueue {
    fn default() -> Self {
        Self::new()
    }
}

/// Implementation of VimContext for MessageQueue
/// Provides clean handler interface while hiding queue implementation details
#[async_trait]
impl VimContext for MessageQueue {
    async fn call(&self, func: &str, args: Vec<Value>) -> Result<Value> {
        let sender = ChannelCommandSender::new(self);
        sender.call(func, args).await
    }

    async fn call_async(&self, func: &str, args: Vec<Value>) -> Result<()> {
        let sender = ChannelCommandSender::new(self);
        sender.call_async(func, args).await
    }

    async fn expr(&self, expr: &str) -> Result<Value> {
        let sender = ChannelCommandSender::new(self);
        sender.expr(expr).await
    }

    async fn expr_async(&self, expr: &str) -> Result<()> {
        let sender = ChannelCommandSender::new(self);
        sender.expr_async(expr).await
    }

    async fn ex(&self, cmd: &str) -> Result<()> {
        let sender = ChannelCommandSender::new(self);
        sender.ex(cmd).await
    }

    async fn normal(&self, keys: &str) -> Result<()> {
        let sender = ChannelCommandSender::new(self);
        sender.normal(keys).await
    }

    async fn redraw(&self, force: bool) -> Result<()> {
        let sender = ChannelCommandSender::new(self);
        sender.redraw(force).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use tokio::time::{timeout, Duration};

    #[tokio::test]
    async fn test_response_dispatcher() {
        let dispatcher = ResponseDispatcher::new();
        let (tx, rx) = oneshot::channel();

        // Register pending call
        dispatcher.register(-1, tx).await;
        assert_eq!(dispatcher.pending_count().await, 1);

        // Dispatch response
        dispatcher
            .dispatch_response(-1, json!("test_result"))
            .await
            .unwrap();

        // Verify response received
        let result = timeout(Duration::from_millis(100), rx)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(result, json!("test_result"));

        // Verify call removed from pending
        assert_eq!(dispatcher.pending_count().await, 0);
    }

    #[tokio::test]
    async fn test_message_queue_flow() {
        let queue = MessageQueue::new();

        // Test outgoing message
        let test_msg = VimProtocol::Channel(crate::protocol::ChannelCommand::CallAsync {
            func: "test".to_string(),
            args: vec![],
        });

        queue.send_to_vim(test_msg.clone()).await.unwrap();

        // Verify message queued
        let mut rx = queue.outgoing_rx.lock().await;
        let received = timeout(Duration::from_millis(100), rx.recv())
            .await
            .unwrap()
            .unwrap();
        assert!(matches!(received, VimProtocol::Channel(_)));
    }

    #[tokio::test]
    async fn test_request_queuing() {
        let queue = MessageQueue::new();

        // Queue a request
        queue
            .queue_request(
                "test_method".to_string(),
                json!({"param": "value"}),
                Some(123),
            )
            .await
            .unwrap();

        // Verify request queued
        let mut rx = queue.request_rx.lock().await;
        let (method, params, id) = timeout(Duration::from_millis(100), rx.recv())
            .await
            .unwrap()
            .unwrap();

        assert_eq!(method, "test_method");
        assert_eq!(params, json!({"param": "value"}));
        assert_eq!(id, Some(123));
    }

    #[tokio::test]
    async fn test_response_handling() {
        let queue = MessageQueue::new();
        let (tx, rx) = oneshot::channel();

        // Register pending call via dispatcher
        queue.response_dispatcher().register(-42, tx).await;

        // Handle response via queue
        queue
            .handle_response(-42, json!("response_data"))
            .await
            .unwrap();

        // Verify response received
        let result = timeout(Duration::from_millis(100), rx)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(result, json!("response_data"));
    }
}
