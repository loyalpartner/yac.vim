use crate::bridge::client::ClientId;
use crate::file::FileManager;
use crate::lsp::jsonrpc::RequestId;
use crate::lsp::protocol::{Position, Range, VimCommand};
use crate::lsp::server::LspServerManager;
use crate::utils::{Error, Result};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::RwLock;
use tracing::{debug, error, info, warn};

#[derive(Debug, Clone)]
pub struct Location {
    pub uri: String,
    pub range: Range,
    pub selection_range: Option<Range>,
}

pub struct DefinitionHandler {
    lsp_manager: Arc<RwLock<LspServerManager>>,
    file_manager: Arc<RwLock<FileManager>>,
    pending_definitions: HashMap<RequestId, (ClientId, String)>, // request_id -> (client_id, uri)
}

impl DefinitionHandler {
    pub fn new(
        lsp_manager: Arc<RwLock<LspServerManager>>,
        file_manager: Arc<RwLock<FileManager>>,
    ) -> Self {
        Self {
            lsp_manager,
            file_manager,
            pending_definitions: HashMap::new(),
        }
    }

    pub async fn handle_definition_request(
        &mut self,
        client_id: ClientId,
        request_id: RequestId,
        uri: String,
        position: Position,
    ) -> Result<()> {
        info!(
            "Handling definition request for {} at {}:{}",
            uri, position.line, position.character
        );

        // Validate file is open and get language
        let language = {
            let file_manager = self.file_manager.read().await;
            if !file_manager.is_file_open(&uri) {
                warn!("Definition requested for unopened file: {}", uri);
                return Ok(()); // Just ignore definition for unopened files
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

        // Prepare LSP definition parameters
        let params = self.build_definition_params(&uri, &position)?;

        // Store pending request info
        self.pending_definitions
            .insert(request_id.clone(), (client_id.clone(), uri.clone()));

        // Send definition request to LSP server
        let response = {
            let mut lsp_manager = self.lsp_manager.write().await;
            lsp_manager
                .send_request(
                    &server_id,
                    "textDocument/definition".to_string(),
                    Some(params),
                )
                .await
        };

        match response {
            Ok(response) => {
                debug!("Received definition response from server {}", server_id);
                self.process_definition_response(request_id, response.result)
                    .await?;
            }
            Err(e) => {
                error!("LSP definition request failed for {}: {}", uri, e);
                self.pending_definitions.remove(&request_id);
            }
        }

        Ok(())
    }

    fn build_definition_params(&self, uri: &str, position: &Position) -> Result<Value> {
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

    async fn process_definition_response(
        &mut self,
        request_id: RequestId,
        result: crate::lsp::jsonrpc::JsonRpcResponseResult,
    ) -> Result<()> {
        let (client_id, uri) = self
            .pending_definitions
            .remove(&request_id)
            .ok_or_else(|| {
                Error::Internal(anyhow::anyhow!(
                    "No pending definition found for request {}",
                    request_id
                ))
            })?;

        match result {
            crate::lsp::jsonrpc::JsonRpcResponseResult::Success { result } => {
                let locations = self.parse_lsp_definition_response(result)?;
                if !locations.is_empty() {
                    self.send_definition_to_client(&client_id, locations)
                        .await?;
                } else {
                    debug!("No definition found for request from client {}", client_id);
                }
            }
            crate::lsp::jsonrpc::JsonRpcResponseResult::Error { error } => {
                warn!(
                    "LSP server returned error for definition: {} - {}",
                    error.code, error.message
                );
                // Don't show anything for definition errors
            }
        }

        Ok(())
    }

    fn parse_lsp_definition_response(&self, result: Value) -> Result<Vec<Location>> {
        if result.is_null() {
            return Ok(vec![]);
        }

        let locations = if result.is_array() {
            // Location[]
            result.as_array().unwrap().clone()
        } else if result.is_object() {
            // Single Location
            vec![result]
        } else {
            return Ok(vec![]);
        };

        let mut parsed_locations = Vec::new();

        for location in locations {
            if let Some(parsed) = self.parse_location(&location)? {
                parsed_locations.push(parsed);
            }
        }

        debug!("Parsed {} definition locations", parsed_locations.len());
        Ok(parsed_locations)
    }

    fn parse_location(&self, location: &Value) -> Result<Option<Location>> {
        let uri = location
            .get("uri")
            .and_then(|u| u.as_str())
            .ok_or_else(|| Error::protocol("Missing uri in location".to_string()))?;

        let range_json = location
            .get("range")
            .ok_or_else(|| Error::protocol("Missing range in location".to_string()))?;

        let range = self.parse_range(range_json)?;

        // Some servers provide targetSelectionRange
        let selection_range = location
            .get("targetSelectionRange")
            .or_else(|| location.get("selectionRange"))
            .and_then(|r| self.parse_range(r).ok());

        Ok(Some(Location {
            uri: uri.to_string(),
            range,
            selection_range,
        }))
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

    async fn send_definition_to_client(
        &self,
        client_id: &str,
        locations: Vec<Location>,
    ) -> Result<()> {
        if locations.len() == 1 {
            // Single definition - jump directly
            let location = &locations[0];
            let command = VimCommand::JumpToLocation {
                uri: location.uri.clone(),
                range: location.range.clone(),
                selection_range: location.selection_range.clone(),
            };

            info!(
                "Sending jump to definition command to client {} for {}",
                client_id, location.uri
            );
            debug!("Jump command: {:?}", command);
        } else if locations.len() > 1 {
            // Multiple definitions - show a list (for now, just jump to first)
            let location = &locations[0];
            let command = VimCommand::JumpToLocation {
                uri: location.uri.clone(),
                range: location.range.clone(),
                selection_range: location.selection_range.clone(),
            };

            info!(
                "Multiple definitions found, jumping to first one for client {}",
                client_id
            );
            debug!("Jump command: {:?}", command);
        }

        // In a real implementation, we'd send this through the client manager
        Ok(())
    }

    pub async fn handle_declaration_request(
        &mut self,
        client_id: ClientId,
        request_id: RequestId,
        uri: String,
        position: Position,
    ) -> Result<()> {
        // Declaration is similar to definition but looks for declarations instead
        // For simplicity, we'll reuse the same logic but with "textDocument/declaration"
        info!(
            "Handling declaration request for {} at {}:{}",
            uri, position.line, position.character
        );

        // Similar implementation to definition but using "textDocument/declaration"
        // For brevity, just delegate to definition for now
        self.handle_definition_request(client_id, request_id, uri, position)
            .await
    }

    pub async fn handle_type_definition_request(
        &mut self,
        client_id: ClientId,
        request_id: RequestId,
        uri: String,
        position: Position,
    ) -> Result<()> {
        // Type definition shows the definition of the type of a symbol
        info!(
            "Handling type definition request for {} at {}:{}",
            uri, position.line, position.character
        );

        // Similar implementation but using "textDocument/typeDefinition"
        // For brevity, just delegate to definition for now
        self.handle_definition_request(client_id, request_id, uri, position)
            .await
    }

    pub async fn handle_implementation_request(
        &mut self,
        client_id: ClientId,
        request_id: RequestId,
        uri: String,
        position: Position,
    ) -> Result<()> {
        // Implementation shows implementations of an interface/abstract method
        info!(
            "Handling implementation request for {} at {}:{}",
            uri, position.line, position.character
        );

        // Similar implementation but using "textDocument/implementation"
        // For brevity, just delegate to definition for now
        self.handle_definition_request(client_id, request_id, uri, position)
            .await
    }

    pub fn cleanup_expired_requests(&mut self) {
        // Clean up old pending definition requests
        if self.pending_definitions.len() > 50 {
            warn!("Too many pending definitions, clearing old requests");
            self.pending_definitions.clear();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_definition_params_building() {
        let handler = DefinitionHandler::new(
            Arc::new(RwLock::new(LspServerManager::new(HashMap::new()))),
            Arc::new(RwLock::new(FileManager::new())),
        );

        let params = handler
            .build_definition_params(
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
    fn test_location_parsing() {
        let handler = DefinitionHandler::new(
            Arc::new(RwLock::new(LspServerManager::new(HashMap::new()))),
            Arc::new(RwLock::new(FileManager::new())),
        );

        let location_json = json!({
            "uri": "file:///src/lib.rs",
            "range": {
                "start": {"line": 15, "character": 8},
                "end": {"line": 15, "character": 20}
            }
        });

        let location = handler.parse_location(&location_json).unwrap().unwrap();
        assert_eq!(location.uri, "file:///src/lib.rs");
        assert_eq!(location.range.start.line, 15);
        assert_eq!(location.range.start.character, 8);
        assert_eq!(location.range.end.line, 15);
        assert_eq!(location.range.end.character, 20);
    }

    #[test]
    fn test_empty_definition_response() {
        let handler = DefinitionHandler::new(
            Arc::new(RwLock::new(LspServerManager::new(HashMap::new()))),
            Arc::new(RwLock::new(FileManager::new())),
        );

        let null_result = json!(null);
        let locations = handler.parse_lsp_definition_response(null_result).unwrap();
        assert!(locations.is_empty());

        let empty_array = json!([]);
        let locations = handler.parse_lsp_definition_response(empty_array).unwrap();
        assert!(locations.is_empty());
    }
}
