use crate::lsp::jsonrpc::{JsonRpcRequest, JsonRpcResponse};
use serde::{Deserialize, Serialize};
use serde_json::Value;

// Vim-specific protocol messages
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "method", content = "params")]
pub enum VimEvent {
    #[serde(rename = "client_connect")]
    ClientConnect {
        client_info: ClientInfo,
        capabilities: ClientCapabilities,
    },
    #[serde(rename = "client_disconnect")]
    ClientDisconnect { reason: String },
    #[serde(rename = "file_opened")]
    FileOpened {
        uri: String,
        language_id: String,
        version: i32,
        content: String,
    },
    #[serde(rename = "file_changed")]
    FileChanged {
        uri: String,
        version: i32,
        changes: Vec<TextDocumentContentChange>,
    },
    #[serde(rename = "file_saved")]
    FileSaved { uri: String },
    #[serde(rename = "file_closed")]
    FileClosed { uri: String },
    #[serde(rename = "cursor_moved")]
    CursorMoved { uri: String, position: Position },
    #[serde(rename = "completion_selected")]
    CompletionSelected { item_id: String, action: String },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "method", content = "params")]
pub enum VimRequest {
    #[serde(rename = "completion")]
    Completion {
        uri: String,
        position: Position,
        context: Option<CompletionContext>,
    },
    #[serde(rename = "hover")]
    Hover { uri: String, position: Position },
    #[serde(rename = "goto_definition")]
    GotoDefinition { uri: String, position: Position },
    #[serde(rename = "references")]
    References {
        uri: String,
        position: Position,
        context: ReferenceContext,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "method", content = "params")]
pub enum VimCommand {
    #[serde(rename = "show_completion")]
    ShowCompletion {
        request_id: String,
        position: Position,
        items: Vec<CompletionItem>,
        incomplete: bool,
    },
    #[serde(rename = "hide_completion")]
    HideCompletion,
    #[serde(rename = "show_hover")]
    ShowHover {
        position: Position,
        content: HoverContent,
        range: Option<Range>,
    },
    #[serde(rename = "show_diagnostics")]
    ShowDiagnostics {
        uri: String,
        diagnostics: Vec<Diagnostic>,
    },
    #[serde(rename = "jump_to_location")]
    JumpToLocation {
        uri: String,
        range: Range,
        selection_range: Option<Range>,
    },
    #[serde(rename = "set_status")]
    SetStatus {
        component: String,
        text: String,
        highlight: Option<String>,
    },
    #[serde(rename = "show_message")]
    ShowMessage {
        message_type: MessageType,
        message: String,
    },
}

// LSP protocol wrapper types
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LspRequest {
    pub server_id: String,
    pub request: JsonRpcRequest,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LspResponse {
    pub server_id: String,
    pub response: JsonRpcResponse,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LspNotification {
    pub server_id: String,
    pub method: String,
    pub params: Option<Value>,
}

// Common LSP types (simplified subset of lsp-types)
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Position {
    pub line: i32,
    pub character: i32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Range {
    pub start: Position,
    pub end: Position,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TextDocumentContentChange {
    pub range: Option<Range>,
    pub text: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ClientInfo {
    pub name: String,
    pub version: String,
    pub pid: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ClientCapabilities {
    pub completion: bool,
    pub hover: bool,
    pub goto_definition: bool,
    pub references: bool,
    pub diagnostics: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CompletionContext {
    pub trigger_kind: i32,
    pub trigger_character: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CompletionItem {
    pub id: String,
    pub label: String,
    pub kind: i32,
    pub detail: Option<String>,
    pub documentation: Option<String>,
    pub insert_text: Option<String>,
    pub sort_text: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HoverContent {
    pub kind: String,
    pub value: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Diagnostic {
    pub range: Range,
    pub severity: i32,
    pub code: Option<String>,
    pub source: Option<String>,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReferenceContext {
    pub include_declaration: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum MessageType {
    Error,
    Warning,
    Info,
    Log,
}

impl Default for ClientCapabilities {
    fn default() -> Self {
        Self {
            completion: true,
            hover: true,
            goto_definition: true,
            references: true,
            diagnostics: true,
        }
    }
}
