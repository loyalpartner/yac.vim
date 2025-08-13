use crate::bridge::client::ClientId;
use crate::file::FileManager;
use crate::lsp::jsonrpc::RequestId;
use crate::lsp::protocol::{HoverContent, Position, Range, VimCommand};
use crate::lsp::server::LspServerManager;
use crate::utils::{Error, Result};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::RwLock;
use tracing::{debug, error, info, warn};

pub struct HoverHandler {
    lsp_manager: Arc<RwLock<LspServerManager>>,
    file_manager: Arc<RwLock<FileManager>>,
    pending_hovers: HashMap<RequestId, (ClientId, String)>, // request_id -> (client_id, uri)
}

impl HoverHandler {
    pub fn new(
        lsp_manager: Arc<RwLock<LspServerManager>>,
        file_manager: Arc<RwLock<FileManager>>,
    ) -> Self {
        Self {
            lsp_manager,
            file_manager,
            pending_hovers: HashMap::new(),
        }
    }

    pub async fn handle_hover_request(
        &mut self,
        client_id: ClientId,
        request_id: RequestId,
        uri: String,
        position: Position,
    ) -> Result<()> {
        info!(
            "Handling hover request for {} at {}:{}",
            uri, position.line, position.character
        );

        // Validate file is open and get language
        let language = {
            let file_manager = self.file_manager.read().await;
            if !file_manager.is_file_open(&uri) {
                warn!("Hover requested for unopened file: {}", uri);
                return Ok(()); // Just ignore hover for unopened files
            }

            file_manager
                .get_file_language(&uri)
                .ok_or_else(|| Error::file_not_found(&uri))?
                .to_string()
        };

        // Find or start appropriate LSP server
        let server_id = {
            let mut lsp_manager = self.lsp_manager.write().await;
            match lsp_manager.find_server_for_filetype(&language).await {
                Ok(id) => id,
                Err(e) => {
                    warn!("No LSP server available for {}: {}", language, e);
                    return Ok(());
                }
            }
        };

        // Prepare LSP hover parameters
        let params = self.build_hover_params(&uri, &position)?;

        // Store pending request info
        self.pending_hovers
            .insert(request_id.clone(), (client_id.clone(), uri.clone()));

        // Send hover request to LSP server
        let response = {
            let mut lsp_manager = self.lsp_manager.write().await;
            lsp_manager
                .send_request(&server_id, "textDocument/hover".to_string(), Some(params))
                .await
        };

        match response {
            Ok(response) => {
                debug!("Received hover response from server {}", server_id);
                self.process_hover_response(request_id, response.result)
                    .await?;
            }
            Err(e) => {
                error!("LSP hover request failed for {}: {}", uri, e);
                self.pending_hovers.remove(&request_id);
            }
        }

        Ok(())
    }

    fn build_hover_params(&self, uri: &str, position: &Position) -> Result<Value> {
        Ok(json!({
            "textDocument": {
                "uri": uri
            },
            "position": {
                "line": position.line,
                "character": position.character
            }
        }))
    }

    async fn process_hover_response(
        &mut self,
        request_id: RequestId,
        result: crate::lsp::jsonrpc::JsonRpcResponseResult,
    ) -> Result<()> {
        let (client_id, uri) = self.pending_hovers.remove(&request_id).ok_or_else(|| {
            Error::Internal(anyhow::anyhow!(
                "No pending hover found for request {}",
                request_id
            ))
        })?;

        match result {
            crate::lsp::jsonrpc::JsonRpcResponseResult::Success { result } => {
                if let Some(hover_info) = self.parse_lsp_hover_response(result)? {
                    self.send_hover_to_client(&client_id, hover_info).await?;
                }
                // If no hover info, just don't show anything
            }
            crate::lsp::jsonrpc::JsonRpcResponseResult::Error { error } => {
                warn!(
                    "LSP server returned error for hover: {} - {}",
                    error.code, error.message
                );
                // Don't show anything for hover errors
            }
        }

        Ok(())
    }

    fn parse_lsp_hover_response(
        &self,
        result: Value,
    ) -> Result<Option<(HoverContent, Position, Option<Range>)>> {
        if result.is_null() {
            return Ok(None);
        }

        // Extract contents
        let contents = result.get("contents");
        if contents.is_none() {
            return Ok(None);
        }

        let hover_content = self.parse_hover_contents(contents.unwrap())?;
        if hover_content.value.is_empty() {
            return Ok(None);
        }

        // Extract range if present
        let range = result.get("range").and_then(|r| self.parse_range(r).ok());

        // For simplicity, use a default position (in real implementation, use the request position)
        let position = Position {
            line: 0,
            character: 0,
        };

        Ok(Some((hover_content, position, range)))
    }

    fn parse_hover_contents(&self, contents: &Value) -> Result<HoverContent> {
        let (kind, value) = if contents.is_string() {
            // Simple string content
            (
                "plaintext".to_string(),
                contents.as_str().unwrap().to_string(),
            )
        } else if contents.is_array() {
            // Array of MarkupContent or strings
            let parts: Vec<String> = contents
                .as_array()
                .unwrap()
                .iter()
                .map(|item| {
                    if item.is_string() {
                        item.as_str().unwrap().to_string()
                    } else if let Some(value) = item.get("value") {
                        value.as_str().unwrap_or("").to_string()
                    } else {
                        "".to_string()
                    }
                })
                .filter(|s| !s.is_empty())
                .collect();

            ("plaintext".to_string(), parts.join("\n\n"))
        } else if let Some(kind) = contents.get("kind") {
            // MarkupContent
            let kind_str = kind.as_str().unwrap_or("plaintext").to_string();
            let value_str = contents
                .get("value")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            (kind_str, value_str)
        } else {
            // Fallback
            ("plaintext".to_string(), "".to_string())
        };

        Ok(HoverContent { kind, value })
    }

    fn parse_range(&self, range: &Value) -> Result<Range> {
        let start = range
            .get("start")
            .ok_or_else(|| Error::protocol("Missing start in range".to_string()))?;
        let end = range
            .get("end")
            .ok_or_else(|| Error::protocol("Missing end in range".to_string()))?;

        let start_pos = Position {
            line: start.get("line").and_then(|l| l.as_i64()).unwrap_or(0) as i32,
            character: start.get("character").and_then(|c| c.as_i64()).unwrap_or(0) as i32,
        };

        let end_pos = Position {
            line: end.get("line").and_then(|l| l.as_i64()).unwrap_or(0) as i32,
            character: end.get("character").and_then(|c| c.as_i64()).unwrap_or(0) as i32,
        };

        Ok(Range {
            start: start_pos,
            end: end_pos,
        })
    }

    async fn send_hover_to_client(
        &self,
        client_id: &str,
        (content, position, range): (HoverContent, Position, Option<Range>),
    ) -> Result<()> {
        let command = VimCommand::ShowHover {
            position,
            content,
            range,
        };

        info!("Sending hover info to client {}", client_id);
        debug!("Hover command: {:?}", command);

        // In a real implementation, we'd send this through the client manager
        Ok(())
    }

    pub fn cleanup_expired_requests(&mut self) {
        // Clean up old pending hover requests
        if self.pending_hovers.len() > 50 {
            warn!("Too many pending hovers, clearing old requests");
            self.pending_hovers.clear();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_hover_params_building() {
        let handler = HoverHandler::new(
            Arc::new(RwLock::new(LspServerManager::new(HashMap::new()))),
            Arc::new(RwLock::new(FileManager::new())),
        );

        let params = handler
            .build_hover_params(
                "file:///test.rs",
                &Position {
                    line: 10,
                    character: 5,
                },
            )
            .unwrap();

        assert_eq!(params["textDocument"]["uri"], "file:///test.rs");
        assert_eq!(params["position"]["line"], 10);
        assert_eq!(params["position"]["character"], 5);
    }

    #[test]
    fn test_hover_content_parsing() {
        let handler = HoverHandler::new(
            Arc::new(RwLock::new(LspServerManager::new(HashMap::new()))),
            Arc::new(RwLock::new(FileManager::new())),
        );

        // Test string content
        let string_content = json!("Simple hover text");
        let content = handler.parse_hover_contents(&string_content).unwrap();
        assert_eq!(content.kind, "plaintext");
        assert_eq!(content.value, "Simple hover text");

        // Test MarkupContent
        let markup_content = json!({
            "kind": "markdown",
            "value": "**Bold text**"
        });
        let content = handler.parse_hover_contents(&markup_content).unwrap();
        assert_eq!(content.kind, "markdown");
        assert_eq!(content.value, "**Bold text**");
    }

    #[test]
    fn test_range_parsing() {
        let handler = HoverHandler::new(
            Arc::new(RwLock::new(LspServerManager::new(HashMap::new()))),
            Arc::new(RwLock::new(FileManager::new())),
        );

        let range_json = json!({
            "start": {"line": 5, "character": 10},
            "end": {"line": 5, "character": 15}
        });

        let range = handler.parse_range(&range_json).unwrap();
        assert_eq!(range.start.line, 5);
        assert_eq!(range.start.character, 10);
        assert_eq!(range.end.line, 5);
        assert_eq!(range.end.character, 15);
    }
}
