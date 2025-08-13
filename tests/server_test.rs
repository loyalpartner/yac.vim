use std::time::Duration;
use tokio::net::TcpStream;
use tokio::time::sleep;
use yac_vim::{BridgeServer, Config};

#[tokio::test]
async fn test_server_startup_and_shutdown() {
    let config = Config::default();
    let mut server = BridgeServer::new(config).await.expect("Failed to create server");

    // Start server in background
    let server_handle = tokio::spawn(async move {
        // Run server for a short time
        tokio::select! {
            _ = server.run() => {},
            _ = sleep(Duration::from_millis(100)) => {},
        }
    });

    // Wait a bit for server to start
    sleep(Duration::from_millis(50)).await;

    // Try to connect to the server
    let result = TcpStream::connect("127.0.0.1:9527").await;
    assert!(result.is_ok(), "Should be able to connect to server");

    // Clean up
    server_handle.abort();
}

#[tokio::test]
async fn test_multiple_clients() {
    let mut config = Config::default();
    config.server.port = 9528; // Use different port to avoid conflict
    let mut server = BridgeServer::new(config).await.expect("Failed to create server");

    // Start server in background
    let server_handle = tokio::spawn(async move {
        tokio::select! {
            _ = server.run() => {},
            _ = sleep(Duration::from_millis(200)) => {},
        }
    });

    // Wait for server to start
    sleep(Duration::from_millis(50)).await;

    // Connect multiple clients
    let client1 = TcpStream::connect("127.0.0.1:9528").await;
    let client2 = TcpStream::connect("127.0.0.1:9528").await;

    assert!(client1.is_ok(), "First client should connect successfully");
    assert!(client2.is_ok(), "Second client should connect successfully");

    // Keep connections alive briefly
    sleep(Duration::from_millis(50)).await;

    // Clean up
    drop(client1);
    drop(client2);
    server_handle.abort();
}