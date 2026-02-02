use crate::protocol::VimProtocol;
use crate::VimError;
use anyhow::Result;
use async_trait::async_trait;
use serde_json::Value;
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::Mutex;

#[async_trait]
pub trait MessageTransport: Send + Sync {
    async fn send(&self, msg: &VimProtocol) -> Result<()>;
    async fn recv(&self) -> Result<VimProtocol>;
}

/// Stdio Transport - handles stdin/stdout communication
pub struct StdioTransport {
    stdin: Arc<Mutex<BufReader<tokio::io::Stdin>>>,
}

impl Default for StdioTransport {
    fn default() -> Self {
        Self::new()
    }
}

impl StdioTransport {
    pub fn new() -> Self {
        Self {
            stdin: Arc::new(Mutex::new(BufReader::new(tokio::io::stdin()))),
        }
    }
}

#[async_trait]
impl MessageTransport for StdioTransport {
    async fn send(&self, msg: &VimProtocol) -> Result<()> {
        let json = msg.encode();
        let line = format!("{}\n", json);
        let mut stdout = tokio::io::stdout();
        stdout.write_all(line.as_bytes()).await?;
        stdout.flush().await?;
        Ok(())
    }

    async fn recv(&self) -> Result<VimProtocol> {
        use crate::protocol::MessageParser;

        let mut line = String::new();
        let mut stdin = self.stdin.lock().await;
        let parser = MessageParser::new();

        // Keep reading until we get a non-empty line
        loop {
            line.clear();
            let n = stdin.read_line(&mut line).await?;

            if n == 0 {
                // EOF reached
                return Err(VimError::Eof.into());
            }

            let trimmed = line.trim();
            if !trimmed.is_empty() {
                // Got a non-empty line, try to parse it
                let json: Value = serde_json::from_str(trimmed)?;
                return parser.parse(&json);
            }
            // Empty line, continue reading
        }
    }
}

#[cfg(test)]
pub struct MockTransport {
    sent_messages: Arc<Mutex<Vec<VimProtocol>>>,
    received_messages: Arc<Mutex<Vec<VimProtocol>>>,
}

#[cfg(test)]
impl Default for MockTransport {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
impl MockTransport {
    pub fn new() -> Self {
        Self {
            sent_messages: Arc::new(Mutex::new(Vec::new())),
            received_messages: Arc::new(Mutex::new(Vec::new())),
        }
    }

    pub async fn get_sent_messages(&self) -> Vec<VimProtocol> {
        self.sent_messages.lock().await.clone()
    }

    pub async fn add_received_message(&self, msg: VimProtocol) {
        self.received_messages.lock().await.push(msg);
    }
}

#[cfg(test)]
#[async_trait]
impl MessageTransport for MockTransport {
    async fn send(&self, msg: &VimProtocol) -> Result<()> {
        self.sent_messages.lock().await.push(msg.clone());
        Ok(())
    }

    async fn recv(&self) -> Result<VimProtocol> {
        let mut messages = self.received_messages.lock().await;
        if let Some(msg) = messages.pop() {
            Ok(msg)
        } else {
            Err(VimError::NoMessages.into())
        }
    }
}
