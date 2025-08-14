use crate::bridge::client::ClientId;
use crate::utils::{Error, Result};
use serde_json::Value;
use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::RwLock;
use tracing::{debug, warn};

/// 速率限制配置
#[derive(Debug, Clone)]
pub struct RateLimitConfig {
    /// 时间窗口（秒）
    pub window_seconds: u64,
    /// 最大请求数
    pub max_requests: u32,
    /// 单个消息最大大小（字节）
    pub max_message_size: usize,
    /// 每秒最大字节数
    pub max_bytes_per_second: usize,
}

impl Default for RateLimitConfig {
    fn default() -> Self {
        Self {
            window_seconds: 60,      // 1分钟窗口
            max_requests: 1000,      // 每分钟最多1000个请求
            max_message_size: 1024 * 1024, // 1MB per message
            max_bytes_per_second: 10 * 1024 * 1024, // 10MB/s
        }
    }
}

/// 客户端速率限制状态
#[derive(Debug, Clone)]
struct ClientRateState {
    requests: Vec<Instant>,
    bytes_sent: Vec<(Instant, usize)>,
    last_cleanup: Instant,
}

impl ClientRateState {
    fn new() -> Self {
        Self {
            requests: Vec::new(),
            bytes_sent: Vec::new(),
            last_cleanup: Instant::now(),
        }
    }
    
    fn cleanup(&mut self, window: Duration) {
        let now = Instant::now();
        let cutoff = now - window;
        
        // 清理过期的请求记录
        self.requests.retain(|&time| time > cutoff);
        self.bytes_sent.retain(|(time, _)| *time > cutoff);
        
        self.last_cleanup = now;
    }
    
    fn should_cleanup(&self) -> bool {
        self.last_cleanup.elapsed() > Duration::from_secs(10)
    }
}

/// 速率限制器
pub struct RateLimiter {
    config: RateLimitConfig,
    clients: Arc<RwLock<HashMap<ClientId, ClientRateState>>>,
}

impl RateLimiter {
    pub fn new(config: RateLimitConfig) -> Self {
        Self {
            config,
            clients: Arc::new(RwLock::new(HashMap::new())),
        }
    }
    
    /// 检查客户端是否被速率限制
    pub async fn check_rate_limit(&self, client_id: &ClientId, message_size: usize) -> Result<()> {
        let mut clients = self.clients.write().await;
        let state = clients.entry(client_id.clone()).or_insert_with(ClientRateState::new);
        
        let now = Instant::now();
        let window = Duration::from_secs(self.config.window_seconds);
        
        // 定期清理过期数据
        if state.should_cleanup() {
            state.cleanup(window);
        }
        
        // 检查消息大小
        if message_size > self.config.max_message_size {
            warn!("Client {} exceeded message size limit: {} > {}", 
                  client_id, message_size, self.config.max_message_size);
            return Err(Error::security(format!(
                "Message size {} exceeds limit {}", 
                message_size, self.config.max_message_size
            )));
        }
        
        // 检查请求数限制
        let recent_requests = state.requests.iter()
            .filter(|&&time| time > now - window)
            .count();
            
        if recent_requests >= self.config.max_requests as usize {
            warn!("Client {} exceeded request rate limit: {} requests in window", 
                  client_id, recent_requests);
            return Err(Error::security(format!(
                "Rate limit exceeded: {} requests in {} seconds", 
                recent_requests, self.config.window_seconds
            )));
        }
        
        // 检查带宽限制
        let bytes_in_last_second: usize = state.bytes_sent.iter()
            .filter(|(time, _)| *time > now - Duration::from_secs(1))
            .map(|(_, bytes)| *bytes)
            .sum();
            
        if bytes_in_last_second + message_size > self.config.max_bytes_per_second {
            warn!("Client {} exceeded bandwidth limit: {} + {} > {}", 
                  client_id, bytes_in_last_second, message_size, self.config.max_bytes_per_second);
            return Err(Error::security(format!(
                "Bandwidth limit exceeded: {} bytes/s", 
                self.config.max_bytes_per_second
            )));
        }
        
        // 记录此次请求
        state.requests.push(now);
        state.bytes_sent.push((now, message_size));
        
        debug!("Rate limit check passed for client {}: {} bytes, {} recent requests", 
               client_id, message_size, recent_requests + 1);
        
        Ok(())
    }
    
    /// 清理客户端状态
    pub async fn cleanup_client(&self, client_id: &ClientId) {
        let mut clients = self.clients.write().await;
        clients.remove(client_id);
        debug!("Cleaned up rate limit state for client {}", client_id);
    }
    
    /// 获取速率限制统计
    pub async fn get_stats(&self) -> HashMap<String, u32> {
        let clients = self.clients.read().await;
        let mut stats = HashMap::new();
        
        stats.insert("active_clients".to_string(), clients.len() as u32);
        stats.insert("max_requests_per_window".to_string(), self.config.max_requests);
        stats.insert("window_seconds".to_string(), self.config.window_seconds as u32);
        stats.insert("max_message_size".to_string(), self.config.max_message_size as u32);
        stats.insert("max_bytes_per_second".to_string(), self.config.max_bytes_per_second as u32);
        
        stats
    }
}

/// 输入验证器
pub struct InputValidator {
    max_path_length: usize,
    allowed_schemes: Vec<String>,
}

impl Default for InputValidator {
    fn default() -> Self {
        Self {
            max_path_length: 4096,
            allowed_schemes: vec!["file".to_string()],
        }
    }
}

impl InputValidator {
    pub fn new(max_path_length: usize, allowed_schemes: Vec<String>) -> Self {
        Self {
            max_path_length,
            allowed_schemes,
        }
    }
    
    /// 验证文件URI
    pub fn validate_file_uri(&self, uri: &str) -> Result<()> {
        // 检查长度
        if uri.len() > self.max_path_length {
            return Err(Error::security(format!(
                "URI length {} exceeds maximum {}", 
                uri.len(), self.max_path_length
            )));
        }
        
        // 检查scheme
        let scheme = uri.split(':').next().unwrap_or("");
        if !self.allowed_schemes.contains(&scheme.to_string()) {
            return Err(Error::security(format!(
                "URI scheme '{}' not allowed. Allowed schemes: {:?}", 
                scheme, self.allowed_schemes
            )));
        }
        
        // 检查路径遍历攻击
        if uri.contains("..") {
            return Err(Error::security(
                "Path traversal detected in URI".to_string()
            ));
        }
        
        // 检查空字符和控制字符
        if uri.chars().any(|c| c.is_control() && c != '\t' && c != '\n' && c != '\r') {
            return Err(Error::security(
                "Invalid control characters in URI".to_string()
            ));
        }
        
        Ok(())
    }
    
    /// 验证位置参数
    pub fn validate_position(&self, line: i32, character: i32) -> Result<()> {
        if line < 0 || line > 1_000_000 {
            return Err(Error::security(format!(
                "Line number {} out of valid range (0-1000000)", line
            )));
        }
        
        if character < 0 || character > 10_000 {
            return Err(Error::security(format!(
                "Character position {} out of valid range (0-10000)", character
            )));
        }
        
        Ok(())
    }
    
    /// 验证文件内容长度
    pub fn validate_content_length(&self, content: &str) -> Result<()> {
        const MAX_FILE_SIZE: usize = 10 * 1024 * 1024; // 10MB
        
        if content.len() > MAX_FILE_SIZE {
            return Err(Error::security(format!(
                "File content size {} exceeds maximum {} bytes", 
                content.len(), MAX_FILE_SIZE
            )));
        }
        
        Ok(())
    }
    
    /// 验证JSON结构深度（防止嵌套过深的JSON攻击）
    pub fn validate_json_depth(&self, value: &Value) -> Result<()> {
        const MAX_DEPTH: usize = 32;
        
        fn check_depth(value: &Value, current_depth: usize, max_depth: usize) -> bool {
            if current_depth > max_depth {
                return false;
            }
            
            match value {
                Value::Object(obj) => {
                    obj.values().all(|v| check_depth(v, current_depth + 1, max_depth))
                }
                Value::Array(arr) => {
                    arr.iter().all(|v| check_depth(v, current_depth + 1, max_depth))
                }
                _ => true,
            }
        }
        
        if !check_depth(value, 0, MAX_DEPTH) {
            return Err(Error::security(format!(
                "JSON nesting depth exceeds maximum {}", MAX_DEPTH
            )));
        }
        
        Ok(())
    }
}

/// 安全管理器 - 集成所有安全检查
pub struct SecurityManager {
    rate_limiter: RateLimiter,
    validator: InputValidator,
}

impl SecurityManager {
    pub fn new(rate_config: RateLimitConfig, validator: InputValidator) -> Self {
        Self {
            rate_limiter: RateLimiter::new(rate_config),
            validator,
        }
    }
    
    /// 全面的安全检查
    pub async fn check_message(&self, client_id: &ClientId, message: &Value, message_size: usize) -> Result<()> {
        // 速率限制检查
        self.rate_limiter.check_rate_limit(client_id, message_size).await?;
        
        // JSON深度检查
        self.validator.validate_json_depth(message)?;
        
        // 如果消息包含URI，验证它
        if let Some(params) = message.get("params") {
            if let Some(uri) = params.get("uri").and_then(|u| u.as_str()) {
                self.validator.validate_file_uri(uri)?;
            }
            
            // 验证位置参数
            if let Some(position) = params.get("position") {
                if let (Some(line), Some(character)) = (
                    position.get("line").and_then(|l| l.as_i64()),
                    position.get("character").and_then(|c| c.as_i64())
                ) {
                    self.validator.validate_position(line as i32, character as i32)?;
                }
            }
            
            // 验证文件内容
            if let Some(content) = params.get("content").and_then(|c| c.as_str()) {
                self.validator.validate_content_length(content)?;
            }
        }
        
        Ok(())
    }
    
    pub async fn cleanup_client(&self, client_id: &ClientId) {
        self.rate_limiter.cleanup_client(client_id).await;
    }
    
    pub async fn get_security_stats(&self) -> HashMap<String, u32> {
        self.rate_limiter.get_stats().await
    }

    /// 检查连接速率
    pub async fn check_connection_rate(&self, client_addr: &str) -> Result<()> {
        // 简化版本 - 实际实现应该按IP地址进行速率限制
        self.rate_limiter.check_rate_limit(&format!("conn:{}", client_addr), 1).await
    }

    /// 检查请求速率
    pub async fn check_request_rate(&self, client_id: &str, request_type: &str) -> Result<()> {
        let key = format!("req:{}:{}", client_id, request_type);
        self.rate_limiter.check_rate_limit(&key, 1).await
    }

    /// 验证URI格式
    pub fn validate_uri(&self, uri: &str) -> Result<()> {
        self.validator.validate_file_uri(uri)
    }

    /// 验证LSP位置参数
    pub fn validate_position(&self, position: &crate::lsp::protocol::Position) -> Result<()> {
        if position.line < 0 || position.character < 0 {
            return Err(Error::security("Invalid position: negative values not allowed"));
        }
        
        // 防止过大的位置值（可能的攻击）
        if position.line > 1_000_000 || position.character > 10_000 {
            return Err(Error::security("Invalid position: values too large"));
        }
        
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[tokio::test]
    async fn test_rate_limiting() {
        let config = RateLimitConfig {
            window_seconds: 1,
            max_requests: 2,
            max_message_size: 100,
            max_bytes_per_second: 200,
        };
        let limiter = RateLimiter::new(config);
        let client_id = "test_client".to_string();
        
        // 前两个请求应该通过
        assert!(limiter.check_rate_limit(&client_id, 50).await.is_ok());
        assert!(limiter.check_rate_limit(&client_id, 50).await.is_ok());
        
        // 第三个请求应该被限制
        assert!(limiter.check_rate_limit(&client_id, 50).await.is_err());
    }
    
    #[tokio::test] 
    async fn test_message_size_limit() {
        let config = RateLimitConfig {
            window_seconds: 60,
            max_requests: 1000,
            max_message_size: 100,
            max_bytes_per_second: 1000,
        };
        let limiter = RateLimiter::new(config);
        let client_id = "test_client".to_string();
        
        // 小消息应该通过
        assert!(limiter.check_rate_limit(&client_id, 50).await.is_ok());
        
        // 大消息应该被拒绝
        assert!(limiter.check_rate_limit(&client_id, 200).await.is_err());
    }
    
    #[test]
    fn test_uri_validation() {
        let validator = InputValidator::default();
        
        // 有效的URI
        assert!(validator.validate_file_uri("file:///path/to/file.rs").is_ok());
        
        // 路径遍历攻击
        assert!(validator.validate_file_uri("file:///path/../../../etc/passwd").is_err());
        
        // 无效的scheme
        assert!(validator.validate_file_uri("http://example.com").is_err());
        
        // 过长的路径
        let long_path = "file:///".to_string() + &"a".repeat(5000);
        assert!(validator.validate_file_uri(&long_path).is_err());
    }
    
    #[test]
    fn test_json_depth_validation() {
        let validator = InputValidator::default();
        
        // 正常的JSON
        let normal_json = json!({"key": "value", "nested": {"inner": "value"}});
        assert!(validator.validate_json_depth(&normal_json).is_ok());
        
        // 过深的JSON
        let mut deep_json = json!({});
        let mut current = &mut deep_json;
        for i in 0..50 {
            let next = json!({});
            current[format!("level_{}", i)] = next;
            current = &mut current[format!("level_{}", i)];
        }
        assert!(validator.validate_json_depth(&deep_json).is_err());
    }
    
    #[tokio::test]
    async fn test_security_manager() {
        let rate_config = RateLimitConfig::default();
        let validator = InputValidator::default();
        let manager = SecurityManager::new(rate_config, validator);
        
        let client_id = "test_client".to_string();
        let valid_message = json!({
            "method": "completion",
            "params": {
                "uri": "file:///path/to/file.rs",
                "position": {"line": 10, "character": 5}
            }
        });
        
        // 有效消息应该通过
        assert!(manager.check_message(&client_id, &valid_message, 100).await.is_ok());
        
        let invalid_message = json!({
            "method": "completion", 
            "params": {
                "uri": "file:///path/../../../etc/passwd",
                "position": {"line": -1, "character": 5}
            }
        });
        
        // 无效消息应该被拒绝
        assert!(manager.check_message(&client_id, &invalid_message, 100).await.is_err());
    }
}