use anyhow::{Error, Result};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::Arc;
use tokio::sync::{oneshot, Mutex};

use crate::protocol::{ChannelCommand, VimProtocol};
use crate::transport::MessageTransport;

/// Channel command sender - handles client-to-vim commands with negative IDs
/// Thread-safe and cloneable for sharing between handlers
pub struct ChannelCommandSender {
    transport: Arc<dyn MessageTransport>,
    pending_calls: Arc<Mutex<HashMap<i64, oneshot::Sender<Value>>>>, // Uses negative IDs per Vim protocol
    next_id: AtomicI64, // Generates negative IDs for client-to-vim commands
}

impl ChannelCommandSender {
    pub fn new(transport: Arc<dyn MessageTransport>) -> Self {
        Self {
            transport,
            pending_calls: Arc::new(Mutex::new(HashMap::new())),
            next_id: AtomicI64::new(-1), // Start at -1, decrement for each call
        }
    }

    /// Generate next negative ID atomically (-1, -2, -3, ...)
    fn next_call_id(&self) -> i64 {
        self.next_id.fetch_sub(1, Ordering::SeqCst)
    }

    /// Call vim function with response: ["call", func, args, id]
    /// Uses negative IDs per Vim channel protocol requirement
    pub async fn call(&self, func: &str, args: Vec<Value>) -> Result<Value> {
        let call_id = self.next_call_id(); // Generate negative ID (-1, -2, -3, ...)
        let (tx, rx) = oneshot::channel();

        // Register pending call before sending
        {
            let mut pending = self.pending_calls.lock().await;
            pending.insert(call_id, tx);
        }

        let cmd = ChannelCommand::Call {
            func: func.to_string(),
            args,
            id: call_id,
        };

        // Send command
        self.transport.send(&VimProtocol::Channel(cmd)).await?;

        // Wait for response
        rx.await.map_err(|_| Error::msg("Call timeout"))
    }

    /// Call vim function without response: ["call", func, args]
    pub async fn call_async(&self, func: &str, args: Vec<Value>) -> Result<()> {
        let cmd = ChannelCommand::CallAsync {
            func: func.to_string(),
            args,
        };

        self.transport.send(&VimProtocol::Channel(cmd)).await
    }

    /// Execute vim expression with response: ["expr", expr, id]
    /// Uses negative IDs per Vim channel protocol requirement  
    pub async fn expr(&self, expr: &str) -> Result<Value> {
        let expr_id = self.next_call_id(); // Generate negative ID (-1, -2, -3, ...)
        let (tx, rx) = oneshot::channel();

        {
            let mut pending = self.pending_calls.lock().await;
            pending.insert(expr_id, tx);
        }

        let cmd = ChannelCommand::Expr {
            expr: expr.to_string(),
            id: expr_id,
        };

        self.transport.send(&VimProtocol::Channel(cmd)).await?;
        rx.await.map_err(|_| Error::msg("Expr timeout"))
    }

    /// Execute vim expression without response: ["expr", expr]
    pub async fn expr_async(&self, expr: &str) -> Result<()> {
        let cmd = ChannelCommand::ExprAsync {
            expr: expr.to_string(),
        };

        self.transport.send(&VimProtocol::Channel(cmd)).await
    }

    /// Execute ex command: ["ex", command]
    pub async fn ex(&self, command: &str) -> Result<()> {
        let cmd = ChannelCommand::Ex {
            command: command.to_string(),
        };

        self.transport.send(&VimProtocol::Channel(cmd)).await
    }

    /// Execute normal mode command: ["normal", keys]
    pub async fn normal(&self, keys: &str) -> Result<()> {
        let cmd = ChannelCommand::Normal {
            keys: keys.to_string(),
        };

        self.transport.send(&VimProtocol::Channel(cmd)).await
    }

    /// Redraw vim screen: ["redraw", force?]
    pub async fn redraw(&self, force: bool) -> Result<()> {
        let cmd = ChannelCommand::Redraw { force };
        self.transport.send(&VimProtocol::Channel(cmd)).await
    }

    /// Legacy compatibility: Execute vim expression via call
    pub async fn eval(&self, expr: &str) -> Result<Value> {
        self.call("eval", vec![json!(expr)]).await
    }

    /// Legacy compatibility: Execute vim command via call  
    pub async fn execute(&self, cmd: &str) -> Result<Value> {
        self.call("execute", vec![json!(cmd)]).await
    }

    /// Handle response from vim - called by MessageReceiver
    /// This is internal API used by the message processing system
    pub(crate) async fn handle_response(&self, id: i64, result: Value) -> Result<()> {
        let mut pending = self.pending_calls.lock().await;
        if let Some(sender) = pending.remove(&id) {
            let _ = sender.send(result); // Ignore send errors (receiver dropped)
        }
        Ok(())
    }
}

// Make it cloneable for sharing between handlers
impl Clone for ChannelCommandSender {
    fn clone(&self) -> Self {
        Self {
            transport: self.transport.clone(),
            pending_calls: self.pending_calls.clone(),
            next_id: AtomicI64::new(self.next_id.load(Ordering::SeqCst)),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::transport::MockTransport;

    #[tokio::test]
    async fn test_channel_command_sender() {
        let transport = Arc::new(MockTransport::new());
        let sender = ChannelCommandSender::new(transport.clone());

        // Test async call (no response expected)
        sender
            .call_async("test_func", vec![json!("arg1")])
            .await
            .unwrap();

        let sent_messages = transport.get_sent_messages().await;
        assert_eq!(sent_messages.len(), 1);

        // Should be async call format
        if let VimProtocol::Channel(ChannelCommand::CallAsync { func, args }) = &sent_messages[0] {
            assert_eq!(func, "test_func");
            assert_eq!(args, &vec![json!("arg1")]);
        } else {
            panic!("Expected CallAsync command");
        }
    }

    #[tokio::test]
    async fn test_id_generation() {
        let transport = Arc::new(MockTransport::new());
        let sender = ChannelCommandSender::new(transport.clone());

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
        let transport = Arc::new(MockTransport::new());
        let sender1 = ChannelCommandSender::new(transport.clone());
        let sender2 = sender1.clone();

        // Both should work independently
        sender1.ex("echo 'test1'").await.unwrap();
        sender2.ex("echo 'test2'").await.unwrap();

        let sent_messages = transport.get_sent_messages().await;
        assert_eq!(sent_messages.len(), 2);
    }
}
