use crate::utils::Result;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    pub server: ServerConfig,
    pub lsp_servers: HashMap<String, LspServerConfig>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServerConfig {
    pub host: String,
    pub port: u16,
    pub max_connections: usize,
    pub timeout_ms: u64,
    pub resource_limits: ResourceLimits,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ResourceLimits {
    /// 每个客户端的最大消息队列大小
    pub client_message_queue_size: usize,
    /// 每个客户端的最大命令队列大小
    pub client_command_queue_size: usize,
    /// LSP请求队列大小
    pub lsp_request_queue_size: usize,
    /// LSP响应队列大小
    pub lsp_response_queue_size: usize,
    /// 事件处理队列大小
    pub event_queue_size: usize,
    /// 最大消息大小 (字节)
    pub max_message_size: usize,
    /// 最大并发客户端连接数
    pub max_concurrent_clients: usize,
    /// 最大并发LSP服务器数
    pub max_concurrent_lsp_servers: usize,
}

impl Default for ResourceLimits {
    fn default() -> Self {
        Self {
            client_message_queue_size: 1000,
            client_command_queue_size: 100,
            lsp_request_queue_size: 1000,
            lsp_response_queue_size: 1000,
            event_queue_size: 1000,
            max_message_size: 1024 * 1024, // 1MB
            max_concurrent_clients: 50,
            max_concurrent_lsp_servers: 10,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LspServerConfig {
    pub command: Vec<String>,
    pub args: Vec<String>,
    pub filetypes: Vec<String>,
    pub root_patterns: Vec<String>,
    pub initialization_options: Option<serde_json::Value>,
    pub settings: Option<serde_json::Value>,
    pub env: HashMap<String, String>,
}

impl Default for Config {
    fn default() -> Self {
        let mut lsp_servers = HashMap::new();

        // Default rust-analyzer configuration
        lsp_servers.insert(
            "rust-analyzer".to_string(),
            LspServerConfig {
                command: vec!["rust-analyzer".to_string()],
                args: vec![],
                filetypes: vec!["rust".to_string()],
                root_patterns: vec!["Cargo.toml".to_string(), "Cargo.lock".to_string()],
                initialization_options: None,
                settings: Some(serde_json::json!({
                    "rust-analyzer": {
                        "assist": {
                            "importEnforceGranularity": true,
                            "importPrefix": "crate"
                        },
                        "cargo": {
                            "allFeatures": true
                        },
                        "checkOnSave": {
                            "command": "clippy"
                        }
                    }
                })),
                env: HashMap::new(),
            },
        );

        Self {
            server: ServerConfig {
                host: "127.0.0.1".to_string(),
                port: 9527,
                max_connections: 10,
                timeout_ms: 30000,
                resource_limits: ResourceLimits::default(),
            },
            lsp_servers,
        }
    }
}

impl Config {
    pub fn load() -> Result<Self> {
        // For now, return default config
        // TODO: Add support for loading from config file
        Ok(Self::default())
    }

    pub fn get_lsp_config(&self, language: &str) -> Option<&LspServerConfig> {
        self.lsp_servers
            .values()
            .find(|config| config.filetypes.contains(&language.to_string()))
    }

    pub fn get_lsp_config_by_name(&self, name: &str) -> Option<&LspServerConfig> {
        self.lsp_servers.get(name)
    }
}
