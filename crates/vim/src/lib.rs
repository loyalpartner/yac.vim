//! vim crate - v4 refactored implementation
//!
//! Clean architecture with separated concerns:
//! - Protocol parsing (JSON-RPC vs Vim channel)
//! - Command sending (ChannelCommandSender)
//! - Message receiving (MessageReceiver)
//! - Transport abstraction (stdio, mock, etc.)
//!
//! Follows Linus philosophy: eliminate special cases, use data structures to simplify algorithms.

use std::sync::Arc;

// ============================================================================
// Error Types - Linus style: explicit, structured errors
// ============================================================================

#[derive(Debug, thiserror::Error)]
pub enum VimError {
    #[error("EOF reached")]
    Eof,

    #[error("No messages to receive")]
    NoMessages,

    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),

    #[error("JSON error: {0}")]
    Json(#[from] serde_json::Error),

    #[error("Task join error: {0}")]
    TaskJoin(#[from] tokio::task::JoinError),

    #[error("Protocol error: {0}")]
    Protocol(String),
}

pub type Result<T> = std::result::Result<T, VimError>;

// New modular architecture
pub mod protocol;
pub mod queue;
pub mod receiver;
pub mod sender;
pub mod transport;

// Re-export key types
pub use protocol::{ChannelCommand, JsonRpcMessage, VimProtocol};
pub use queue::MessageQueue;
pub use receiver::{Handler, HandlerPool, HandlerResult, IoLoop, VimContext};
pub use sender::ChannelCommandSender;
pub use transport::{MessageTransport, StdioTransport};

// ================================================================
// New VimClient - composition of sender + receiver
// ================================================================

/// The main vim client - now using message queue architecture
/// Eliminates the blocking problem by separating I/O from business logic
pub struct VimClient {
    sender: ChannelCommandSender,
    handler_pool: HandlerPool,
    io_loop: IoLoop,
}

impl VimClient {
    /// Create stdio client with new queue architecture
    pub fn new_stdio() -> Self {
        let transport = Arc::new(StdioTransport::new());
        let queue = Arc::new(MessageQueue::new());

        let sender = ChannelCommandSender::new(&queue);
        let handler_pool = HandlerPool::new(queue.clone());
        let io_loop = IoLoop::new(transport, queue);

        Self {
            sender,
            handler_pool,
            io_loop,
        }
    }

    /// Create client with custom transport and queue architecture
    pub fn new(transport: Arc<dyn MessageTransport>) -> Self {
        let queue = Arc::new(MessageQueue::new());

        let sender = ChannelCommandSender::new(&queue);
        let handler_pool = HandlerPool::new(queue.clone());
        let io_loop = IoLoop::new(transport, queue);

        Self {
            sender,
            handler_pool,
            io_loop,
        }
    }

    /// Get reference to command sender
    pub fn sender(&self) -> &ChannelCommandSender {
        &self.sender
    }

    /// Get mutable reference to handler pool for adding handlers
    pub fn handler_pool_mut(&mut self) -> &mut HandlerPool {
        &mut self.handler_pool
    }

    /// Type-safe handler registration
    pub fn add_handler<H: Handler + 'static>(&mut self, method: &str, handler: H) {
        self.handler_pool.add_handler(method, handler);
    }

    /// Main processing loop - starts I/O and handler pool concurrently
    /// This eliminates the blocking problem by running components in parallel
    pub async fn run(mut self) -> anyhow::Result<()> {
        use tracing::info;

        info!("Starting VimClient with non-blocking architecture");

        // Start both I/O loop and handler pool concurrently
        let io_handle = tokio::spawn(async move { self.io_loop.run().await });

        let handler_handle = tokio::spawn(async move { self.handler_pool.run().await });

        // Wait for either to complete (or fail)
        tokio::select! {
            io_result = io_handle => {
                match io_result {
                    Ok(Ok(())) => info!("I/O loop completed successfully"),
                    Ok(Err(e)) => return Err(e),
                    Err(e) => return Err(anyhow::Error::from(VimError::TaskJoin(e))),
                }
            }
            handler_result = handler_handle => {
                match handler_result {
                    Ok(Ok(())) => info!("Handler pool completed successfully"),
                    Ok(Err(e)) => return Err(e),
                    Err(e) => return Err(anyhow::Error::from(VimError::TaskJoin(e))),
                }
            }
        }

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{json, Value};

    #[tokio::test]
    async fn test_vim_client_creation() {
        use transport::MockTransport;

        let transport = Arc::new(MockTransport::new());
        let mut client = VimClient::new(transport.clone());

        // Test that we can add handlers
        struct TestHandler;

        #[async_trait::async_trait]
        impl Handler for TestHandler {
            type Input = Value;
            type Output = String;

            async fn handle(
                &self,
                _vim: &dyn VimContext,
                input: Self::Input,
            ) -> anyhow::Result<HandlerResult<Self::Output>> {
                Ok(HandlerResult::Data(format!("handled: {}", input)))
            }
        }

        client.add_handler("test_method", TestHandler);

        // Test that sender methods work (they queue messages now)
        let _result = client
            .sender()
            .call_async("test_func", vec![json!("arg")])
            .await;
        // Note: We can't easily test message delivery without running the full I/O loop
    }
}
