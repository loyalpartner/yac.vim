use crate::bridge::client::ClientId;
use crate::lsp::jsonrpc::RequestId;
use crate::lsp::protocol::{VimEvent, VimRequest};
use crate::utils::{config::ResourceLimits, Result};
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::{broadcast, mpsc, RwLock};
use tracing::{debug, error, info, warn};
use uuid::Uuid;

/// 事件ID用于追踪和关联
pub type EventId = Uuid;

/// 改进的事件定义，使用命名字段替代位置参数
#[derive(Debug, Clone)]
pub enum Event {
    /// 客户端连接事件
    ClientConnected {
        client_id: ClientId,
        event_id: EventId,
    },
    /// 客户端断开连接事件
    ClientDisconnected {
        client_id: ClientId,
        event_id: EventId,
    },
    /// Vim事件（通知类型）
    VimEvent {
        client_id: ClientId,
        event: VimEvent,
        event_id: EventId,
    },
    /// Vim请求（需要响应）
    VimRequest {
        client_id: ClientId,
        request_id: RequestId,
        request: VimRequest,
        event_id: EventId,
    },
    /// LSP服务器响应
    LspResponse {
        server_id: String,
        response: serde_json::Value,
        event_id: EventId,
    },
    /// LSP服务器通知
    LspNotification {
        server_id: String,
        method: String,
        params: Option<serde_json::Value>,
        event_id: EventId,
    },
}

impl Event {
    /// 获取事件ID
    pub fn event_id(&self) -> EventId {
        match self {
            Event::ClientConnected { event_id, .. } => *event_id,
            Event::ClientDisconnected { event_id, .. } => *event_id,
            Event::VimEvent { event_id, .. } => *event_id,
            Event::VimRequest { event_id, .. } => *event_id,
            Event::LspResponse { event_id, .. } => *event_id,
            Event::LspNotification { event_id, .. } => *event_id,
        }
    }

    /// 获取事件类型名称（用于订阅）
    pub fn event_type(&self) -> &'static str {
        match self {
            Event::ClientConnected { .. } => "client_connected",
            Event::ClientDisconnected { .. } => "client_disconnected",
            Event::VimEvent { .. } => "vim_event",
            Event::VimRequest { .. } => "vim_request",
            Event::LspResponse { .. } => "lsp_response",
            Event::LspNotification { .. } => "lsp_notification",
        }
    }

    /// 创建带自动生成ID的事件
    pub fn client_connected(client_id: ClientId) -> Self {
        Event::ClientConnected {
            client_id,
            event_id: Uuid::new_v4(),
        }
    }

    pub fn client_disconnected(client_id: ClientId) -> Self {
        Event::ClientDisconnected {
            client_id,
            event_id: Uuid::new_v4(),
        }
    }

    pub fn vim_event(client_id: ClientId, event: VimEvent) -> Self {
        Event::VimEvent {
            client_id,
            event,
            event_id: Uuid::new_v4(),
        }
    }

    pub fn vim_request(client_id: ClientId, request_id: RequestId, request: VimRequest) -> Self {
        Event::VimRequest {
            client_id,
            request_id,
            request,
            event_id: Uuid::new_v4(),
        }
    }

    pub fn lsp_response(server_id: String, response: serde_json::Value) -> Self {
        Event::LspResponse {
            server_id,
            response,
            event_id: Uuid::new_v4(),
        }
    }

    pub fn lsp_notification(
        server_id: String,
        method: String,
        params: Option<serde_json::Value>,
    ) -> Self {
        Event::LspNotification {
            server_id,
            method,
            params,
            event_id: Uuid::new_v4(),
        }
    }
}

/// 事件订阅者信息 - 使用有界通道
#[derive(Debug, Clone)]
struct Subscriber {
    id: String,
    sender: mpsc::Sender<Event>,
}

/// 重新设计的事件总线 - 使用发布-订阅模式
pub struct EventBus {
    /// 广播发送器，用于分发事件到所有订阅者
    broadcast_tx: broadcast::Sender<Event>,
    /// 按事件类型分组的订阅者
    subscribers: Arc<RwLock<HashMap<String, Vec<Subscriber>>>>,
    /// 事件处理统计
    stats: Arc<RwLock<EventStats>>,
}

/// 事件统计信息
#[derive(Debug, Default)]
pub struct EventStats {
    pub total_events: u64,
    pub events_by_type: HashMap<String, u64>,
    pub failed_deliveries: u64,
    pub active_subscribers: usize,
}

impl EventBus {
    pub fn new(limits: &ResourceLimits) -> Self {
        let (broadcast_tx, _) = broadcast::channel(limits.event_queue_size);

        Self {
            broadcast_tx,
            subscribers: Arc::new(RwLock::new(HashMap::new())),
            stats: Arc::new(RwLock::new(EventStats::default())),
        }
    }

    /// 获取事件发送器（可以安全克隆给多个组件使用）
    pub fn get_sender(&self) -> EventSender {
        EventSender {
            broadcast_tx: self.broadcast_tx.clone(),
            stats: self.stats.clone(),
        }
    }

    /// 创建事件处理器
    pub fn create_handler(&self) -> EventHandler {
        let receiver = self.broadcast_tx.subscribe();
        EventHandler {
            receiver,
            stats: self.stats.clone(),
        }
    }

    /// 订阅特定类型的事件 - 使用有界通道
    pub async fn subscribe(
        &self,
        event_type: String,
        subscriber_id: String,
        queue_size: usize,
    ) -> Result<mpsc::Receiver<Event>> {
        let mut subscribers = self.subscribers.write().await;

        // 检查订阅者数量限制
        let max_subscribers = 10; // 可以配置化
        let current_count = subscribers.get(&event_type).map_or(0, |v| v.len());
        if current_count >= max_subscribers {
            return Err(crate::utils::Error::Internal(anyhow::anyhow!(
                "Too many subscribers for event type: {}",
                event_type
            )));
        }

        let (tx, rx) = mpsc::channel(queue_size);
        let subscriber = Subscriber {
            id: subscriber_id,
            sender: tx,
        };

        subscribers
            .entry(event_type.clone())
            .or_insert_with(Vec::new)
            .push(subscriber);

        // 更新统计
        let mut stats = self.stats.write().await;
        stats.active_subscribers = subscribers.values().map(|v| v.len()).sum();

        info!("New subscriber added for event type: {}", event_type);
        Ok(rx)
    }

    /// 取消订阅
    pub async fn unsubscribe(&self, event_type: &str, subscriber_id: &str) -> Result<()> {
        let mut subscribers = self.subscribers.write().await;

        if let Some(subs) = subscribers.get_mut(event_type) {
            subs.retain(|s| s.id != subscriber_id);
            if subs.is_empty() {
                subscribers.remove(event_type);
            }
        }

        // 更新统计
        let mut stats = self.stats.write().await;
        stats.active_subscribers = subscribers.values().map(|v| v.len()).sum();

        info!(
            "Subscriber {} removed from event type: {}",
            subscriber_id, event_type
        );
        Ok(())
    }

    /// 获取事件统计信息
    pub async fn get_stats(&self) -> EventStats {
        let stats = self.stats.read().await;
        EventStats {
            total_events: stats.total_events,
            events_by_type: stats.events_by_type.clone(),
            failed_deliveries: stats.failed_deliveries,
            active_subscribers: stats.active_subscribers,
        }
    }

    /// 启动事件分发循环（在后台运行）
    pub async fn start_dispatcher(&self) -> Result<()> {
        let mut receiver = self.broadcast_tx.subscribe();
        let subscribers = self.subscribers.clone();
        let stats = self.stats.clone();

        tokio::spawn(async move {
            while let Ok(event) = receiver.recv().await {
                let event_type = event.event_type().to_string();

                // 获取该事件类型的订阅者
                let subs = {
                    let subscribers_read = subscribers.read().await;
                    subscribers_read.get(&event_type).cloned()
                };

                if let Some(subs) = subs {
                    for subscriber in &subs {
                        // 使用非阻塞发送避免阻塞整个分发器
                        match subscriber.sender.try_send(event.clone()) {
                            Ok(_) => {}
                            Err(mpsc::error::TrySendError::Full(_)) => {
                                // 队列已满，记录错误但继续处理
                                let mut stats_write = stats.write().await;
                                stats_write.failed_deliveries += 1;
                                warn!("Event queue full for subscriber: {}", subscriber.id);
                            }
                            Err(mpsc::error::TrySendError::Closed(_)) => {
                                // 订阅者通道已关闭，记录失败
                                let mut stats_write = stats.write().await;
                                stats_write.failed_deliveries += 1;
                                warn!("Failed to deliver event to subscriber: {}", subscriber.id);
                            }
                        }
                    }
                }
            }
        });

        Ok(())
    }
}

/// 事件发送器 - 可以安全地在多个组件间共享
#[derive(Clone)]
pub struct EventSender {
    broadcast_tx: broadcast::Sender<Event>,
    stats: Arc<RwLock<EventStats>>,
}

impl EventSender {
    /// 发送事件（非阻塞）
    pub async fn emit(&self, event: Event) -> Result<()> {
        let event_type = event.event_type().to_string();
        let event_id = event.event_id();

        debug!("Emitting event: {} ({})", event_type, event_id);

        match self.broadcast_tx.send(event) {
            Ok(_) => {
                // 更新统计
                let mut stats = self.stats.write().await;
                stats.total_events += 1;
                *stats.events_by_type.entry(event_type).or_insert(0) += 1;
                Ok(())
            }
            Err(_) => {
                error!("Failed to emit event: {} ({})", event_type, event_id);
                Err(crate::utils::Error::Internal(anyhow::anyhow!(
                    "Event bus broadcast channel closed"
                )))
            }
        }
    }

    /// 批量发送事件（提高性能）
    pub async fn emit_batch(&self, events: Vec<Event>) -> Result<usize> {
        let mut success_count = 0;

        for event in events {
            if self.emit(event).await.is_ok() {
                success_count += 1;
            }
        }

        Ok(success_count)
    }
}

/// 事件处理器 - 处理接收到的事件
pub struct EventHandler {
    receiver: broadcast::Receiver<Event>,
    stats: Arc<RwLock<EventStats>>,
}

impl EventHandler {
    /// 处理单个事件
    pub async fn handle_next(&mut self) -> Result<Option<Event>> {
        match self.receiver.recv().await {
            Ok(event) => {
                debug!(
                    "Received event: {} ({})",
                    event.event_type(),
                    event.event_id()
                );
                Ok(Some(event))
            }
            Err(broadcast::error::RecvError::Closed) => {
                info!("Event handler channel closed");
                Ok(None)
            }
            Err(broadcast::error::RecvError::Lagged(skipped)) => {
                warn!("Event handler lagged, skipped {} events", skipped);
                // 使用Box::pin来避免无限递归
                Box::pin(self.handle_next()).await
            }
        }
    }

    /// 批量处理事件
    pub async fn handle_batch(&mut self, max_batch_size: usize) -> Result<Vec<Event>> {
        let mut events = Vec::with_capacity(max_batch_size);

        // 获取第一个事件
        if let Some(event) = self.handle_next().await? {
            events.push(event);
        } else {
            return Ok(events);
        }

        // 尝试获取更多事件（非阻塞）
        for _ in 1..max_batch_size {
            match self.receiver.try_recv() {
                Ok(event) => events.push(event),
                Err(broadcast::error::TryRecvError::Empty) => break,
                Err(broadcast::error::TryRecvError::Closed) => break,
                Err(broadcast::error::TryRecvError::Lagged(_)) => continue,
            }
        }

        Ok(events)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::time::{timeout, Duration};

    #[tokio::test]
    async fn test_event_bus_creation() {
        let limits = ResourceLimits::default();
        let bus = EventBus::new(&limits);
        let sender = bus.get_sender();

        // 应该能够创建发送器
        assert!(true);
    }

    #[tokio::test]
    async fn test_event_emission_and_handling() {
        let limits = ResourceLimits::default();
        let bus = EventBus::new(&limits);
        let sender = bus.get_sender();
        let mut handler = bus.create_handler();

        let test_event = Event::client_connected("test-client".to_string());
        let event_id = test_event.event_id();

        // 发送事件
        sender.emit(test_event).await.unwrap();

        // 接收事件
        let received = timeout(Duration::from_millis(100), handler.handle_next()).await;
        assert!(received.is_ok());

        let event = received.unwrap().unwrap().unwrap();
        assert_eq!(event.event_id(), event_id);
        assert_eq!(event.event_type(), "client_connected");
    }

    #[tokio::test]
    async fn test_subscription_system() {
        let limits = ResourceLimits::default();
        let bus = EventBus::new(&limits);
        let sender = bus.get_sender();

        // 订阅特定事件类型
        let mut sub_rx = bus
            .subscribe("client_connected".to_string(), "test-sub".to_string(), 100)
            .await
            .unwrap();

        // 启动分发器
        bus.start_dispatcher().await.unwrap();

        // 发送匹配的事件
        let test_event = Event::client_connected("test-client".to_string());
        sender.emit(test_event).await.unwrap();

        // 应该能接收到事件
        let received = timeout(Duration::from_millis(100), sub_rx.recv()).await;
        assert!(received.is_ok());
    }

    #[tokio::test]
    async fn test_batch_processing() {
        let limits = ResourceLimits::default();
        let bus = EventBus::new(&limits);
        let sender = bus.get_sender();
        let mut handler = bus.create_handler();

        // 批量发送事件
        let events = vec![
            Event::client_connected("client1".to_string()),
            Event::client_connected("client2".to_string()),
            Event::client_connected("client3".to_string()),
        ];

        sender.emit_batch(events).await.unwrap();

        // 批量接收事件
        let received = timeout(Duration::from_millis(100), handler.handle_batch(5)).await;
        assert!(received.is_ok());

        let events = received.unwrap().unwrap();
        assert_eq!(events.len(), 3);
    }

    #[tokio::test]
    async fn test_event_stats() {
        let limits = ResourceLimits::default();
        let bus = EventBus::new(&limits);
        let sender = bus.get_sender();

        // 启动事件分发器
        bus.start_dispatcher().await.unwrap();

        // 等待一点时间让分发器启动
        tokio::time::sleep(tokio::time::Duration::from_millis(10)).await;

        // 发送几个事件
        sender
            .emit(Event::client_connected("client1".to_string()))
            .await
            .unwrap();
        sender
            .emit(Event::client_disconnected("client1".to_string()))
            .await
            .unwrap();

        // 等待事件被处理
        tokio::time::sleep(tokio::time::Duration::from_millis(10)).await;

        let stats = bus.get_stats().await;
        assert_eq!(stats.total_events, 2);
        assert_eq!(stats.events_by_type.get("client_connected"), Some(&1));
        assert_eq!(stats.events_by_type.get("client_disconnected"), Some(&1));
    }
}
