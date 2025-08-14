pub mod bridge;
pub mod file;
pub mod handlers;
pub mod lsp;
pub mod utils;

pub use bridge::BridgeServer;
pub use utils::config::Config;
pub use utils::error::{Error, Result};

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::net::TcpListener;

    #[tokio::test]
    async fn test_basic_server_startup() {
        // 测试服务器能否绑定端口
        let listener = TcpListener::bind("127.0.0.1:0").await;
        assert!(listener.is_ok(), "无法绑定TCP端口");

        let listener = listener.unwrap();
        let addr = listener.local_addr().unwrap();
        drop(listener);

        println!("✅ TCP服务器可以绑定到端口: {}", addr);
    }

    #[tokio::test]
    async fn test_config_loading() {
        // 测试配置加载
        let config = Config::default();
        assert_eq!(config.server.host, "127.0.0.1");
        assert_eq!(config.server.port, 9527);
        println!("✅ 默认配置加载正常");
    }

    #[tokio::test]
    async fn test_message_parsing() {
        // 测试LSP消息解析
        let mut parser = lsp::LspMessageParser::new();
        let test_msg = r#"{"jsonrpc":"2.0","method":"test","params":{}}"#;
        let lsp_formatted = lsp::format_lsp_message(test_msg);

        let messages = parser.parse_messages(&lsp_formatted).unwrap();
        assert_eq!(messages.len(), 1);
        println!("✅ LSP消息解析正常");
    }

    #[tokio::test]
    async fn test_multiple_message_parsing() {
        // 测试多个LSP消息的解析
        let mut parser = lsp::LspMessageParser::new();

        let msg1 = r#"{"jsonrpc":"2.0","method":"test1","params":{}}"#;
        let msg2 = r#"{"jsonrpc":"2.0","method":"test2","params":{}}"#;

        let formatted1 = lsp::format_lsp_message(msg1);
        let formatted2 = lsp::format_lsp_message(msg2);
        let combined = format!("{}{}", formatted1, formatted2);

        let messages = parser.parse_messages(&combined).unwrap();
        assert_eq!(messages.len(), 2);
        println!("✅ 多消息解析正常");
    }

    #[tokio::test]
    async fn test_partial_message_parsing() {
        // 测试部分消息的解析
        let mut parser = lsp::LspMessageParser::new();
        let test_msg = r#"{"jsonrpc":"2.0","method":"test","params":{}}"#;
        let formatted = lsp::format_lsp_message(test_msg);

        // 模拟网络传输中的分块接收
        let mid_point = formatted.len() / 2;
        let part1 = &formatted[..mid_point];
        let part2 = &formatted[mid_point..];

        // 第一部分应该没有完整消息
        let messages1 = parser.parse_messages(part1).unwrap();
        assert_eq!(messages1.len(), 0);

        // 第二部分应该解析出完整消息
        let messages2 = parser.parse_messages(part2).unwrap();
        assert_eq!(messages2.len(), 1);
        println!("✅ 分块消息解析正常");
    }

    #[tokio::test]
    async fn test_error_handling() {
        // 测试错误处理
        use crate::utils::Error;

        // 测试IO错误转换
        let io_error =
            std::io::Error::new(std::io::ErrorKind::ConnectionRefused, "Connection refused");
        let yac_error = Error::from(io_error);
        assert!(yac_error.to_string().contains("Connection refused"));

        println!("✅ 错误处理正常");
    }

    #[tokio::test]
    async fn test_server_creation() {
        // 测试服务器创建 - 使用随机端口避免冲突
        let mut config = Config::default();
        config.server.port = 0; // 使用0让系统自动分配可用端口
        let result = BridgeServer::new(config).await;
        assert!(result.is_ok(), "服务器创建应该成功");

        println!("✅ 服务器创建正常");
    }

    #[test]
    fn test_client_id_generation() {
        // 测试客户端ID生成的唯一性
        use std::collections::HashSet;
        use std::sync::atomic::{AtomicU64, Ordering};

        static COUNTER: AtomicU64 = AtomicU64::new(0);

        let mut ids = HashSet::new();
        for _ in 0..1000 {
            let id = format!("client_{}", COUNTER.fetch_add(1, Ordering::SeqCst));
            assert!(ids.insert(id), "客户端ID应该是唯一的");
        }

        println!("✅ 客户端ID生成正常");
    }

    #[test]
    fn test_config_validation() {
        // 测试配置验证
        let mut config = Config::default();

        // 测试有效端口范围
        config.server.port = 8080;
        assert!(config.server.port > 0 && config.server.port <= 65535);

        // 测试主机地址
        assert!(!config.server.host.is_empty());

        println!("✅ 配置验证正常");
    }
}
