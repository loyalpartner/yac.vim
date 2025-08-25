use anyhow::Result;
use async_trait::async_trait;
use lsp_client::LspClient;
use serde::{Deserialize, Serialize};
use std::process::{Command, Stdio};
use tokio::net::TcpStream;
use tokio::time::{sleep, Duration};
use tracing::{debug, info};

/// Remote configuration for SSH-based LSP servers
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RemoteConfig {
    pub host: String,
    pub port: u16,
    pub ssh_user: String,
    pub ssh_host: String,
    pub auto_deploy: bool,
}

/// Transport configuration supporting both local and remote LSP servers
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum TransportConfig {
    Local { command: String, args: Vec<String> },
    Remote(RemoteConfig),
}

/// Unified transport abstraction for LSP communication
/// Following Linus principle: eliminate special cases through proper abstraction
#[async_trait]
pub trait LspTransport: Send + Sync {
    /// Send LSP request and wait for response
    async fn request<R>(&self, params: R::Params) -> Result<R::Result>
    where
        R: lsp_types::request::Request,
        R::Params: Serialize + Send + 'static,
        R::Result: for<'de> Deserialize<'de>;

    /// Send LSP notification (fire-and-forget)
    async fn notify<T>(&self, method: &str, params: T) -> Result<()>
    where
        T: Serialize + Send + 'static;
}

/// Local transport using existing LspClient
pub struct LocalTransport {
    client: LspClient,
}

impl LocalTransport {
    pub async fn new(command: &str, args: &[&str]) -> Result<Self> {
        let client = LspClient::new(command, args).await?;
        Ok(Self { client })
    }
}

#[async_trait]
impl LspTransport for LocalTransport {
    async fn request<R>(&self, params: R::Params) -> Result<R::Result>
    where
        R: lsp_types::request::Request,
        R::Params: Serialize + Send + 'static,
        R::Result: for<'de> Deserialize<'de>,
    {
        self.client.request::<R>(params).await.map_err(Into::into)
    }

    async fn notify<T>(&self, method: &str, params: T) -> Result<()>
    where
        T: Serialize + Send + 'static,
    {
        self.client.notify(method, params).await.map_err(Into::into)
    }
}

/// Remote transport using SSH tunnel + TCP connection
#[allow(dead_code)]
pub struct RemoteTransport {
    stream: TcpStream,
    config: RemoteConfig,
    _tunnel_process: Option<std::process::Child>,
}

impl RemoteTransport {
    pub async fn new(config: RemoteConfig) -> Result<Self> {
        let local_port = find_available_port().await?;

        // Establish SSH tunnel
        let tunnel_process = establish_ssh_tunnel(&config, local_port).await?;

        // Wait for tunnel to be ready
        sleep(Duration::from_millis(500)).await;

        // Connect to tunneled port
        let stream = TcpStream::connect(format!("localhost:{}", local_port)).await?;

        info!(
            "Remote transport connected via SSH tunnel on port {}",
            local_port
        );

        Ok(Self {
            stream,
            config,
            _tunnel_process: Some(tunnel_process),
        })
    }
}

#[async_trait]
impl LspTransport for RemoteTransport {
    async fn request<R>(&self, _params: R::Params) -> Result<R::Result>
    where
        R: lsp_types::request::Request,
        R::Params: Serialize + Send + 'static,
        R::Result: for<'de> Deserialize<'de>,
    {
        // For now, return error - this needs full JSON-RPC implementation
        Err(anyhow::anyhow!("Remote requests not yet implemented"))
    }

    async fn notify<T>(&self, _method: &str, _params: T) -> Result<()>
    where
        T: Serialize + Send + 'static,
    {
        // For now, return error - this needs full JSON-RPC implementation
        Err(anyhow::anyhow!("Remote notifications not yet implemented"))
    }
}

/// Find an available local port for SSH tunnel
async fn find_available_port() -> Result<u16> {
    use tokio::net::TcpListener;

    // Try ports starting from 9000
    for port in 9000..10000 {
        if let Ok(listener) = TcpListener::bind(format!("localhost:{}", port)).await {
            drop(listener);
            return Ok(port);
        }
    }

    Err(anyhow::anyhow!("No available ports found"))
}

/// Establish SSH tunnel for LSP communication
async fn establish_ssh_tunnel(
    config: &RemoteConfig,
    local_port: u16,
) -> Result<std::process::Child> {
    let tunnel_cmd = format!(
        "ssh -L {}:localhost:{} -N -f {}@{}",
        local_port, config.port, config.ssh_user, config.ssh_host
    );

    debug!("Establishing SSH tunnel: {}", tunnel_cmd);

    let child = Command::new("sh")
        .arg("-c")
        .arg(&tunnel_cmd)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()?;

    Ok(child)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_find_available_port() {
        let port = find_available_port().await.unwrap();
        assert!(port >= 9000 && port < 10000);
    }
}
