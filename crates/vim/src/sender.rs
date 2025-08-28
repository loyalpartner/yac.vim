use anyhow::{Error, Result};
use serde_json::Value;
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::Arc;
use tokio::sync::{mpsc, oneshot};
use tracing::debug;

use crate::protocol::{ChannelCommand, VimProtocol};
use crate::queue::{MessageQueue, ResponseDispatcher};

/// Channel command sender - handles client-to-vim commands with negative IDs
/// Now uses message queue for non-blocking operation
pub struct ChannelCommandSender {
    outgoing_tx: mpsc::UnboundedSender<VimProtocol>,
    response_dispatcher: Arc<ResponseDispatcher>,
    next_id: AtomicI64, // Generates negative IDs for client-to-vim commands
}

impl ChannelCommandSender {
    pub fn new(queue: &MessageQueue) -> Self {
        Self {
            outgoing_tx: queue.outgoing_sender(),
            response_dispatcher: queue.response_dispatcher(),
            next_id: AtomicI64::new(-1), // Start at -1, decrement for each call
        }
    }

    /// Generate next negative ID atomically (-1, -2, -3, ...)
    fn next_call_id(&self) -> i64 {
        self.next_id.fetch_sub(1, Ordering::SeqCst)
    }

    /// Call vim function with response: ["call", func, args, id]
    /// Now non-blocking - uses queue and response dispatcher
    pub async fn call(&self, func: &str, args: Vec<Value>) -> Result<Value> {
        let call_id = self.next_call_id(); // Generate negative ID (-1, -2, -3, ...)
        let (tx, rx) = oneshot::channel();

        // Register response handler
        self.response_dispatcher.register(call_id, tx).await;

        let cmd = ChannelCommand::Call {
            func: func.to_string(),
            args,
            id: call_id,
        };

        // Send to queue (non-blocking)
        self.outgoing_tx
            .send(VimProtocol::Channel(cmd))
            .map_err(|_| Error::msg("Failed to queue call command"))?;

        debug!("Queued call: func={}, id={}", func, call_id);

        // Wait for response (doesn't block I/O loop)
        rx.await.map_err(|_| Error::msg("Call timeout"))
    }

    /// Call vim function without response: ["call", func, args]
    pub async fn call_async(&self, func: &str, args: Vec<Value>) -> Result<()> {
        let cmd = ChannelCommand::CallAsync {
            func: func.to_string(),
            args,
        };

        self.outgoing_tx
            .send(VimProtocol::Channel(cmd))
            .map_err(|_| Error::msg("Failed to queue call_async command"))
    }

    /// Execute vim expression with response: ["expr", expr, id]
    /// Now non-blocking via queue
    pub async fn expr(&self, expr: &str) -> Result<Value> {
        let expr_id = self.next_call_id(); // Generate negative ID (-1, -2, -3, ...)
        let (tx, rx) = oneshot::channel();

        // Register response handler
        self.response_dispatcher.register(expr_id, tx).await;

        let cmd = ChannelCommand::Expr {
            expr: expr.to_string(),
            id: expr_id,
        };

        self.outgoing_tx
            .send(VimProtocol::Channel(cmd))
            .map_err(|_| Error::msg("Failed to queue expr command"))?;

        debug!("Queued expr: expr={}, id={}", expr, expr_id);
        rx.await.map_err(|_| Error::msg("Expression timeout"))
    }

    /// Execute vim expression without response: ["expr", expr]
    pub async fn expr_async(&self, expr: &str) -> Result<()> {
        let cmd = ChannelCommand::ExprAsync {
            expr: expr.to_string(),
        };

        self.outgoing_tx
            .send(VimProtocol::Channel(cmd))
            .map_err(|_| Error::msg("Failed to queue expr_async command"))
    }

    /// Execute ex command: ["ex", command]
    pub async fn ex(&self, command: &str) -> Result<()> {
        let cmd = ChannelCommand::Ex {
            command: command.to_string(),
        };

        self.outgoing_tx
            .send(VimProtocol::Channel(cmd))
            .map_err(|_| Error::msg("Failed to queue ex command"))
    }

    /// Execute normal mode command: ["normal", keys]
    pub async fn normal(&self, keys: &str) -> Result<()> {
        let cmd = ChannelCommand::Normal {
            keys: keys.to_string(),
        };

        self.outgoing_tx
            .send(VimProtocol::Channel(cmd))
            .map_err(|_| Error::msg("Failed to queue normal command"))
    }

    /// Redraw vim screen: ["redraw", force?]
    pub async fn redraw(&self, force: bool) -> Result<()> {
        let cmd = ChannelCommand::Redraw { force };
        self.outgoing_tx
            .send(VimProtocol::Channel(cmd))
            .map_err(|_| Error::msg("Failed to queue redraw command"))
    }

    // Response handling is now done by ResponseDispatcher in the queue
    // This method is no longer needed
}

// Make it cloneable for sharing between handlers
impl Clone for ChannelCommandSender {
    fn clone(&self) -> Self {
        Self {
            outgoing_tx: self.outgoing_tx.clone(),
            response_dispatcher: self.response_dispatcher.clone(),
            next_id: AtomicI64::new(self.next_id.load(Ordering::SeqCst)),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::queue::MessageQueue;
    use serde_json::json;
    use tokio::time::{timeout, Duration};

    #[tokio::test]
    async fn test_call_async_queuing() {
        let queue = MessageQueue::new();
        let sender = ChannelCommandSender::new(&queue);

        // Test async call (no response expected)
        sender
            .call_async("test_func", vec![json!("arg1")])
            .await
            .unwrap();

        // Check message was queued
        let mut rx = queue.outgoing_rx.lock().await;
        let message = timeout(Duration::from_millis(100), rx.recv())
            .await
            .unwrap()
            .unwrap();

        if let VimProtocol::Channel(ChannelCommand::CallAsync { func, args }) = message {
            assert_eq!(func, "test_func");
            assert_eq!(args, vec![json!("arg1")]);
        } else {
            panic!("Expected CallAsync command");
        }
    }

    #[tokio::test]
    async fn test_id_generation() {
        let queue = MessageQueue::new();
        let sender = ChannelCommandSender::new(&queue);

        // Generate several IDs
        let id1 = sender.next_call_id();
        let id2 = sender.next_call_id();
        let id3 = sender.next_call_id();

        // Should be negative and decreasing
        assert!(id1 < 0);
        assert!(id2 < 0);
        assert!(id3 < 0);
        assert!(id2 < id1);
        assert!(id3 < id2);
    }

    #[tokio::test]
    async fn test_cloning() {
        let queue = MessageQueue::new();
        let sender1 = ChannelCommandSender::new(&queue);
        let sender2 = sender1.clone();

        // Both should work independently
        sender1.ex("echo 'test1'").await.unwrap();
        sender2.ex("echo 'test2'").await.unwrap();

        // Check both messages were queued
        let mut rx = queue.outgoing_rx.lock().await;
        let _msg1 = timeout(Duration::from_millis(100), rx.recv())
            .await
            .unwrap()
            .unwrap();
        let _msg2 = timeout(Duration::from_millis(100), rx.recv())
            .await
            .unwrap()
            .unwrap();
    }

    #[tokio::test]
    async fn test_call_with_response() {
        let queue = MessageQueue::new();
        let sender = ChannelCommandSender::new(&queue);

        // Start a background task to simulate response
        let response_dispatcher = queue.response_dispatcher();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(10)).await;
            response_dispatcher
                .dispatch_response(-1, json!("test_response"))
                .await
                .unwrap();
        });

        // This should complete without blocking
        let result = sender.call("test_func", vec![json!("arg1")]).await.unwrap();
        assert_eq!(result, json!("test_response"));
    }
}
