use crate::lsp::jsonrpc::JsonRpcMessage;
use crate::utils::{Error, Result};
use std::collections::HashMap;
use tracing::{debug, trace};

/// LSP message parser for Content-Length framed messages
/// Handles LSP protocol messages with Content-Length headers (not HTTP protocol)
pub struct LspMessageParser {
    buffer: String,
}

impl Default for LspMessageParser {
    fn default() -> Self {
        Self::new()
    }
}

impl LspMessageParser {
    pub fn new() -> Self {
        Self {
            buffer: String::new(),
        }
    }

    /// Parse incoming data and extract complete LSP messages
    pub fn parse_messages(&mut self, data: &str) -> Result<Vec<JsonRpcMessage>> {
        trace!("LSP Message Parser received {} bytes", data.len());
        self.buffer.push_str(data);
        let mut messages = Vec::new();

        loop {
            if let Some(message) = self.try_extract_message()? {
                debug!("Successfully parsed LSP message");
                messages.push(message);
            } else {
                break;
            }
        }

        if !messages.is_empty() {
            debug!("Extracted {} LSP messages from buffer", messages.len());
        }
        Ok(messages)
    }

    fn try_extract_message(&mut self) -> Result<Option<JsonRpcMessage>> {
        // Find the double newline that separates headers from body
        if let Some(header_end) = self.buffer.find("\r\n\r\n") {
            let header_section = &self.buffer[..header_end];
            let body_start = header_end + 4;

            // Parse headers
            let headers = self.parse_headers(header_section)?;

            // Get Content-Length
            let content_length = headers
                .get("Content-Length")
                .ok_or_else(|| Error::protocol("Missing Content-Length header".to_string()))?
                .parse::<usize>()
                .map_err(|_| Error::protocol("Invalid Content-Length header".to_string()))?;

            // Check if we have the complete message
            if self.buffer.len() >= body_start + content_length {
                let json_body = &self.buffer[body_start..body_start + content_length];

                // Parse JSON-RPC message
                let message = JsonRpcMessage::parse(json_body)?;

                // Remove processed message from buffer
                self.buffer.drain(..body_start + content_length);

                return Ok(Some(message));
            }
        }

        Ok(None)
    }

    fn parse_headers(&self, header_section: &str) -> Result<HashMap<String, String>> {
        let mut headers = HashMap::new();

        for line in header_section.lines() {
            let line = line.trim();
            if line.is_empty() {
                continue;
            }

            if let Some((key, value)) = line.split_once(':') {
                headers.insert(key.trim().to_string(), value.trim().to_string());
            }
        }

        Ok(headers)
    }
}

/// Format a JSON-RPC message for LSP transmission with Content-Length header
pub fn format_lsp_message(message: &str) -> String {
    format!(
        "Content-Length: {}\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n{}",
        message.len(),
        message
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn test_parse_simple_message() {
        let mut parser = LspMessageParser::new();

        let test_message = r#"{"jsonrpc":"2.0","method":"test","params":{}}"#;
        let lsp_message = format!(
            "Content-Length: {}\r\n\r\n{}",
            test_message.len(),
            test_message
        );

        let messages = parser.parse_messages(&lsp_message).unwrap();
        assert_eq!(messages.len(), 1);
    }

    #[test]
    fn test_format_message() {
        let json_msg = r#"{"jsonrpc":"2.0","method":"test"}"#;
        let formatted = format_lsp_message(json_msg);

        assert!(formatted.contains("Content-Length: 33"));
        assert!(formatted.contains("Content-Type: application/vscode-jsonrpc"));
        assert!(formatted.ends_with(json_msg));
    }
}
