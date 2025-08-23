use anyhow::Result;
use async_trait::async_trait;
use serde::Deserialize;
use tracing::info;
use vim::Handler;

// Request structure that vim sends for notification
#[derive(Debug, Deserialize)]
pub struct GotoDefinitionNotificationRequest {
    pub file: String,
    pub line: u32,
    pub column: u32,
}

// Notification handler - prints log message only
#[derive(Clone)]
pub struct GotoDefinitionNotificationHandler;

impl GotoDefinitionNotificationHandler {
    pub fn new() -> Self {
        Self
    }
}

#[async_trait]
impl Handler for GotoDefinitionNotificationHandler {
    type Input = GotoDefinitionNotificationRequest;
    type Output = ();

    async fn handle(&self, input: Self::Input) -> Result<Option<Self::Output>> {
        // Print log message as requested
        info!(
            "GotoDefinitionNotification received: file={}, line={}, column={}",
            input.file, input.line, input.column
        );

        // Return None to indicate this is a notification (no response needed)
        Ok(None)
    }
}
