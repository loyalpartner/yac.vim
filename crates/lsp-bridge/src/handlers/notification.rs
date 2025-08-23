use anyhow::Result;
use async_trait::async_trait;
use lsp_client::{JsonRpcNotification, LspClient, NotificationHandler};
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tokio::sync::{mpsc, Mutex};
use tracing::{debug, warn};
use vim::Handler;

// Import the types from lsp_bridge
use lsp_bridge::{DiagnosticItem, VimAction};

/// Enhanced notification types that LSP servers can send to clients
/// Simplified to avoid conflicts with internal tag "method"
#[derive(Debug, Serialize, Deserialize)]
pub enum LspNotificationType {
    /// Standard diagnostics notifications
    PublishDiagnostics { diagnostics: Vec<DiagnosticItem> },

    /// Progress notifications for long-running operations
    Progress { token: String, value: String },

    /// Window messages (info, warning, error, log)
    ShowMessage { message_type: u32, message: String },

    /// Log messages from the server
    LogMessage { message_type: u32, message: String },

    /// Custom/unknown notifications
    Unknown {
        notification_method: String,
        params: serde_json::Value,
    },
}

// Removed complex type definitions to avoid conflicts - use LSP types directly

/// Enhanced notification handler that supports multiple LSP notification types
/// Following Linus-style: simple data structures, eliminate special cases
pub struct EnhancedNotificationHandler {
    sender: mpsc::UnboundedSender<VimAction>,
    supported_methods: std::collections::HashSet<String>,
}

impl EnhancedNotificationHandler {
    pub fn new(sender: mpsc::UnboundedSender<VimAction>) -> Self {
        let mut supported_methods = std::collections::HashSet::new();

        // Register all notification types we can handle
        supported_methods.insert("textDocument/publishDiagnostics".to_string());
        supported_methods.insert("$/progress".to_string());
        supported_methods.insert("window/showMessage".to_string());
        supported_methods.insert("window/logMessage".to_string());
        supported_methods.insert("workspace/configuration".to_string());
        supported_methods.insert("workspace/applyEdit".to_string());
        supported_methods.insert("workspace/didChangeWorkspaceFolders".to_string());
        supported_methods.insert("workspace/didChangeWatchedFiles".to_string());

        Self {
            sender,
            supported_methods,
        }
    }

    /// Check if we can handle this notification method
    pub fn supports_method(&self, method: &str) -> bool {
        self.supported_methods.contains(method)
    }

    fn handle_diagnostics_notification(&self, params: serde_json::Value) -> Result<()> {
        if let Ok(diagnostics_params) =
            serde_json::from_value::<lsp_types::PublishDiagnosticsParams>(params)
        {
            let file_path = diagnostics_params
                .uri
                .to_file_path()
                .unwrap_or_default()
                .to_string_lossy()
                .to_string();

            let diagnostic_items: Vec<DiagnosticItem> = diagnostics_params
                .diagnostics
                .iter()
                .map(|d| {
                    let mut item = DiagnosticItem::from(d);
                    item.file = file_path.clone();
                    item
                })
                .collect();

            let vim_action = VimAction::Diagnostics {
                diagnostics: diagnostic_items,
            };

            if let Err(e) = self.sender.send(vim_action) {
                warn!("Failed to send diagnostics to channel: {}", e);
            } else {
                debug!(
                    "Sent {} diagnostics for {} to channel",
                    diagnostics_params.diagnostics.len(),
                    file_path
                );
            }
        }

        Ok(())
    }

    fn handle_progress_notification(&self, params: serde_json::Value) -> Result<()> {
        // For progress notifications, we could display them in Vim's status line
        // For now, just log them
        debug!("Progress notification: {:?}", params);
        Ok(())
    }

    fn handle_show_message_notification(&self, params: serde_json::Value) -> Result<()> {
        if let Ok(message_params) = serde_json::from_value::<lsp_types::ShowMessageParams>(params) {
            let message_type = match message_params.typ {
                lsp_types::MessageType::ERROR => "Error",
                lsp_types::MessageType::WARNING => "Warning",
                lsp_types::MessageType::INFO => "Info",
                lsp_types::MessageType::LOG => "Log",
                _ => "Unknown",
            };

            debug!("LSP {}: {}", message_type, message_params.message);

            // Send to Vim as a general message - could be displayed in echo area
            let vim_action = VimAction::ShowHover {
                content: format!("LSP {}: {}", message_type, message_params.message),
            };

            if let Err(e) = self.sender.send(vim_action) {
                warn!("Failed to send message to channel: {}", e);
            }
        }

        Ok(())
    }

    fn handle_log_message_notification(&self, params: serde_json::Value) -> Result<()> {
        if let Ok(log_params) = serde_json::from_value::<lsp_types::LogMessageParams>(params) {
            let message_type = match log_params.typ {
                lsp_types::MessageType::ERROR => "Error",
                lsp_types::MessageType::WARNING => "Warning",
                lsp_types::MessageType::INFO => "Info",
                lsp_types::MessageType::LOG => "Log",
                _ => "Unknown",
            };

            debug!("LSP Log {}: {}", message_type, log_params.message);
        }

        Ok(())
    }

    fn handle_apply_edit_notification(&self, params: serde_json::Value) -> Result<()> {
        if let Ok(apply_edit_params) =
            serde_json::from_value::<lsp_types::ApplyWorkspaceEditParams>(params)
        {
            debug!(
                "Received workspace edit request: {:?}",
                apply_edit_params.label
            );

            // Convert LSP workspace edit to our format
            if let Some(changes) = apply_edit_params.edit.changes {
                let mut file_edits = Vec::new();

                for (uri, text_edits) in changes {
                    if let Ok(file_path) = uri.to_file_path() {
                        let edits: Vec<lsp_bridge::TextEdit> = text_edits
                            .iter()
                            .map(|edit| lsp_bridge::TextEdit {
                                start_line: edit.range.start.line,
                                start_column: edit.range.start.character,
                                end_line: edit.range.end.line,
                                end_column: edit.range.end.character,
                                new_text: edit.new_text.clone(),
                            })
                            .collect();

                        file_edits.push(lsp_bridge::FileEdit {
                            file: file_path.to_string_lossy().to_string(),
                            edits,
                        });
                    }
                }

                let vim_action = VimAction::WorkspaceEdit { edits: file_edits };

                if let Err(e) = self.sender.send(vim_action) {
                    warn!("Failed to send workspace edit to channel: {}", e);
                }
            }
        }

        Ok(())
    }

    fn handle_unknown_notification(&self, method: &str, params: serde_json::Value) {
        debug!(
            "Received unsupported notification: {} with params: {:?}",
            method, params
        );
    }
}

impl NotificationHandler for EnhancedNotificationHandler {
    fn handle_notification(&self, notification: JsonRpcNotification) {
        debug!("Handling LSP notification: {}", notification.method);

        let result = match notification.method.as_str() {
            "textDocument/publishDiagnostics" => {
                self.handle_diagnostics_notification(notification.params)
            }
            "$/progress" => self.handle_progress_notification(notification.params),
            "window/showMessage" => self.handle_show_message_notification(notification.params),
            "window/logMessage" => self.handle_log_message_notification(notification.params),
            "workspace/applyEdit" => self.handle_apply_edit_notification(notification.params),
            "workspace/didChangeWorkspaceFolders" => {
                debug!("Workspace folders changed: {:?}", notification.params);
                Ok(())
            }
            "workspace/didChangeWatchedFiles" => {
                debug!("Watched files changed: {:?}", notification.params);
                Ok(())
            }
            "workspace/configuration" => {
                debug!("Configuration request: {:?}", notification.params);
                Ok(())
            }
            _ => {
                self.handle_unknown_notification(&notification.method, notification.params);
                Ok(())
            }
        };

        if let Err(e) = result {
            warn!(
                "Failed to handle notification {}: {}",
                notification.method, e
            );
        }
    }
}

/// Input for notification handler registration request
#[derive(Debug, Deserialize)]
pub struct NotificationHandlerRequest {
    pub methods: Vec<String>,
}

/// Response indicating which methods were registered
#[derive(Debug, Serialize)]
pub struct NotificationHandlerResponse {
    pub registered_methods: Vec<String>,
    pub unsupported_methods: Vec<String>,
}

/// Handler for managing notification registrations
/// This allows Vim to request registration of specific notification types
pub struct NotificationRegistrationHandler {
    lsp_client: Arc<Mutex<Option<LspClient>>>,
    sender: mpsc::UnboundedSender<VimAction>,
}

impl NotificationRegistrationHandler {
    pub fn new(
        client: Arc<Mutex<Option<LspClient>>>,
        sender: mpsc::UnboundedSender<VimAction>,
    ) -> Self {
        Self {
            lsp_client: client,
            sender,
        }
    }
}

#[async_trait]
impl Handler for NotificationRegistrationHandler {
    type Input = NotificationHandlerRequest;
    type Output = NotificationHandlerResponse;

    async fn handle(
        &self,
        _ctx: &mut dyn vim::VimContext,
        input: Self::Input,
    ) -> Result<Option<Self::Output>> {
        debug!(
            "Registering notification handlers for methods: {:?}",
            input.methods
        );

        let handler = EnhancedNotificationHandler::new(self.sender.clone());
        let mut registered_methods = Vec::new();
        let mut unsupported_methods = Vec::new();

        // Check which methods we support
        for method in input.methods {
            if handler.supports_method(&method) {
                registered_methods.push(method);
            } else {
                unsupported_methods.push(method);
            }
        }

        // Register the enhanced handler with LSP client for supported methods
        if let Some(client) = self.lsp_client.lock().await.as_ref() {
            for method in &registered_methods {
                if let Err(e) = client
                    .register_notification_handler(method, handler.clone())
                    .await
                {
                    warn!(
                        "Failed to register notification handler for {}: {}",
                        method, e
                    );
                }
            }
        }

        Ok(Some(NotificationHandlerResponse {
            registered_methods,
            unsupported_methods,
        }))
    }
}

// Make handler cloneable for registration with multiple methods
impl Clone for EnhancedNotificationHandler {
    fn clone(&self) -> Self {
        Self {
            sender: self.sender.clone(),
            supported_methods: self.supported_methods.clone(),
        }
    }
}
