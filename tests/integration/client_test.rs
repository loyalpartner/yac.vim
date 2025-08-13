use std::time::Duration;
use tokio::net::TcpStream;
use tokio::time::sleep;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use yac_vim::{BridgeServer, Config};

#[tokio::test]
async fn test_client_connection_lifecycle() {
    let mut config = Config::default();
    config.server.port = 9555; // 使用不同端口避免冲突
    
    let mut server = BridgeServer::new(config).await.expect("Failed to create server");

    // 在后台启动服务器
    let server_handle = tokio::spawn(async move {
        tokio::select! {
            _ = server.run() => {},
            _ = sleep(Duration::from_millis(2000)) => {},
        }
    });

    // 等待服务器启动
    sleep(Duration::from_millis(100)).await;

    // 测试客户端连接
    let mut stream = TcpStream::connect("127.0.0.1:9555").await
        .expect("Should connect to server");

    // 发送测试消息
    let test_message = r#"{"jsonrpc":"2.0","method":"initialize","params":{},"id":1}"#;
    let lsp_message = format!(
        "Content-Length: {}\r\n\r\n{}",
        test_message.len(),
        test_message
    );
    
    stream.write_all(lsp_message.as_bytes()).await
        .expect("Should write message");

    // 读取响应
    let mut buffer = vec![0; 1024];
    let _ = tokio::time::timeout(Duration::from_millis(500), stream.read(&mut buffer)).await;

    // 关闭连接
    drop(stream);

    // 清理
    server_handle.abort();
    let _ = server_handle.await;
}

#[tokio::test]
async fn test_multiple_concurrent_clients() {
    let mut config = Config::default();
    config.server.port = 9556; // 使用不同端口避免冲突
    
    let mut server = BridgeServer::new(config).await.expect("Failed to create server");

    // 在后台启动服务器
    let server_handle = tokio::spawn(async move {
        tokio::select! {
            _ = server.run() => {},
            _ = sleep(Duration::from_millis(2000)) => {},
        }
    });

    // 等待服务器启动
    sleep(Duration::from_millis(100)).await;

    // 创建多个并发客户端连接
    let mut handles = Vec::new();
    
    for i in 0..5 {
        let handle = tokio::spawn(async move {
            let mut stream = TcpStream::connect("127.0.0.1:9556").await
                .expect("Should connect to server");

            // 发送测试消息
            let test_message = format!(
                r#"{{"jsonrpc":"2.0","method":"test_client_{}","params":{{}},"id":{}}}"#,
                i, i
            );
            let lsp_message = format!(
                "Content-Length: {}\r\n\r\n{}",
                test_message.len(),
                test_message
            );
            
            stream.write_all(lsp_message.as_bytes()).await
                .expect("Should write message");

            // 保持连接一小段时间
            sleep(Duration::from_millis(200)).await;
            
            drop(stream);
        });
        
        handles.push(handle);
    }

    // 等待所有客户端完成
    for handle in handles {
        handle.await.expect("Client task should complete");
    }

    // 清理
    server_handle.abort();
    let _ = server_handle.await;
}

#[tokio::test]
async fn test_client_disconnect_handling() {
    let mut config = Config::default();
    config.server.port = 9557; // 使用不同端口避免冲突
    
    let mut server = BridgeServer::new(config).await.expect("Failed to create server");

    // 在后台启动服务器
    let server_handle = tokio::spawn(async move {
        tokio::select! {
            _ = server.run() => {},
            _ = sleep(Duration::from_millis(2000)) => {},
        }
    });

    // 等待服务器启动
    sleep(Duration::from_millis(100)).await;

    // 连接然后立即断开
    {
        let stream = TcpStream::connect("127.0.0.1:9557").await
            .expect("Should connect to server");
        // stream 在作用域结束时自动断开
    }

    // 再次连接应该仍然工作
    let mut stream2 = TcpStream::connect("127.0.0.1:9557").await
        .expect("Should connect to server after disconnect");

    let test_message = r#"{"jsonrpc":"2.0","method":"test_after_disconnect","params":{},"id":1}"#;
    let lsp_message = format!(
        "Content-Length: {}\r\n\r\n{}",
        test_message.len(),
        test_message
    );
    
    stream2.write_all(lsp_message.as_bytes()).await
        .expect("Should write message after reconnect");

    drop(stream2);

    // 清理
    server_handle.abort();
    let _ = server_handle.await;
}