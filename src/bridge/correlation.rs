// 请求-响应关联管理器
// 负责跟踪LSP请求的来源客户端，以便将响应正确路由

use crate::bridge::client::ClientId;
use crate::lsp::jsonrpc::RequestId;
use crate::utils::Result;
use std::collections::HashMap;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::sync::RwLock;
use tracing::{debug, warn};
use uuid::Uuid;

/// 请求关联信息
#[derive(Debug, Clone)]
pub struct RequestCorrelation {
    /// 发起请求的客户端ID
    pub client_id: ClientId,
    /// 可选的Vim端请求ID（用于某些需要响应的情况）
    pub vim_request_id: Option<String>,
    /// LSP服务器ID
    pub server_id: String,
    /// 请求方法
    pub method: String,
    /// 请求参数（用于重试）
    pub params: Option<serde_json::Value>,
    /// 请求时间戳
    pub timestamp: u64,
}

impl RequestCorrelation {
    pub fn new(
        client_id: ClientId,
        vim_request_id: Option<String>,
        server_id: String,
        method: String,
        params: Option<serde_json::Value>,
    ) -> Self {
        let timestamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();

        Self {
            client_id,
            vim_request_id,
            server_id,
            method,
            params,
            timestamp,
        }
    }

    /// 检查请求是否已过期（超过5分钟）
    pub fn is_expired(&self, current_time: u64) -> bool {
        current_time.saturating_sub(self.timestamp) > 300 // 5分钟
    }
}

/// 请求关联管理器
#[derive(Debug)]
pub struct RequestCorrelationManager {
    /// LSP请求ID到关联信息的映射
    correlations: Arc<RwLock<HashMap<RequestId, RequestCorrelation>>>,
    /// 清理间隔（秒）
    cleanup_interval: u64,
}

impl RequestCorrelationManager {
    pub fn new() -> Self {
        Self {
            correlations: Arc::new(RwLock::new(HashMap::new())),
            cleanup_interval: 300, // 5分钟
        }
    }

    /// 添加请求关联
    pub async fn add_correlation(
        &self,
        lsp_request_id: RequestId,
        client_id: ClientId,
        vim_request_id: Option<String>,
        server_id: String,
        method: String,
        params: Option<serde_json::Value>,
    ) -> Result<()> {
        let correlation = RequestCorrelation::new(
            client_id,
            vim_request_id,
            server_id,
            method,
            params,
        );

        debug!(
            "Adding request correlation: {} -> client {}", 
            lsp_request_id, correlation.client_id
        );

        let mut correlations = self.correlations.write().await;
        correlations.insert(lsp_request_id, correlation);

        Ok(())
    }

    /// 获取并移除请求关联信息
    pub async fn take_correlation(&self, lsp_request_id: &RequestId) -> Option<RequestCorrelation> {
        let mut correlations = self.correlations.write().await;
        let correlation = correlations.remove(lsp_request_id);
        
        if let Some(ref corr) = correlation {
            debug!(
                "Taking request correlation: {} -> client {}", 
                lsp_request_id, corr.client_id
            );
        }
        
        correlation
    }

    /// 获取关联信息（不移除）
    pub async fn get_correlation(&self, lsp_request_id: &RequestId) -> Option<RequestCorrelation> {
        let correlations = self.correlations.read().await;
        correlations.get(lsp_request_id).cloned()
    }

    /// 清理过期的关联信息
    pub async fn cleanup_expired(&self) {
        let current_time = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();

        let mut correlations = self.correlations.write().await;
        let before_count = correlations.len();

        correlations.retain(|request_id, correlation| {
            if correlation.is_expired(current_time) {
                warn!(
                    "Request {} expired after {} seconds", 
                    request_id, 
                    current_time.saturating_sub(correlation.timestamp)
                );
                false
            } else {
                true
            }
        });

        let after_count = correlations.len();
        if before_count > after_count {
            debug!("Cleaned up {} expired request correlations", before_count - after_count);
        }
    }

    /// 获取统计信息
    pub async fn get_stats(&self) -> CorrelationStats {
        let correlations = self.correlations.read().await;
        let current_time = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();

        let total_requests = correlations.len();
        let expired_count = correlations.values()
            .filter(|corr| corr.is_expired(current_time))
            .count();

        CorrelationStats {
            total_requests,
            expired_count,
            active_requests: total_requests - expired_count,
        }
    }

    /// 启动定期清理任务
    pub async fn start_cleanup_task(&self) {
        let correlations = self.correlations.clone();
        let cleanup_interval = self.cleanup_interval;

        tokio::spawn(async move {
            let mut interval = tokio::time::interval(
                tokio::time::Duration::from_secs(cleanup_interval)
            );

            loop {
                interval.tick().await;
                
                let current_time = SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_secs();

                let mut correlations = correlations.write().await;
                let before_count = correlations.len();

                correlations.retain(|request_id, correlation| {
                    if correlation.is_expired(current_time) {
                        warn!(
                            "Auto-cleanup: Request {} expired after {} seconds", 
                            request_id, 
                            current_time.saturating_sub(correlation.timestamp)
                        );
                        false
                    } else {
                        true
                    }
                });

                let after_count = correlations.len();
                if before_count > after_count {
                    debug!(
                        "Auto-cleanup: Removed {} expired request correlations", 
                        before_count - after_count
                    );
                }
            }
        });
    }

    /// 生成新的LSP请求ID
    pub fn generate_request_id() -> RequestId {
        RequestId::String(Uuid::new_v4().to_string())
    }
}

impl Default for RequestCorrelationManager {
    fn default() -> Self {
        Self::new()
    }
}

/// 关联统计信息
#[derive(Debug, Clone)]
pub struct CorrelationStats {
    pub total_requests: usize,
    pub expired_count: usize,
    pub active_requests: usize,
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::time::{sleep, Duration};

    #[tokio::test]
    async fn test_correlation_basic_operations() {
        let manager = RequestCorrelationManager::new();
        let request_id = RequestId::String("test-request-1".to_string());
        let client_id = "client-1".to_string();

        // 添加关联
        manager
            .add_correlation(
                request_id.clone(),
                client_id.clone(),
                None,
                "rust-analyzer".to_string(),
                "textDocument/completion".to_string(),
                None,
            )
            .await
            .unwrap();

        // 获取关联
        let correlation = manager.get_correlation(&request_id).await;
        assert!(correlation.is_some());
        assert_eq!(correlation.unwrap().client_id, client_id);

        // 取出关联
        let correlation = manager.take_correlation(&request_id).await;
        assert!(correlation.is_some());

        // 再次获取应为空
        let correlation = manager.get_correlation(&request_id).await;
        assert!(correlation.is_none());
    }

    #[tokio::test]
    async fn test_cleanup_expired() {
        let manager = RequestCorrelationManager::new();
        
        // 创建一个"已过期"的关联（通过修改时间戳）
        let request_id = RequestId::String("expired-request".to_string());
        let mut correlation = RequestCorrelation::new(
            "client-1".to_string(),
            None,
            "rust-analyzer".to_string(),
            "textDocument/completion".to_string(),
            None,
        );
        correlation.timestamp = 0; // 设置为很久以前

        {
            let mut correlations = manager.correlations.write().await;
            correlations.insert(request_id.clone(), correlation);
        }

        // 清理前应该存在
        let stats = manager.get_stats().await;
        assert_eq!(stats.total_requests, 1);

        // 执行清理
        manager.cleanup_expired().await;

        // 清理后应该为空
        let stats = manager.get_stats().await;
        assert_eq!(stats.total_requests, 0);
    }

    #[tokio::test]
    async fn test_request_id_generation() {
        let id1 = RequestCorrelationManager::generate_request_id();
        let id2 = RequestCorrelationManager::generate_request_id();
        
        assert_ne!(id1, id2);
        assert!(!id1.is_empty());
        assert!(!id2.is_empty());
    }
}