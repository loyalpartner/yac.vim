use crate::bridge::client::ClientId;
use crate::file::FileManager;
use crate::lsp::jsonrpc::RequestId;
use crate::lsp::protocol::{CompletionContext, CompletionItem, Position, VimCommand};
use crate::lsp::server::LspServerManager;
use crate::utils::{Error, Result};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::RwLock;
use tracing::{debug, error, info, warn};

pub struct CompletionHandler {
    lsp_manager: Arc<RwLock<LspServerManager>>,
    file_manager: Arc<RwLock<FileManager>>,
    pending_completions: HashMap<RequestId, (ClientId, String)>, // request_id -> (client_id, uri)
}

impl CompletionHandler {
    pub fn new(
        lsp_manager: Arc<RwLock<LspServerManager>>,
        file_manager: Arc<RwLock<FileManager>>,
    ) -> Self {
        Self {
            lsp_manager,
            file_manager,
            pending_completions: HashMap::new(),
        }
    }

    pub async fn handle_completion_request(
        &mut self,
        client_id: ClientId,
        request_id: RequestId,
        uri: String,
        position: Position,
        context: Option<CompletionContext>,
    ) -> Result<()> {
        info!(
            "Handling completion request for {} at {}:{}",
            uri, position.line, position.character
        );

        // Validate file is open and get language
        let language = {
            let file_manager = self.file_manager.read().await;
            if !file_manager.is_file_open(&uri) {
                warn!("Completion requested for unopened file: {}", uri);
                return self
                    .send_empty_completion(&client_id, &request_id.to_string(), position)
                    .await;
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
                    return self
                        .send_empty_completion(&client_id, &request_id.to_string(), position)
                        .await;
                }
            }
        };

        // Prepare LSP completion parameters
        let params = self.build_completion_params(&uri, &position, context)?;

        // Store pending request info
        self.pending_completions
            .insert(request_id.clone(), (client_id.clone(), uri.clone()));

        // Send completion request to LSP server
        let response = {
            let mut lsp_manager = self.lsp_manager.write().await;
            lsp_manager
                .send_request(
                    &server_id,
                    "textDocument/completion".to_string(),
                    Some(params),
                )
                .await
        };

        match response {
            Ok(response) => {
                debug!("Received completion response from server {}", server_id);
                self.process_completion_response(request_id, response.result)
                    .await?;
            }
            Err(e) => {
                error!("LSP completion request failed for {}: {}", uri, e);
                self.pending_completions.remove(&request_id);
                self.send_empty_completion(&client_id, &request_id.to_string(), position)
                    .await?;
            }
        }

        Ok(())
    }

    fn build_completion_params(
        &self,
        uri: &str,
        position: &Position,
        context: Option<CompletionContext>,
    ) -> Result<Value> {
        let mut params = json!({
            "textDocument": {
                "uri": uri
            },
            "position": {
                "line": position.line,
                "character": position.character
            }
        });

        if let Some(ctx) = context {
            params["context"] = json!({
                "triggerKind": ctx.trigger_kind,
                "triggerCharacter": ctx.trigger_character
            });
        }

        Ok(params)
    }

    async fn process_completion_response(
        &mut self,
        request_id: RequestId,
        result: crate::lsp::jsonrpc::JsonRpcResponseResult,
    ) -> Result<()> {
        let (client_id, uri) = self
            .pending_completions
            .remove(&request_id)
            .ok_or_else(|| {
                Error::Internal(anyhow::anyhow!(
                    "No pending completion found for request {}",
                    request_id
                ))
            })?;

        match result {
            crate::lsp::jsonrpc::JsonRpcResponseResult::Success { result } => {
                let completion_items = self.parse_lsp_completion_response(result)?;
                self.send_completion_to_client(&client_id, &request_id.to_string(), &uri, completion_items)
                    .await?;
            }
            crate::lsp::jsonrpc::JsonRpcResponseResult::Error { error } => {
                warn!(
                    "LSP server returned error for completion: {} - {}",
                    error.code, error.message
                );
                let position = Position {
                    line: 0,
                    character: 0,
                }; // Default position
                self.send_empty_completion(&client_id, &request_id.to_string(), position)
                    .await?;
            }
        }

        Ok(())
    }

    fn parse_lsp_completion_response(&self, result: Value) -> Result<Vec<CompletionItem>> {
        let items = if result.is_array() {
            // CompletionItem[]
            result.as_array().unwrap().clone()
        } else if result.is_object() && result.get("items").is_some() {
            // CompletionList
            result["items"].as_array().unwrap().clone()
        } else {
            return Ok(vec![]);
        };

        let mut completion_items = Vec::new();

        for (index, item) in items.iter().enumerate() {
            let label = item["label"].as_str().unwrap_or("").to_string();
            if label.is_empty() {
                continue;
            }

            let kind = item["kind"].as_i64().unwrap_or(1) as i32;
            let detail = item["detail"].as_str().map(|s| s.to_string());
            let documentation = item["documentation"]
                .as_str()
                .or_else(|| item["documentation"]["value"].as_str())
                .map(|s| s.to_string());

            let insert_text = item["insertText"]
                .as_str()
                .or_else(|| item["textEdit"]["newText"].as_str())
                .unwrap_or(&label)
                .to_string();

            let sort_text = item["sortText"]
                .as_str()
                .unwrap_or(&format!("{:04}", index))
                .to_string();

            let completion_item = CompletionItem {
                id: format!("completion_item_{}", index),
                label,
                kind,
                detail,
                documentation,
                insert_text: Some(insert_text),
                sort_text: Some(sort_text),
            };

            completion_items.push(completion_item);
        }

        // Sort by sort_text
        completion_items.sort_by(|a, b| {
            let a_sort = a.sort_text.as_ref().unwrap_or(&a.label);
            let b_sort = b.sort_text.as_ref().unwrap_or(&b.label);
            a_sort.cmp(b_sort)
        });

        debug!("Parsed {} completion items", completion_items.len());
        Ok(completion_items)
    }

    async fn send_completion_to_client(
        &self,
        client_id: &str,
        request_id: &str,
        uri: &str,
        items: Vec<CompletionItem>,
    ) -> Result<()> {
        // Get current cursor position (simplified - in real implementation, track cursor position)
        let position = Position {
            line: 0,
            character: 0,
        };

        let command = VimCommand::ShowCompletion {
            request_id: request_id.to_string(),
            position,
            items,
            incomplete: false,
        };

        let item_count = match &command {
            VimCommand::ShowCompletion { items, .. } => items.len(),
            _ => 0,
        };
        info!(
            "Sending {} completion items to client {} for {}",
            item_count, client_id, uri
        );

        // In a real implementation, we'd send this through the client manager
        // For now, just log the completion
        debug!("Completion command prepared: {:?}", command);

        Ok(())
    }

    async fn send_empty_completion(
        &self,
        client_id: &str,
        request_id: &str,
        position: Position,
    ) -> Result<()> {
        let command = VimCommand::ShowCompletion {
            request_id: request_id.to_string(),
            position,
            items: vec![],
            incomplete: false,
        };

        debug!("Sending empty completion to client {}", client_id);
        // In a real implementation, send through client manager
        Ok(())
    }

    pub fn cleanup_expired_requests(&mut self) {
        // In a real implementation, we'd track request timestamps and clean up old ones
        // For now, just clear all pending requests periodically
        if self.pending_completions.len() > 100 {
            warn!("Too many pending completions, clearing old requests");
            self.pending_completions.clear();
        }
    }
}

// Completion item kinds from LSP specification
#[allow(dead_code)]
pub mod completion_item_kind {
    pub const TEXT: i32 = 1;
    pub const METHOD: i32 = 2;
    pub const FUNCTION: i32 = 3;
    pub const CONSTRUCTOR: i32 = 4;
    pub const FIELD: i32 = 5;
    pub const VARIABLE: i32 = 6;
    pub const CLASS: i32 = 7;
    pub const INTERFACE: i32 = 8;
    pub const MODULE: i32 = 9;
    pub const PROPERTY: i32 = 10;
    pub const UNIT: i32 = 11;
    pub const VALUE: i32 = 12;
    pub const ENUM: i32 = 13;
    pub const KEYWORD: i32 = 14;
    pub const SNIPPET: i32 = 15;
    pub const COLOR: i32 = 16;
    pub const FILE: i32 = 17;
    pub const REFERENCE: i32 = 18;
    pub const FOLDER: i32 = 19;
    pub const ENUM_MEMBER: i32 = 20;
    pub const CONSTANT: i32 = 21;
    pub const STRUCT: i32 = 22;
    pub const EVENT: i32 = 23;
    pub const OPERATOR: i32 = 24;
    pub const TYPE_PARAMETER: i32 = 25;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_completion_params_building() {
        let handler = CompletionHandler::new(
            Arc::new(RwLock::new(LspServerManager::new(HashMap::new()))),
            Arc::new(RwLock::new(FileManager::new())),
        );

        let params = handler
            .build_completion_params(
                "file:///test.rs",
                &Position {
                    line: 10,
                    character: 5,
                },
                Some(CompletionContext {
                    trigger_kind: 1,
                    trigger_character: Some(".".to_string()),
                }),
            )
            .unwrap();

        assert_eq!(params["textDocument"]["uri"], "file:///test.rs");
        assert_eq!(params["position"]["line"], 10);
        assert_eq!(params["position"]["character"], 5);
        assert_eq!(params["context"]["triggerKind"], 1);
        assert_eq!(params["context"]["triggerCharacter"], ".");
    }

    #[test]
    fn test_empty_completion_parsing() {
        let handler = CompletionHandler::new(
            Arc::new(RwLock::new(LspServerManager::new(HashMap::new()))),
            Arc::new(RwLock::new(FileManager::new())),
        );

        let empty_array = json!([]);
        let items = handler.parse_lsp_completion_response(empty_array).unwrap();
        assert!(items.is_empty());

        let empty_list = json!({"items": []});
        let items = handler.parse_lsp_completion_response(empty_list).unwrap();
        assert!(items.is_empty());
    }
}
