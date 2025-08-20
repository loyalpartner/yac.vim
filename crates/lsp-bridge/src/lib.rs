use lsp_client::{LspClient, Result as LspResult};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

// Legacy structs removed - now using VimCommand only

// 新的简化命令格式
#[derive(Debug, Serialize, Deserialize)]
pub struct VimCommand {
    pub command: String, // goto_definition, hover, completion, rename
    pub file: String,    // 绝对文件路径
    pub line: u32,       // 0-based 行号
    pub column: u32,     // 0-based 列号
    #[serde(skip_serializing_if = "Option::is_none")]
    pub new_name: Option<String>, // 用于 rename 命令的新名称
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text: Option<String>, // 用于 textDocument lifecycle 的文档内容
    #[serde(skip_serializing_if = "Option::is_none")]
    pub save_reason: Option<u32>, // 用于 willSave 的保存原因 (1=Manual, 2=AfterDelay, 3=FocusOut)
}

// Using VimCommand directly - no legacy support

// Legacy response format removed - using VimAction only

// 新的动作格式
#[derive(Debug, Serialize, Deserialize)]
#[serde(tag = "action")]
pub enum VimAction {
    #[serde(rename = "init")]
    Init { log_file: String },
    #[serde(rename = "jump")]
    Jump {
        file: String,
        line: u32,   // 0-based
        column: u32, // 0-based
    },
    #[serde(rename = "show_hover")]
    ShowHover { content: String },
    #[serde(rename = "completions")]
    Completions { items: Vec<CompletionItem> },
    #[serde(rename = "references")]
    References { locations: Vec<ReferenceLocation> },
    #[serde(rename = "inlay_hints")]
    InlayHints { hints: Vec<InlayHint> },
    #[serde(rename = "workspace_edit")]
    WorkspaceEdit { edits: Vec<FileEdit> },
    #[serde(rename = "call_hierarchy")]
    CallHierarchy { items: Vec<CallHierarchyItem> },
    #[serde(rename = "document_symbols")]
    DocumentSymbols { symbols: Vec<DocumentSymbol> },
    #[serde(rename = "none")]
    None,
    #[serde(rename = "error")]
    Error { message: String },
}

#[derive(Debug, Serialize, Deserialize)]
pub struct CompletionItem {
    pub label: String,
    pub kind: String,
    pub detail: Option<String>,        // 类型/符号详细信息
    pub documentation: Option<String>, // 完整文档内容
}

#[derive(Debug, Serialize, Deserialize)]
pub struct ReferenceLocation {
    pub file: String,
    pub line: u32,   // 0-based
    pub column: u32, // 0-based
}

#[derive(Debug, Serialize, Deserialize)]
pub struct InlayHint {
    pub line: u32,               // 0-based line number
    pub column: u32,             // 0-based column position
    pub label: String,           // The hint text to display
    pub kind: String,            // "type" or "parameter"
    pub tooltip: Option<String>, // Optional tooltip text
}

#[derive(Debug, Serialize, Deserialize)]
pub struct FileEdit {
    pub file: String,         // File path
    pub edits: Vec<TextEdit>, // Text edits for this file
}

#[derive(Debug, Serialize, Deserialize)]
pub struct TextEdit {
    pub start_line: u32,   // 0-based start line
    pub start_column: u32, // 0-based start column
    pub end_line: u32,     // 0-based end line
    pub end_column: u32,   // 0-based end column
    pub new_text: String,  // New text to insert
}

#[derive(Debug, Serialize, Deserialize)]
pub struct CallHierarchyItem {
    pub name: String,           // Function/method name
    pub kind: String,           // Symbol kind (function, method, etc.)
    pub detail: Option<String>, // Additional details
    pub file: String,           // File path
    pub line: u32,              // 0-based line number
    pub column: u32,            // 0-based column number
    pub selection_line: u32,    // 0-based selection start line
    pub selection_column: u32,  // 0-based selection start column
}

#[derive(Debug, Serialize, Deserialize)]
pub struct DocumentSymbol {
    pub name: String,                  // Symbol name
    pub kind: String,                  // Symbol kind (function, struct, etc.)
    pub detail: Option<String>,        // Additional details
    pub file: String,                  // File path
    pub line: u32,                     // 0-based line number
    pub column: u32,                   // 0-based column number
    pub selection_line: u32,           // 0-based selection start line
    pub selection_column: u32,         // 0-based selection start column
    pub children: Vec<DocumentSymbol>, // Nested symbols
}

// Using VimAction directly - no legacy support

pub struct LspBridge {
    // 暂时只支持单个客户端，后续可扩展
    client: Option<LspClient>,
}

impl Default for LspBridge {
    fn default() -> Self {
        Self::new()
    }
}

impl LspBridge {
    pub fn new() -> Self {
        Self { client: None }
    }

    /// 处理高层命令
    pub async fn handle_command(&mut self, command: VimCommand) -> VimAction {
        // 提取语言和文件路径
        let language = Self::detect_language(&command.file);
        let file_path = command.file.clone();

        // 如果没有客户端，先创建一个
        if self.client.is_none() {
            match self.create_client(&language, &file_path).await {
                Ok(client) => self.client = Some(client),
                Err(e) => {
                    return VimAction::Error {
                        message: format!("Failed to create LSP client: {}", e),
                    };
                }
            }
        }

        // 处理Vim命令
        self.handle_vim_command(command).await
    }

    /// 处理高层Vim命令
    async fn handle_vim_command(&self, command: VimCommand) -> VimAction {
        if let Some(client) = &self.client {
            match command.command.as_str() {
                "file_open" => self.handle_file_open(client, &command).await,
                "goto_definition" => self.handle_goto_definition(client, &command).await,
                "goto_declaration" => self.handle_goto_declaration(client, &command).await,
                "goto_type_definition" => self.handle_goto_type_definition(client, &command).await,
                "goto_implementation" => self.handle_goto_implementation(client, &command).await,
                "hover" => self.handle_hover(client, &command).await,
                "completion" => self.handle_completion(client, &command).await,
                "references" => self.handle_references(client, &command).await,
                "inlay_hints" => self.handle_inlay_hints(client, &command).await,
                "rename" => self.handle_rename(client, &command).await,
                "call_hierarchy_incoming" => {
                    self.handle_call_hierarchy_incoming(client, &command).await
                }
                "call_hierarchy_outgoing" => {
                    self.handle_call_hierarchy_outgoing(client, &command).await
                }
                "document_symbols" => self.handle_document_symbols(client, &command).await,
                "did_save" => self.handle_did_save(client, &command).await,
                "did_change" => self.handle_did_change(client, &command).await,
                "will_save" => self.handle_will_save(client, &command).await,
                "will_save_wait_until" => self.handle_will_save_wait_until(client, &command).await,
                "did_close" => self.handle_did_close(client, &command).await,
                _ => VimAction::Error {
                    message: format!("Unknown command: {}", command.command),
                },
            }
        } else {
            VimAction::Error {
                message: "No LSP client available".to_string(),
            }
        }
    }

    /// 处理跳转到声明
    async fn handle_goto_declaration(&self, client: &LspClient, command: &VimCommand) -> VimAction {
        use lsp_types::{
            GotoDefinitionParams, Position, TextDocumentIdentifier, TextDocumentPositionParams,
        };

        // 确保文件已打开
        if let Err(e) = self.ensure_file_open(client, &command.file).await {
            return VimAction::Error {
                message: format!("Failed to open file: {}", e),
            };
        }

        let uri = match lsp_types::Url::from_file_path(&command.file) {
            Ok(uri) => uri,
            Err(_) => {
                return VimAction::Error {
                    message: format!("Invalid file path: {}", command.file),
                }
            }
        };

        let params = GotoDefinitionParams {
            text_document_position_params: TextDocumentPositionParams {
                text_document: TextDocumentIdentifier { uri },
                position: Position {
                    line: command.line,
                    character: command.column,
                },
            },
            work_done_progress_params: Default::default(),
            partial_result_params: Default::default(),
        };

        use lsp_types::request::GotoDeclaration;
        match client.request::<GotoDeclaration>(params).await {
            Ok(Some(response)) => {
                use tracing::debug;
                debug!("Got LSP declaration response: {:?}", response);

                // 处理 GotoDefinitionResponse (可能是 Location 或 LocationLink)
                match response {
                    lsp_types::GotoDefinitionResponse::Scalar(location) => {
                        VimAction::from(location)
                    }
                    lsp_types::GotoDefinitionResponse::Array(locations) => {
                        if let Some(first) = locations.first() {
                            VimAction::from(first)
                        } else {
                            VimAction::Error {
                                message: "No declaration found".to_string(),
                            }
                        }
                    }
                    lsp_types::GotoDefinitionResponse::Link(links) => {
                        if let Some(first_link) = links.first() {
                            VimAction::from(first_link)
                        } else {
                            VimAction::Error {
                                message: "No declaration found".to_string(),
                            }
                        }
                    }
                }
            }
            Ok(None) => VimAction::Error {
                message: "No declaration found".to_string(),
            },
            Err(e) => VimAction::Error {
                message: e.to_string(),
            },
        }
    }

    /// 处理跳转到定义
    async fn handle_goto_definition(&self, client: &LspClient, command: &VimCommand) -> VimAction {
        use lsp_types::{
            GotoDefinitionParams, Position, TextDocumentIdentifier, TextDocumentPositionParams,
        };

        // 确保文件已打开
        if let Err(e) = self.ensure_file_open(client, &command.file).await {
            return VimAction::Error {
                message: format!("Failed to open file: {}", e),
            };
        }

        let uri = match lsp_types::Url::from_file_path(&command.file) {
            Ok(uri) => uri,
            Err(_) => {
                return VimAction::Error {
                    message: format!("Invalid file path: {}", command.file),
                }
            }
        };

        let params = GotoDefinitionParams {
            text_document_position_params: TextDocumentPositionParams {
                text_document: TextDocumentIdentifier { uri },
                position: Position {
                    line: command.line,
                    character: command.column,
                },
            },
            work_done_progress_params: Default::default(),
            partial_result_params: Default::default(),
        };

        use lsp_types::request::GotoDefinition;
        match client.request::<GotoDefinition>(params).await {
            Ok(Some(response)) => {
                use tracing::debug;
                debug!("Got LSP definition response: {:?}", response);

                // 处理 GotoDefinitionResponse (可能是 Location 或 LocationLink)
                match response {
                    lsp_types::GotoDefinitionResponse::Scalar(location) => {
                        VimAction::from(location)
                    }
                    lsp_types::GotoDefinitionResponse::Array(locations) => {
                        if let Some(first) = locations.first() {
                            VimAction::from(first)
                        } else {
                            VimAction::Error {
                                message: "No definition found".to_string(),
                            }
                        }
                    }
                    lsp_types::GotoDefinitionResponse::Link(links) => {
                        if let Some(first_link) = links.first() {
                            VimAction::from(first_link)
                        } else {
                            VimAction::Error {
                                message: "No definition found".to_string(),
                            }
                        }
                    }
                }
            }
            Ok(None) => VimAction::Error {
                message: "No definition found".to_string(),
            },
            Err(e) => VimAction::Error {
                message: e.to_string(),
            },
        }
    }

    /// 处理跳转到类型定义
    async fn handle_goto_type_definition(
        &self,
        client: &LspClient,
        command: &VimCommand,
    ) -> VimAction {
        use lsp_types::request::GotoTypeDefinitionParams;
        use lsp_types::{Position, TextDocumentIdentifier, TextDocumentPositionParams};

        // 确保文件已打开
        if let Err(e) = self.ensure_file_open(client, &command.file).await {
            return VimAction::Error {
                message: format!("Failed to open file: {}", e),
            };
        }

        let uri = match lsp_types::Url::from_file_path(&command.file) {
            Ok(uri) => uri,
            Err(_) => {
                return VimAction::Error {
                    message: format!("Invalid file path: {}", command.file),
                }
            }
        };

        let params = GotoTypeDefinitionParams {
            text_document_position_params: TextDocumentPositionParams {
                text_document: TextDocumentIdentifier { uri },
                position: Position {
                    line: command.line,
                    character: command.column,
                },
            },
            work_done_progress_params: Default::default(),
            partial_result_params: Default::default(),
        };

        use lsp_types::request::GotoTypeDefinition;
        match client.request::<GotoTypeDefinition>(params).await {
            Ok(Some(response)) => {
                use tracing::debug;
                debug!("Got LSP type definition response: {:?}", response);

                // 处理 GotoDefinitionResponse (可能是 Location 或 LocationLink)
                match response {
                    lsp_types::GotoDefinitionResponse::Scalar(location) => {
                        VimAction::from(location)
                    }
                    lsp_types::GotoDefinitionResponse::Array(locations) => {
                        if let Some(first) = locations.first() {
                            VimAction::from(first)
                        } else {
                            VimAction::Error {
                                message: "No type definition found".to_string(),
                            }
                        }
                    }
                    lsp_types::GotoDefinitionResponse::Link(links) => {
                        if let Some(first_link) = links.first() {
                            VimAction::from(first_link)
                        } else {
                            VimAction::Error {
                                message: "No type definition found".to_string(),
                            }
                        }
                    }
                }
            }
            Ok(None) => VimAction::Error {
                message: "No type definition found".to_string(),
            },
            Err(e) => VimAction::Error {
                message: e.to_string(),
            },
        }
    }

    /// 处理跳转到实现
    async fn handle_goto_implementation(
        &self,
        client: &LspClient,
        command: &VimCommand,
    ) -> VimAction {
        use lsp_types::request::GotoImplementationParams;
        use lsp_types::{Position, TextDocumentIdentifier, TextDocumentPositionParams};

        // 确保文件已打开
        if let Err(e) = self.ensure_file_open(client, &command.file).await {
            return VimAction::Error {
                message: format!("Failed to open file: {}", e),
            };
        }

        let uri = match lsp_types::Url::from_file_path(&command.file) {
            Ok(uri) => uri,
            Err(_) => {
                return VimAction::Error {
                    message: format!("Invalid file path: {}", command.file),
                }
            }
        };

        let params = GotoImplementationParams {
            text_document_position_params: TextDocumentPositionParams {
                text_document: TextDocumentIdentifier { uri },
                position: Position {
                    line: command.line,
                    character: command.column,
                },
            },
            work_done_progress_params: Default::default(),
            partial_result_params: Default::default(),
        };

        use lsp_types::request::GotoImplementation;
        match client.request::<GotoImplementation>(params).await {
            Ok(Some(response)) => {
                use tracing::debug;
                debug!("Got LSP implementation response: {:?}", response);

                // 处理 GotoDefinitionResponse (可能是 Location 或 LocationLink)
                match response {
                    lsp_types::GotoDefinitionResponse::Scalar(location) => {
                        VimAction::from(location)
                    }
                    lsp_types::GotoDefinitionResponse::Array(locations) => {
                        if let Some(first) = locations.first() {
                            VimAction::from(first)
                        } else {
                            VimAction::Error {
                                message: "No implementation found".to_string(),
                            }
                        }
                    }
                    lsp_types::GotoDefinitionResponse::Link(links) => {
                        if let Some(first_link) = links.first() {
                            VimAction::from(first_link)
                        } else {
                            VimAction::Error {
                                message: "No implementation found".to_string(),
                            }
                        }
                    }
                }
            }
            Ok(None) => VimAction::Error {
                message: "No implementation found".to_string(),
            },
            Err(e) => VimAction::Error {
                message: e.to_string(),
            },
        }
    }

    /// 处理悬停信息
    async fn handle_hover(&self, client: &LspClient, command: &VimCommand) -> VimAction {
        use lsp_types::{
            HoverParams, Position, TextDocumentIdentifier, TextDocumentPositionParams,
        };

        // 确保文件已打开
        if let Err(e) = self.ensure_file_open(client, &command.file).await {
            return VimAction::Error {
                message: format!("Failed to open file: {}", e),
            };
        }

        let uri = match lsp_types::Url::from_file_path(&command.file) {
            Ok(uri) => uri,
            Err(_) => {
                return VimAction::Error {
                    message: format!("Invalid file path: {}", command.file),
                }
            }
        };

        let params = HoverParams {
            text_document_position_params: TextDocumentPositionParams {
                text_document: TextDocumentIdentifier { uri },
                position: Position {
                    line: command.line,
                    character: command.column,
                },
            },
            work_done_progress_params: Default::default(),
        };

        use lsp_types::request::HoverRequest;
        match client.request::<HoverRequest>(params).await {
            Ok(Some(hover)) => VimAction::from(hover),
            Ok(None) => VimAction::Error {
                message: "No hover information available".to_string(),
            },
            Err(e) => VimAction::Error {
                message: e.to_string(),
            },
        }
    }

    /// 处理代码补全
    async fn handle_completion(&self, client: &LspClient, command: &VimCommand) -> VimAction {
        use lsp_types::{
            CompletionParams, Position, TextDocumentIdentifier, TextDocumentPositionParams,
        };

        // 确保文件已经打开
        if let Err(e) = self.ensure_file_open(client, &command.file).await {
            return VimAction::Error {
                message: format!("Failed to open file: {}", e),
            };
        }

        let uri = match lsp_types::Url::from_file_path(&command.file) {
            Ok(uri) => uri,
            Err(_) => {
                return VimAction::Error {
                    message: format!("Invalid file path: {}", command.file),
                }
            }
        };

        let params = CompletionParams {
            text_document_position: TextDocumentPositionParams {
                text_document: TextDocumentIdentifier { uri },
                position: Position {
                    line: command.line,
                    character: command.column,
                },
            },
            work_done_progress_params: Default::default(),
            partial_result_params: Default::default(),
            context: None,
        };

        use lsp_types::request::Completion;
        let result = tokio::time::timeout(
            std::time::Duration::from_secs(3),
            client.request::<Completion>(params),
        )
        .await;

        match result {
            Ok(Ok(completions)) => {
                use tracing::debug;
                debug!("Got LSP completion result: {:?}", completions);

                let items = match completions {
                    Some(response) => self.extract_completion_items_from_response(&response),
                    None => vec![],
                };
                VimAction::Completions { items }
            }
            Ok(Err(e)) => VimAction::Error {
                message: format!("Completion failed: {}", e),
            },
            Err(_) => VimAction::Error {
                message: "Completion request timed out".to_string(),
            },
        }
    }

    /// 处理查找引用
    async fn handle_references(&self, client: &LspClient, command: &VimCommand) -> VimAction {
        use lsp_types::{
            Position, ReferenceContext, ReferenceParams, TextDocumentIdentifier,
            TextDocumentPositionParams,
        };

        // 确保文件已打开
        if let Err(e) = self.ensure_file_open(client, &command.file).await {
            return VimAction::Error {
                message: format!("Failed to open file: {}", e),
            };
        }

        let uri = match lsp_types::Url::from_file_path(&command.file) {
            Ok(uri) => uri,
            Err(_) => {
                return VimAction::Error {
                    message: format!("Invalid file path: {}", command.file),
                }
            }
        };

        let params = ReferenceParams {
            text_document_position: TextDocumentPositionParams {
                text_document: TextDocumentIdentifier { uri },
                position: Position {
                    line: command.line,
                    character: command.column,
                },
            },
            work_done_progress_params: Default::default(),
            partial_result_params: Default::default(),
            context: ReferenceContext {
                include_declaration: true,
            },
        };

        use lsp_types::request::References;
        match client.request::<References>(params).await {
            Ok(Some(locations)) => {
                use tracing::debug;
                debug!("Got LSP references result: {:?}", locations);

                let ref_locations: Vec<ReferenceLocation> = locations
                    .iter()
                    .filter_map(|loc| {
                        // 只转换有效的 URI，跳过无效的
                        if loc.uri.to_file_path().is_ok() {
                            Some(ReferenceLocation::from(loc))
                        } else {
                            None
                        }
                    })
                    .collect();
                VimAction::References {
                    locations: ref_locations,
                }
            }
            Ok(None) => VimAction::References { locations: vec![] },
            Err(e) => VimAction::Error {
                message: e.to_string(),
            },
        }
    }

    /// 处理inlay hints
    async fn handle_inlay_hints(&self, client: &LspClient, command: &VimCommand) -> VimAction {
        use lsp_types::{InlayHintParams, Position, Range, TextDocumentIdentifier};

        // 确保文件已打开
        if let Err(e) = self.ensure_file_open(client, &command.file).await {
            return VimAction::Error {
                message: format!("Failed to open file: {}", e),
            };
        }

        let uri = match lsp_types::Url::from_file_path(&command.file) {
            Ok(uri) => uri,
            Err(_) => {
                return VimAction::Error {
                    message: format!("Invalid file path: {}", command.file),
                }
            }
        };

        // Read file to get the total number of lines for the range
        let line_count = match std::fs::read_to_string(&command.file) {
            Ok(content) => content.lines().count() as u32,
            Err(_) => 1000, // fallback to a reasonable default
        };

        let params = InlayHintParams {
            text_document: TextDocumentIdentifier { uri },
            range: Range {
                start: Position {
                    line: 0,
                    character: 0,
                },
                end: Position {
                    line: line_count,
                    character: 0,
                },
            },
            work_done_progress_params: Default::default(),
        };

        use lsp_types::request::InlayHintRequest;
        match client.request::<InlayHintRequest>(params).await {
            Ok(Some(hints)) => {
                use tracing::debug;
                debug!("Got LSP inlay hints result: {:?}", hints);

                let converted_hints: Vec<InlayHint> = hints.iter().map(InlayHint::from).collect();

                VimAction::InlayHints {
                    hints: converted_hints,
                }
            }
            Ok(None) => VimAction::InlayHints { hints: vec![] },
            Err(e) => VimAction::Error {
                message: e.to_string(),
            },
        }
    }

    /// 处理符号重命名
    async fn handle_rename(&self, client: &LspClient, command: &VimCommand) -> VimAction {
        use lsp_types::{
            Position, RenameParams, TextDocumentIdentifier, TextDocumentPositionParams,
        };

        // 确保文件已打开
        if let Err(e) = self.ensure_file_open(client, &command.file).await {
            return VimAction::Error {
                message: format!("Failed to open file: {}", e),
            };
        }

        // 检查是否提供了新名称
        let new_name = match &command.new_name {
            Some(name) => name,
            None => {
                return VimAction::Error {
                    message: "No new name provided for rename".to_string(),
                };
            }
        };

        let uri = match lsp_types::Url::from_file_path(&command.file) {
            Ok(uri) => uri,
            Err(_) => {
                return VimAction::Error {
                    message: format!("Invalid file path: {}", command.file),
                }
            }
        };

        let params = RenameParams {
            text_document_position: TextDocumentPositionParams {
                text_document: TextDocumentIdentifier { uri },
                position: Position {
                    line: command.line,
                    character: command.column,
                },
            },
            new_name: new_name.clone(),
            work_done_progress_params: Default::default(),
        };

        use lsp_types::request::Rename;
        match client.request::<Rename>(params).await {
            Ok(Some(workspace_edit)) => {
                use tracing::debug;
                debug!("Got LSP rename result: {:?}", workspace_edit);

                // 转换 WorkspaceEdit 为我们的格式
                let edits = self.convert_workspace_edit(workspace_edit);

                if edits.is_empty() {
                    VimAction::Error {
                        message: "No changes to apply".to_string(),
                    }
                } else {
                    VimAction::WorkspaceEdit { edits }
                }
            }
            Ok(None) => VimAction::Error {
                message: "Cannot rename symbol at this position".to_string(),
            },
            Err(e) => VimAction::Error {
                message: format!("Rename failed: {}", e),
            },
        }
    }

    /// 处理 call hierarchy incoming calls
    async fn handle_call_hierarchy_incoming(
        &self,
        client: &LspClient,
        command: &VimCommand,
    ) -> VimAction {
        // First prepare call hierarchy items
        match self.prepare_call_hierarchy(client, command).await {
            Ok(Some(items)) => {
                if let Some(first_item) = items.first() {
                    // Get incoming calls for the first item
                    self.get_incoming_calls(client, first_item).await
                } else {
                    VimAction::Error {
                        message: "No call hierarchy item found".to_string(),
                    }
                }
            }
            Ok(None) => VimAction::Error {
                message: "No call hierarchy available".to_string(),
            },
            Err(e) => VimAction::Error {
                message: e.to_string(),
            },
        }
    }

    /// 处理 call hierarchy outgoing calls
    async fn handle_call_hierarchy_outgoing(
        &self,
        client: &LspClient,
        command: &VimCommand,
    ) -> VimAction {
        // First prepare call hierarchy items
        match self.prepare_call_hierarchy(client, command).await {
            Ok(Some(items)) => {
                if let Some(first_item) = items.first() {
                    // Get outgoing calls for the first item
                    self.get_outgoing_calls(client, first_item).await
                } else {
                    VimAction::Error {
                        message: "No call hierarchy item found".to_string(),
                    }
                }
            }
            Ok(None) => VimAction::Error {
                message: "No call hierarchy available".to_string(),
            },
            Err(e) => VimAction::Error {
                message: e.to_string(),
            },
        }
    }

    /// 准备 call hierarchy 请求
    async fn prepare_call_hierarchy(
        &self,
        client: &LspClient,
        command: &VimCommand,
    ) -> Result<Option<Vec<lsp_types::CallHierarchyItem>>, lsp_client::LspError> {
        use lsp_types::{
            CallHierarchyPrepareParams, Position, TextDocumentIdentifier,
            TextDocumentPositionParams,
        };

        // 确保文件已打开
        if let Err(e) = self.ensure_file_open(client, &command.file).await {
            return Err(lsp_client::LspError::Protocol(format!(
                "Failed to open file: {}",
                e
            )));
        }

        let uri = match lsp_types::Url::from_file_path(&command.file) {
            Ok(uri) => uri,
            Err(_) => {
                return Err(lsp_client::LspError::Protocol(format!(
                    "Invalid file path: {}",
                    command.file
                )));
            }
        };

        let params = CallHierarchyPrepareParams {
            text_document_position_params: TextDocumentPositionParams {
                text_document: TextDocumentIdentifier { uri },
                position: Position {
                    line: command.line,
                    character: command.column,
                },
            },
            work_done_progress_params: Default::default(),
        };

        use lsp_types::request::CallHierarchyPrepare;
        client.request::<CallHierarchyPrepare>(params).await
    }

    /// 获取 incoming calls
    async fn get_incoming_calls(
        &self,
        client: &LspClient,
        item: &lsp_types::CallHierarchyItem,
    ) -> VimAction {
        use lsp_types::{request::CallHierarchyIncomingCalls, CallHierarchyIncomingCallsParams};

        let params = CallHierarchyIncomingCallsParams {
            item: item.clone(),
            work_done_progress_params: Default::default(),
            partial_result_params: Default::default(),
        };

        match client.request::<CallHierarchyIncomingCalls>(params).await {
            Ok(Some(calls)) => {
                use tracing::debug;
                debug!("Got LSP incoming calls result: {:?}", calls);

                let call_items: Vec<CallHierarchyItem> = calls
                    .iter()
                    .map(|call| CallHierarchyItem::from(&call.from))
                    .collect();

                VimAction::CallHierarchy { items: call_items }
            }
            Ok(None) => VimAction::CallHierarchy { items: vec![] },
            Err(e) => VimAction::Error {
                message: e.to_string(),
            },
        }
    }

    /// 获取 outgoing calls
    async fn get_outgoing_calls(
        &self,
        client: &LspClient,
        item: &lsp_types::CallHierarchyItem,
    ) -> VimAction {
        use lsp_types::{request::CallHierarchyOutgoingCalls, CallHierarchyOutgoingCallsParams};

        let params = CallHierarchyOutgoingCallsParams {
            item: item.clone(),
            work_done_progress_params: Default::default(),
            partial_result_params: Default::default(),
        };

        match client.request::<CallHierarchyOutgoingCalls>(params).await {
            Ok(Some(calls)) => {
                use tracing::debug;
                debug!("Got LSP outgoing calls result: {:?}", calls);

                let call_items: Vec<CallHierarchyItem> = calls
                    .iter()
                    .map(|call| CallHierarchyItem::from(&call.to))
                    .collect();

                VimAction::CallHierarchy { items: call_items }
            }
            Ok(None) => VimAction::CallHierarchy { items: vec![] },
            Err(e) => VimAction::Error {
                message: e.to_string(),
            },
        }
    }

    /// 处理文档符号请求
    async fn handle_document_symbols(&self, client: &LspClient, command: &VimCommand) -> VimAction {
        use lsp_types::{DocumentSymbolParams, TextDocumentIdentifier};

        // 确保文件已打开
        if let Err(e) = self.ensure_file_open(client, &command.file).await {
            return VimAction::Error {
                message: format!("Failed to open file: {}", e),
            };
        }

        let uri = match lsp_types::Url::from_file_path(&command.file) {
            Ok(uri) => uri,
            Err(_) => {
                return VimAction::Error {
                    message: format!("Invalid file path: {}", command.file),
                }
            }
        };

        let params = DocumentSymbolParams {
            text_document: TextDocumentIdentifier { uri },
            work_done_progress_params: Default::default(),
            partial_result_params: Default::default(),
        };

        use lsp_types::request::DocumentSymbolRequest;
        match client.request::<DocumentSymbolRequest>(params).await {
            Ok(Some(response)) => {
                use tracing::debug;
                debug!("Got LSP document symbols result: {:?}", response);

                let symbols = self.convert_document_symbols_response(response, &command.file);
                VimAction::DocumentSymbols { symbols }
            }
            Ok(None) => VimAction::DocumentSymbols { symbols: vec![] },
            Err(e) => VimAction::Error {
                message: e.to_string(),
            },
        }
    }

    /// 处理文件打开通知
    async fn handle_file_open(&self, client: &LspClient, command: &VimCommand) -> VimAction {
        // 确保文件已经打开（发送textDocument/didOpen）
        if let Err(e) = self.ensure_file_open(client, &command.file).await {
            return VimAction::Error {
                message: format!("Failed to open file: {}", e),
            };
        }

        // 静默成功（不显示任何消息）
        VimAction::None
    }

    /// 确保文件在LSP服务器中已打开
    async fn ensure_file_open(&self, client: &LspClient, file_path: &str) -> Result<(), String> {
        use lsp_types::{DidOpenTextDocumentParams, TextDocumentItem};

        let text = std::fs::read_to_string(file_path)
            .map_err(|e| format!("Failed to read file: {}", e))?;

        let uri = lsp_types::Url::from_file_path(file_path)
            .map_err(|_| format!("Invalid file path: {}", file_path))?;

        let params = DidOpenTextDocumentParams {
            text_document: TextDocumentItem {
                uri,
                language_id: Self::detect_language(file_path),
                version: 1,
                text,
            },
        };

        client
            .notify("textDocument/didOpen", params)
            .await
            .map_err(|e| e.to_string())?;

        Ok(())
    }

    /// 从强类型 CompletionResponse 中提取补全项
    fn extract_completion_items_from_response(
        &self,
        response: &lsp_types::CompletionResponse,
    ) -> Vec<CompletionItem> {
        use lsp_types::CompletionResponse;

        let lsp_items = match response {
            CompletionResponse::Array(items) => items,
            CompletionResponse::List(list) => &list.items,
        };

        lsp_items.iter().map(CompletionItem::from).collect()
    }

    /// 转换 LSP WorkspaceEdit 为我们的格式
    fn convert_workspace_edit(&self, workspace_edit: lsp_types::WorkspaceEdit) -> Vec<FileEdit> {
        let mut file_edits = Vec::new();

        // 处理 changes (传统格式)
        if let Some(changes) = workspace_edit.changes {
            for (uri, text_edits) in changes {
                if let Ok(file_path) = uri.to_file_path() {
                    let file_path_str = file_path.to_string_lossy().to_string();
                    let converted_edits: Vec<TextEdit> =
                        text_edits.iter().map(TextEdit::from).collect();

                    if !converted_edits.is_empty() {
                        file_edits.push(FileEdit {
                            file: file_path_str,
                            edits: converted_edits,
                        });
                    }
                }
            }
        }

        // 处理 document_changes (新格式，更复杂，包含创建/重命名/删除文件)
        if let Some(document_changes) = workspace_edit.document_changes {
            use lsp_types::DocumentChanges;
            match document_changes {
                DocumentChanges::Edits(edits) => {
                    for edit in edits {
                        if let Ok(file_path) = edit.text_document.uri.to_file_path() {
                            let file_path_str = file_path.to_string_lossy().to_string();
                            let converted_edits: Vec<TextEdit> =
                                edit.edits.iter().map(TextEdit::from).collect();

                            if !converted_edits.is_empty() {
                                file_edits.push(FileEdit {
                                    file: file_path_str,
                                    edits: converted_edits,
                                });
                            }
                        }
                    }
                }
                DocumentChanges::Operations(_operations) => {
                    // 暂时不支持文件操作（创建/重命名/删除文件）
                    // 只处理文本编辑
                }
            }
        }

        file_edits
    }

    /// 转换 LSP DocumentSymbolResponse 为我们的格式
    fn convert_document_symbols_response(
        &self,
        response: lsp_types::DocumentSymbolResponse,
        file_path: &str,
    ) -> Vec<DocumentSymbol> {
        use lsp_types::DocumentSymbolResponse;

        match response {
            DocumentSymbolResponse::Flat(symbol_infos) => {
                // Convert SymbolInformation to DocumentSymbol
                symbol_infos
                    .iter()
                    .map(|info| DocumentSymbol::from_symbol_info(info, file_path))
                    .collect()
            }
            DocumentSymbolResponse::Nested(document_symbols) => {
                // Convert nested DocumentSymbol
                document_symbols
                    .iter()
                    .map(|symbol| DocumentSymbol::from_lsp_document_symbol(symbol, file_path))
                    .collect()
            }
        }
    }

    /// 根据文件扩展名检测语言
    fn detect_language(file_path: &str) -> String {
        if file_path.ends_with(".rs") {
            "rust".to_string()
        } else if file_path.ends_with(".py") {
            "python".to_string()
        } else if file_path.ends_with(".js") || file_path.ends_with(".ts") {
            "javascript".to_string()
        } else {
            "text".to_string()
        }
    }

    /// 根据语言类型创建对应的 LSP 客户端
    async fn create_client(&self, language: &str, file_path: &str) -> LspResult<LspClient> {
        use lsp_types::{ClientCapabilities, InitializeParams, WorkspaceFolder};
        use serde_json::json;

        match language {
            "rust" => {
                // 创建客户端
                let client = LspClient::new("rust-analyzer", &[]).await?;

                // 确定工作区根目录
                let workspace_root = Self::find_workspace_root(file_path);

                // 初始化LSP服务器
                #[allow(deprecated)]
                let init_params = InitializeParams {
                    process_id: Some(std::process::id()),
                    root_path: None,
                    root_uri: workspace_root
                        .as_ref()
                        .and_then(|path| lsp_types::Url::from_file_path(path).ok()),
                    initialization_options: None,
                    capabilities: ClientCapabilities::default(),
                    trace: None,
                    workspace_folders: workspace_root.and_then(|path| {
                        lsp_types::Url::from_file_path(&path).ok().map(|uri| {
                            vec![WorkspaceFolder {
                                uri,
                                name: path
                                    .file_name()
                                    .unwrap_or_default()
                                    .to_string_lossy()
                                    .to_string(),
                            }]
                        })
                    }),
                    client_info: None,
                    locale: None,
                };

                // 发送初始化请求
                use lsp_types::request::Initialize;
                client.request::<Initialize>(init_params).await?;
                client.notify("initialized", json!({})).await?;

                Ok(client)
            }
            _ => Err(lsp_client::LspError::Protocol(format!(
                "Unsupported language: {}",
                language
            ))),
        }
    }

    /// 查找工作区根目录（向上查找 Cargo.toml）
    fn find_workspace_root(file_path: &str) -> Option<PathBuf> {
        let mut path = PathBuf::from(file_path);

        while let Some(parent) = path.parent() {
            if parent.join("Cargo.toml").exists() {
                return Some(parent.to_path_buf());
            }
            path = parent.to_path_buf();
        }

        None
    }

    /// 辅助函数：将文件路径转换为LSP URI，减少重复代码
    fn file_path_to_uri(file_path: &str) -> Result<lsp_types::Url, VimAction> {
        lsp_types::Url::from_file_path(file_path).map_err(|_| VimAction::Error {
            message: format!("Invalid file path: {}", file_path),
        })
    }

    /// 处理文档保存通知
    async fn handle_did_save(&self, client: &LspClient, command: &VimCommand) -> VimAction {
        use lsp_types::{DidSaveTextDocumentParams, TextDocumentIdentifier};

        let uri = match Self::file_path_to_uri(&command.file) {
            Ok(uri) => uri,
            Err(action) => return action,
        };

        let params = DidSaveTextDocumentParams {
            text_document: TextDocumentIdentifier { uri },
            text: command.text.clone(),
        };

        match client.notify("textDocument/didSave", params).await {
            Ok(_) => VimAction::None,
            Err(e) => VimAction::Error {
                message: format!("Failed to send didSave notification: {}", e),
            },
        }
    }

    /// 处理文档更改通知
    async fn handle_did_change(&self, client: &LspClient, command: &VimCommand) -> VimAction {
        use lsp_types::{
            DidChangeTextDocumentParams, TextDocumentContentChangeEvent,
            VersionedTextDocumentIdentifier,
        };

        let uri = match Self::file_path_to_uri(&command.file) {
            Ok(uri) => uri,
            Err(action) => return action,
        };

        let text = command.text.as_ref().cloned().unwrap_or_default();
        let params = DidChangeTextDocumentParams {
            text_document: VersionedTextDocumentIdentifier { uri, version: 1 },
            content_changes: vec![TextDocumentContentChangeEvent {
                range: None, // Full document update
                range_length: None,
                text,
            }],
        };

        match client.notify("textDocument/didChange", params).await {
            Ok(_) => VimAction::None,
            Err(e) => VimAction::Error {
                message: format!("Failed to send didChange notification: {}", e),
            },
        }
    }

    /// 处理文档将要保存通知
    async fn handle_will_save(&self, client: &LspClient, command: &VimCommand) -> VimAction {
        use lsp_types::{
            TextDocumentIdentifier, TextDocumentSaveReason, WillSaveTextDocumentParams,
        };

        let uri = match Self::file_path_to_uri(&command.file) {
            Ok(uri) => uri,
            Err(action) => return action,
        };
        let reason = match command.save_reason.unwrap_or(1) {
            1 => TextDocumentSaveReason::MANUAL,
            2 => TextDocumentSaveReason::AFTER_DELAY,
            3 => TextDocumentSaveReason::FOCUS_OUT,
            _ => TextDocumentSaveReason::MANUAL, // Default to Manual save
        };

        let params = WillSaveTextDocumentParams {
            text_document: TextDocumentIdentifier { uri },
            reason,
        };

        match client.notify("textDocument/willSave", params).await {
            Ok(_) => VimAction::None,
            Err(e) => VimAction::Error {
                message: format!("Failed to send willSave notification: {}", e),
            },
        }
    }

    /// 处理文档将要保存等待直到完成请求
    async fn handle_will_save_wait_until(
        &self,
        client: &LspClient,
        command: &VimCommand,
    ) -> VimAction {
        use lsp_types::{
            TextDocumentIdentifier, TextDocumentSaveReason, WillSaveTextDocumentParams,
        };

        let uri = match Self::file_path_to_uri(&command.file) {
            Ok(uri) => uri,
            Err(action) => return action,
        };

        let reason = match command.save_reason.unwrap_or(1) {
            1 => TextDocumentSaveReason::MANUAL,
            2 => TextDocumentSaveReason::AFTER_DELAY,
            3 => TextDocumentSaveReason::FOCUS_OUT,
            _ => TextDocumentSaveReason::MANUAL,
        };

        let params = WillSaveTextDocumentParams {
            text_document: TextDocumentIdentifier { uri },
            reason,
        };

        use lsp_types::request::WillSaveWaitUntil;
        match client.request::<WillSaveWaitUntil>(params).await {
            Ok(Some(edits)) => {
                if edits.is_empty() {
                    VimAction::None
                } else {
                    // Convert the TextEdits to our format
                    let file_edits = vec![FileEdit {
                        file: command.file.clone(),
                        edits: edits.iter().map(TextEdit::from).collect(),
                    }];
                    VimAction::WorkspaceEdit { edits: file_edits }
                }
            }
            Ok(None) => VimAction::None,
            Err(e) => VimAction::Error {
                message: format!("Failed to send willSaveWaitUntil request: {}", e),
            },
        }
    }

    /// 处理文档关闭通知
    async fn handle_did_close(&self, client: &LspClient, command: &VimCommand) -> VimAction {
        use lsp_types::{DidCloseTextDocumentParams, TextDocumentIdentifier};

        let uri = match Self::file_path_to_uri(&command.file) {
            Ok(uri) => uri,
            Err(action) => return action,
        };

        let params = DidCloseTextDocumentParams {
            text_document: TextDocumentIdentifier { uri },
        };

        match client.notify("textDocument/didClose", params).await {
            Ok(_) => VimAction::None,
            Err(e) => VimAction::Error {
                message: format!("Failed to send didClose notification: {}", e),
            },
        }
    }
}

// Type conversion implementations using From trait - Linus approved!

// Direct From implementations for clean conversions
impl From<lsp_types::Location> for VimAction {
    fn from(location: lsp_types::Location) -> Self {
        match location.uri.to_file_path() {
            Ok(path) => VimAction::Jump {
                file: path.to_string_lossy().to_string(),
                line: location.range.start.line,
                column: location.range.start.character,
            },
            Err(_) => VimAction::Error {
                message: "Invalid file URI".to_string(),
            },
        }
    }
}

impl From<&lsp_types::Location> for VimAction {
    fn from(location: &lsp_types::Location) -> Self {
        match location.uri.to_file_path() {
            Ok(path) => VimAction::Jump {
                file: path.to_string_lossy().to_string(),
                line: location.range.start.line,
                column: location.range.start.character,
            },
            Err(_) => VimAction::Error {
                message: "Invalid file URI".to_string(),
            },
        }
    }
}

impl From<lsp_types::LocationLink> for VimAction {
    fn from(link: lsp_types::LocationLink) -> Self {
        match link.target_uri.to_file_path() {
            Ok(path) => VimAction::Jump {
                file: path.to_string_lossy().to_string(),
                line: link.target_selection_range.start.line,
                column: link.target_selection_range.start.character,
            },
            Err(_) => VimAction::Error {
                message: "Invalid file URI".to_string(),
            },
        }
    }
}

impl From<&lsp_types::LocationLink> for VimAction {
    fn from(link: &lsp_types::LocationLink) -> Self {
        match link.target_uri.to_file_path() {
            Ok(path) => VimAction::Jump {
                file: path.to_string_lossy().to_string(),
                line: link.target_selection_range.start.line,
                column: link.target_selection_range.start.character,
            },
            Err(_) => VimAction::Error {
                message: "Invalid file URI".to_string(),
            },
        }
    }
}

impl From<&lsp_types::Location> for ReferenceLocation {
    fn from(location: &lsp_types::Location) -> Self {
        let path = location.uri.to_file_path().expect("Invalid file URI");
        ReferenceLocation {
            file: path.to_string_lossy().to_string(),
            line: location.range.start.line,
            column: location.range.start.character,
        }
    }
}

// Convert LSP CompletionItem to our CompletionItem
impl From<&lsp_types::CompletionItem> for CompletionItem {
    fn from(item: &lsp_types::CompletionItem) -> Self {
        use lsp_types::CompletionItemKind;

        let kind = item
            .kind
            .map(|k| match k {
                CompletionItemKind::TEXT => "Text".to_string(),
                CompletionItemKind::METHOD => "Method".to_string(),
                CompletionItemKind::FUNCTION => "Function".to_string(),
                CompletionItemKind::CONSTRUCTOR => "Constructor".to_string(),
                CompletionItemKind::FIELD => "Field".to_string(),
                CompletionItemKind::VARIABLE => "Variable".to_string(),
                CompletionItemKind::CLASS => "Class".to_string(),
                CompletionItemKind::INTERFACE => "Interface".to_string(),
                CompletionItemKind::MODULE => "Module".to_string(),
                CompletionItemKind::PROPERTY => "Property".to_string(),
                CompletionItemKind::UNIT => "Unit".to_string(),
                CompletionItemKind::VALUE => "Value".to_string(),
                CompletionItemKind::ENUM => "Enum".to_string(),
                CompletionItemKind::KEYWORD => "Keyword".to_string(),
                CompletionItemKind::SNIPPET => "Snippet".to_string(),
                CompletionItemKind::COLOR => "Color".to_string(),
                CompletionItemKind::FILE => "File".to_string(),
                CompletionItemKind::REFERENCE => "Reference".to_string(),
                _ => "Unknown".to_string(),
            })
            .unwrap_or_else(|| "Unknown".to_string());

        // 提取详细信息
        let detail = item.detail.clone();

        // 提取并处理文档信息
        let documentation = item.documentation.as_ref().map(|doc| {
            use lsp_types::Documentation;
            match doc {
                Documentation::String(s) => s.clone(),
                Documentation::MarkupContent(markup) => markup.value.clone(),
            }
        });

        CompletionItem {
            label: item.label.clone(),
            kind,
            detail,
            documentation,
        }
    }
}

// Convert LSP Hover to VimAction
impl From<lsp_types::Hover> for VimAction {
    fn from(hover: lsp_types::Hover) -> Self {
        use lsp_types::HoverContents;

        let content = match hover.contents {
            HoverContents::Scalar(content) => match content {
                lsp_types::MarkedString::String(s) => s,
                lsp_types::MarkedString::LanguageString(ls) => ls.value,
            },
            HoverContents::Array(contents) => {
                let mut result = String::new();
                for content in contents {
                    match content {
                        lsp_types::MarkedString::String(s) => {
                            if !result.is_empty() {
                                result.push('\n');
                            }
                            result.push_str(&s);
                        }
                        lsp_types::MarkedString::LanguageString(ls) => {
                            if !result.is_empty() {
                                result.push('\n');
                            }
                            result.push_str(&ls.value);
                        }
                    }
                }
                result
            }
            HoverContents::Markup(markup) => markup.value,
        };

        VimAction::ShowHover { content }
    }
}

// Convert LSP InlayHint to our InlayHint
impl From<&lsp_types::InlayHint> for InlayHint {
    fn from(hint: &lsp_types::InlayHint) -> Self {
        use lsp_types::InlayHintLabel;

        let label = match &hint.label {
            InlayHintLabel::String(s) => s.clone(),
            InlayHintLabel::LabelParts(parts) => parts
                .iter()
                .map(|part| part.value.as_str())
                .collect::<Vec<_>>()
                .join(""),
        };

        let kind = hint
            .kind
            .as_ref()
            .map(|k| {
                use lsp_types::InlayHintKind;
                match *k {
                    InlayHintKind::TYPE => "type",
                    InlayHintKind::PARAMETER => "parameter",
                    _ => "other",
                }
            })
            .unwrap_or("other")
            .to_string();

        let tooltip = hint.tooltip.as_ref().map(|tooltip| {
            use lsp_types::InlayHintTooltip;
            match tooltip {
                InlayHintTooltip::String(s) => s.clone(),
                InlayHintTooltip::MarkupContent(markup) => markup.value.clone(),
            }
        });

        InlayHint {
            line: hint.position.line,
            column: hint.position.character,
            label,
            kind,
            tooltip,
        }
    }
}

// Convert LSP TextEdit to our TextEdit
impl From<&lsp_types::TextEdit> for TextEdit {
    fn from(edit: &lsp_types::TextEdit) -> Self {
        TextEdit {
            start_line: edit.range.start.line,
            start_column: edit.range.start.character,
            end_line: edit.range.end.line,
            end_column: edit.range.end.character,
            new_text: edit.new_text.clone(),
        }
    }
}

impl From<lsp_types::TextEdit> for TextEdit {
    fn from(edit: lsp_types::TextEdit) -> Self {
        TextEdit::from(&edit)
    }
}

// Convert LSP CallHierarchyItem to our CallHierarchyItem
impl From<&lsp_types::CallHierarchyItem> for CallHierarchyItem {
    fn from(item: &lsp_types::CallHierarchyItem) -> Self {
        use lsp_types::SymbolKind;

        let kind = match item.kind {
            SymbolKind::FUNCTION => "Function",
            SymbolKind::METHOD => "Method",
            SymbolKind::CONSTRUCTOR => "Constructor",
            SymbolKind::CLASS => "Class",
            SymbolKind::MODULE => "Module",
            SymbolKind::INTERFACE => "Interface",
            _ => "Unknown",
        }
        .to_string();

        let file_path = item
            .uri
            .to_file_path()
            .map(|p| p.to_string_lossy().to_string())
            .unwrap_or_else(|_| item.uri.to_string());

        CallHierarchyItem {
            name: item.name.clone(),
            kind,
            detail: item.detail.clone(),
            file: file_path,
            line: item.range.start.line,
            column: item.range.start.character,
            selection_line: item.selection_range.start.line,
            selection_column: item.selection_range.start.character,
        }
    }
}

// Convert LSP OneOf<TextEdit, AnnotatedTextEdit> to our TextEdit
impl From<&lsp_types::OneOf<lsp_types::TextEdit, lsp_types::AnnotatedTextEdit>> for TextEdit {
    fn from(edit: &lsp_types::OneOf<lsp_types::TextEdit, lsp_types::AnnotatedTextEdit>) -> Self {
        match edit {
            lsp_types::OneOf::Left(text_edit) => TextEdit::from(text_edit),
            lsp_types::OneOf::Right(annotated_edit) => TextEdit::from(&annotated_edit.text_edit),
        }
    }
}

// Convert LSP DocumentSymbol and SymbolInformation to our DocumentSymbol
impl DocumentSymbol {
    fn from_lsp_document_symbol(symbol: &lsp_types::DocumentSymbol, file_path: &str) -> Self {
        use lsp_types::SymbolKind;

        let kind = match symbol.kind {
            SymbolKind::FILE => "File",
            SymbolKind::MODULE => "Module",
            SymbolKind::NAMESPACE => "Namespace",
            SymbolKind::PACKAGE => "Package",
            SymbolKind::CLASS => "Class",
            SymbolKind::METHOD => "Method",
            SymbolKind::PROPERTY => "Property",
            SymbolKind::FIELD => "Field",
            SymbolKind::CONSTRUCTOR => "Constructor",
            SymbolKind::ENUM => "Enum",
            SymbolKind::INTERFACE => "Interface",
            SymbolKind::FUNCTION => "Function",
            SymbolKind::VARIABLE => "Variable",
            SymbolKind::CONSTANT => "Constant",
            SymbolKind::STRING => "String",
            SymbolKind::NUMBER => "Number",
            SymbolKind::BOOLEAN => "Boolean",
            SymbolKind::ARRAY => "Array",
            SymbolKind::OBJECT => "Object",
            SymbolKind::KEY => "Key",
            SymbolKind::NULL => "Null",
            SymbolKind::ENUM_MEMBER => "EnumMember",
            SymbolKind::STRUCT => "Struct",
            SymbolKind::EVENT => "Event",
            SymbolKind::OPERATOR => "Operator",
            SymbolKind::TYPE_PARAMETER => "TypeParameter",
            _ => "Unknown",
        }
        .to_string();

        let children = symbol
            .children
            .as_ref()
            .map(|children| {
                children
                    .iter()
                    .map(|child| DocumentSymbol::from_lsp_document_symbol(child, file_path))
                    .collect()
            })
            .unwrap_or_default();

        DocumentSymbol {
            name: symbol.name.clone(),
            kind,
            detail: symbol.detail.clone(),
            file: file_path.to_string(),
            line: symbol.range.start.line,
            column: symbol.range.start.character,
            selection_line: symbol.selection_range.start.line,
            selection_column: symbol.selection_range.start.character,
            children,
        }
    }

    fn from_symbol_info(info: &lsp_types::SymbolInformation, file_path: &str) -> Self {
        use lsp_types::SymbolKind;

        let kind = match info.kind {
            SymbolKind::FILE => "File",
            SymbolKind::MODULE => "Module",
            SymbolKind::NAMESPACE => "Namespace",
            SymbolKind::PACKAGE => "Package",
            SymbolKind::CLASS => "Class",
            SymbolKind::METHOD => "Method",
            SymbolKind::PROPERTY => "Property",
            SymbolKind::FIELD => "Field",
            SymbolKind::CONSTRUCTOR => "Constructor",
            SymbolKind::ENUM => "Enum",
            SymbolKind::INTERFACE => "Interface",
            SymbolKind::FUNCTION => "Function",
            SymbolKind::VARIABLE => "Variable",
            SymbolKind::CONSTANT => "Constant",
            SymbolKind::STRING => "String",
            SymbolKind::NUMBER => "Number",
            SymbolKind::BOOLEAN => "Boolean",
            SymbolKind::ARRAY => "Array",
            SymbolKind::OBJECT => "Object",
            SymbolKind::KEY => "Key",
            SymbolKind::NULL => "Null",
            SymbolKind::ENUM_MEMBER => "EnumMember",
            SymbolKind::STRUCT => "Struct",
            SymbolKind::EVENT => "Event",
            SymbolKind::OPERATOR => "Operator",
            SymbolKind::TYPE_PARAMETER => "TypeParameter",
            _ => "Unknown",
        }
        .to_string();

        DocumentSymbol {
            name: info.name.clone(),
            kind,
            detail: None,
            file: file_path.to_string(),
            line: info.location.range.start.line,
            column: info.location.range.start.character,
            selection_line: info.location.range.start.line,
            selection_column: info.location.range.start.character,
            children: vec![], // SymbolInformation is flat
        }
    }
}
