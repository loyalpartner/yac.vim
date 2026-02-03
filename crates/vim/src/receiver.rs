use crate::protocol::{JsonRpcMessage, VimProtocol};
use crate::queue::MessageQueue;
use crate::transport::MessageTransport;
use crate::VimError;
use anyhow::Result;
use async_trait::async_trait;
use serde::{de::DeserializeOwned, Serialize};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::Arc;
use tracing::{debug, error, info};

/// VimContext trait - clean interface for vim operations
/// Hides implementation details (queue, sender, etc.) from handlers
#[async_trait]
pub trait VimContext: Send + Sync {
    /// Call vim function with response: ["call", func, args, id]
    async fn call(&self, func: &str, args: Vec<Value>) -> Result<Value>;

    /// Call vim function without response: ["call", func, args]
    async fn call_async(&self, func: &str, args: Vec<Value>) -> Result<()>;

    /// Execute vim expression with response: ["expr", expr, id]
    async fn expr(&self, expr: &str) -> Result<Value>;

    /// Execute vim expression without response: ["expr", expr]
    async fn expr_async(&self, expr: &str) -> Result<()>;

    /// Execute ex command: ["ex", cmd]
    async fn ex(&self, cmd: &str) -> Result<()>;

    /// Execute normal mode command: ["normal", keys]
    async fn normal(&self, keys: &str) -> Result<()>;

    /// Redraw vim screen: ["redraw", force?]
    async fn redraw(&self, force: bool) -> Result<()>;
}

/// Handler result - clean semantics
/// Data: has data to return
/// Empty: operation completed but no data (e.g., goto found nothing)
#[derive(Debug)]
pub enum HandlerResult<T> {
    Data(T),
    Empty,
}

/// Handler trait - unified interface for request/notification processing
/// Handler returns result, dispatcher decides whether to send response based on protocol
#[async_trait]
pub trait Handler: Send + Sync {
    type Input: DeserializeOwned;
    type Output: Serialize;

    async fn handle(
        &self,
        vim: &dyn VimContext,
        input: Self::Input,
    ) -> Result<HandlerResult<Self::Output>>;
}

/// Type-erased dispatch result
/// Maps HandlerResult<T> to runtime representation
#[derive(Debug)]
pub enum DispatchResult {
    Data(Value),
    Empty,
}

/// Type-erased dispatcher - compile-time type safety to runtime dispatch
#[async_trait]
trait HandlerDispatch: Send + Sync {
    async fn dispatch(&self, vim: &dyn VimContext, params: Value) -> Result<DispatchResult>;
}

/// Auto implementation - converts type-safe Handler to runtime dispatch version
#[async_trait]
impl<H: Handler> HandlerDispatch for H {
    async fn dispatch(&self, vim: &dyn VimContext, params: Value) -> Result<DispatchResult> {
        let input: H::Input = serde_json::from_value(params)?;
        let result = self.handle(vim, input).await?;

        match result {
            HandlerResult::Data(output) => Ok(DispatchResult::Data(serde_json::to_value(output)?)),
            HandlerResult::Empty => Ok(DispatchResult::Empty),
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
        vim: &dyn VimContext,
        params: Value,
    ) -> Result<DispatchResult> {
        if let Some(handler) = self.handlers.get(method) {
            handler.dispatch(vim, params).await
        } else {
            Err(VimError::Protocol(format!("Unknown method: {}", method)).into())
        }
    }
}

/// I/O Loop - pure message transport, no business logic
/// Separates I/O from handler execution to prevent blocking
pub struct IoLoop {
    transport: Arc<dyn MessageTransport>,
    queue: Arc<MessageQueue>,
}

impl IoLoop {
    pub fn new(transport: Arc<dyn MessageTransport>, queue: Arc<MessageQueue>) -> Self {
        Self { transport, queue }
    }

    /// Pure I/O loop - handles message transport only
    /// All business logic moved to handler pool to prevent blocking
    pub async fn run(&mut self) -> Result<()> {
        info!("Starting I/O loop");

        let mut outgoing_rx = self.queue.outgoing_rx.lock().await;

        loop {
            tokio::select! {
                // Receive messages from vim
                msg_result = self.transport.recv() => {
                    match msg_result {
                        Ok(msg) => {
                            if let Err(e) = self.route_incoming_message(msg).await {
                                error!("Message routing error: {}", e);
                            }
                        }
                        Err(e) => {
                            error!("Transport receive error: {}", e);
                            break;
                        }
                    }
                }
                // Send queued messages to vim
                Some(outgoing) = outgoing_rx.recv() => {
                    if let Err(e) = self.transport.send(&outgoing).await {
                        error!("Transport send error: {}", e);
                    } else {
                        debug!("Sent message to vim: {:?}", outgoing);
                    }
                }
            }
        }
        Ok(())
    }

    /// Route incoming messages to appropriate queues - no blocking operations
    async fn route_incoming_message(&self, msg: VimProtocol) -> Result<()> {
        match msg {
            VimProtocol::JsonRpc(rpc_msg) => match rpc_msg {
                JsonRpcMessage::Request { id, method, params } => {
                    debug!("Routing request: method={}, id={}", method, id);
                    self.queue.queue_request(method, params, Some(id)).await
                }
                JsonRpcMessage::Response { id, result } => {
                    debug!("Routing response: id={}", id);
                    self.queue.handle_response(id, result).await
                }
                JsonRpcMessage::Notification { method, params } => {
                    debug!("Routing notification: method={}", method);
                    self.queue.queue_request(method, params, None).await
                }
            },
            VimProtocol::Channel(_cmd) => {
                error!("Warning: Received outgoing channel command, ignoring");
                Ok(())
            }
        }
    }
}

/// Handler pool - processes business logic in separate tasks
/// Prevents blocking the I/O loop when handlers call vim functions
pub struct HandlerPool {
    handlers: HandlerRegistry,
    queue: Arc<MessageQueue>,
}

impl HandlerPool {
    pub fn new(queue: Arc<MessageQueue>) -> Self {
        Self {
            handlers: HandlerRegistry::new(),
            queue,
        }
    }

    /// Add handler for a specific method
    pub fn add_handler<H: Handler + 'static>(&mut self, method: &str, handler: H) {
        self.handlers.add_handler(method, handler);
    }

    /// Start processing requests from queue
    pub async fn run(&self) -> Result<()> {
        info!("Starting handler pool");

        loop {
            let mut rx = self.queue.request_rx.lock().await;
            if let Some((method, params, id)) = rx.recv().await {
                // Spawn each handler in separate task to prevent blocking
                let handlers = self.handlers.handlers.clone();
                let queue = self.queue.clone();

                tokio::spawn(async move {
                    Self::handle_request_async(handlers, queue, method, params, id).await;
                });
            }
        }
    }

    /// Handle request in separate task - can safely call vim without blocking I/O
    async fn handle_request_async(
        handlers: HashMap<String, Arc<dyn HandlerDispatch>>,
        queue: Arc<MessageQueue>,
        method: String,
        params: Value,
        id: Option<u64>,
    ) {
        debug!(
            "Processing request: method={}, has_id={}",
            method,
            id.is_some()
        );

        // Cast queue to VimContext - clean interface for handlers
        let vim_context: &dyn VimContext = queue.as_ref();

        let result = if let Some(handler) = handlers.get(&method) {
            handler.dispatch(vim_context, params).await
        } else {
            Err(VimError::Protocol(format!("Unknown method: {}", method)).into())
        };

        // Send response only if this was a request (has id)
        // Notification results are discarded per JSON-RPC protocol
        if let Some(request_id) = id {
            let response = match result {
                Ok(DispatchResult::Data(data)) => JsonRpcMessage::Response {
                    id: request_id as i64,
                    result: data,
                },
                Ok(DispatchResult::Empty) => JsonRpcMessage::Response {
                    id: request_id as i64,
                    result: json!(null),
                },
                Err(e) => JsonRpcMessage::Response {
                    id: request_id as i64,
                    result: json!({"error": e.to_string()}),
                },
            };

            if let Err(e) = queue.send_to_vim(VimProtocol::JsonRpc(response)).await {
                error!("Failed to send response: {}", e);
            }
        }
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
            _vim: &dyn VimContext,
            input: Self::Input,
        ) -> Result<HandlerResult<Self::Output>> {
            Ok(HandlerResult::Data(format!("processed: {}", input)))
        }
    }

    // Test handler that returns empty (e.g., goto found nothing)
    struct EmptyHandler;

    #[async_trait]
    impl Handler for EmptyHandler {
        type Input = Value;
        type Output = String;

        async fn handle(
            &self,
            _vim: &dyn VimContext,
            _input: Self::Input,
        ) -> Result<HandlerResult<Self::Output>> {
            Ok(HandlerResult::Empty)
        }
    }

    #[tokio::test]
    async fn test_handler_registry() {
        let mut registry = HandlerRegistry::new();
        registry.add_handler("test_method", TestHandler);

        let queue = MessageQueue::new();
        let vim_context: &dyn VimContext = &queue;

        let result = registry
            .dispatch("test_method", vim_context, json!("test_data"))
            .await
            .unwrap();

        match result {
            DispatchResult::Data(v) => assert_eq!(v, json!("processed: \"test_data\"")),
            DispatchResult::Empty => panic!("Expected Data, got Empty"),
        }
    }

    #[tokio::test]
    async fn test_io_loop_message_routing() {
        let transport = Arc::new(MockTransport::new());
        let queue = Arc::new(MessageQueue::new());
        let _io_loop = IoLoop::new(transport.clone(), queue.clone());

        // Add a test message to mock transport
        let test_request = VimProtocol::JsonRpc(JsonRpcMessage::Request {
            id: 123,
            method: "test_method".to_string(),
            params: json!({"test": "data"}),
        });
        transport.add_received_message(test_request).await;

        // Verify message gets routed to request queue
        // This would require running io_loop in background and checking queue
        // Simplified test for now
    }

    #[tokio::test]
    async fn test_handler_pool_setup() {
        let queue = Arc::new(MessageQueue::new());
        let mut pool = HandlerPool::new(queue.clone());

        pool.add_handler("test_method", TestHandler);
        pool.add_handler("empty", EmptyHandler);

        // Verify handlers are registered
        assert!(pool.handlers.handlers.contains_key("test_method"));
        assert!(pool.handlers.handlers.contains_key("empty"));
    }
}
