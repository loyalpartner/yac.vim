use lsp_client::{LspClient, Result as LspResult};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

// 宏：简化 file_path_to_uri 的错误处理
macro_rules! try_uri {
    ($lsp_bridge:expr, $file_path:expr) => {
        match $lsp_bridge.file_path_to_uri($file_path) {
            Ok(uri) => uri,
            Err(error) => return error,
        }
    };
}

// Linus 风格：简化的位置数据结构
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FilePos {
    pub file: String,
    pub line: u32,
    pub column: u32,
}

impl FilePos {
    pub fn new(file: String, line: u32, column: u32) -> Self {
        Self { file, line, column }
    }
}

// Linus 风格：类型安全的命令格式 - 消除重复，好品味的数据结构
#[derive(Debug, Serialize, Deserialize)]
#[serde(tag = "command")]
pub enum VimCommand {
    // 简单文件操作
    #[serde(rename = "file_open")]
    FileOpen(String),

    // 所有导航命令使用相同的位置结构
    #[serde(rename = "goto_definition")]
    GotoDefinition(FilePos),

    #[serde(rename = "goto_declaration")]
    GotoDeclaration(FilePos),

    #[serde(rename = "goto_type_definition")]
    GotoTypeDefinition(FilePos),

    #[serde(rename = "goto_implementation")]
    GotoImplementation(FilePos),

    // 信息查询命令
    #[serde(rename = "hover")]
    Hover(FilePos),

    #[serde(rename = "completion")]
    Completion(FilePos),

    #[serde(rename = "references")]
    References(FilePos),

    // 文档级别命令
    #[serde(rename = "inlay_hints")]
    InlayHints(String),

    #[serde(rename = "document_symbols")]
    DocumentSymbols(String),

    #[serde(rename = "folding_range")]
    FoldingRange { file: String },

    // 高级功能 - 使用专门的结构
    #[serde(rename = "rename")]
    Rename {
        file: String,
        line: u32,
        column: u32,
        new_name: String,
    },

    #[serde(rename = "call_hierarchy_incoming")]
    CallHierarchyIncoming(FilePos),

    #[serde(rename = "call_hierarchy_outgoing")]
    CallHierarchyOutgoing(FilePos),

    // 文档生命周期
    #[serde(rename = "did_save")]
    DidSave { file: String, text: Option<String> },

    #[serde(rename = "did_change")]
    DidChange { file: String, text: String },

    #[serde(rename = "will_save")]
    WillSave {
        file: String,
        save_reason: Option<u32>,
    },

    #[serde(rename = "will_save_wait_until")]
    WillSaveWaitUntil {
        file: String,
        save_reason: Option<u32>,
    },

    #[serde(rename = "did_close")]
    DidClose(String),
}

impl VimCommand {
    /// Linus 风格：一个简单的函数获取文件路径，消除所有重复
    pub fn file_path(&self) -> &str {
        match self {
            VimCommand::FileOpen(file) => file,
            VimCommand::GotoDefinition(pos) => &pos.file,
            VimCommand::GotoDeclaration(pos) => &pos.file,
            VimCommand::GotoTypeDefinition(pos) => &pos.file,
            VimCommand::GotoImplementation(pos) => &pos.file,
            VimCommand::Hover(pos) => &pos.file,
            VimCommand::Completion(pos) => &pos.file,
            VimCommand::References(pos) => &pos.file,
            VimCommand::InlayHints(file) => file,
            VimCommand::DocumentSymbols(file) => file,
            VimCommand::FoldingRange { file } => file,
            VimCommand::Rename { file, .. } => file,
            VimCommand::CallHierarchyIncoming(pos) => &pos.file,
            VimCommand::CallHierarchyOutgoing(pos) => &pos.file,
            VimCommand::DidSave { file, .. } => file,
            VimCommand::DidChange { file, .. } => file,
            VimCommand::WillSave { file, .. } => file,
            VimCommand::WillSaveWaitUntil { file, .. } => file,
            VimCommand::DidClose(file) => file,
        }
    }

    /// 获取位置信息（如果有）
    pub fn position(&self) -> Option<&FilePos> {
        match self {
            VimCommand::GotoDefinition(pos)
            | VimCommand::GotoDeclaration(pos)
            | VimCommand::GotoTypeDefinition(pos)
            | VimCommand::GotoImplementation(pos)
            | VimCommand::Hover(pos)
            | VimCommand::Completion(pos)
            | VimCommand::References(pos)
            | VimCommand::CallHierarchyIncoming(pos)
            | VimCommand::CallHierarchyOutgoing(pos) => Some(pos),
            _ => None,
        }
    }
}

// 直接转换到 LSP 类型 - 消除中间层

impl FilePos {
    pub fn to_text_document_position_params(
        &self,
        uri: lsp_types::Url,
    ) -> lsp_types::TextDocumentPositionParams {
        use lsp_types::{Position, TextDocumentIdentifier, TextDocumentPositionParams};
        TextDocumentPositionParams {
            text_document: TextDocumentIdentifier { uri },
            position: Position {
                line: self.line,
                character: self.column,
            },
        }
    }

    pub fn to_goto_definition_params(
        &self,
        uri: lsp_types::Url,
    ) -> lsp_types::GotoDefinitionParams {
        lsp_types::GotoDefinitionParams {
            text_document_position_params: self.to_text_document_position_params(uri),
            work_done_progress_params: Default::default(),
            partial_result_params: Default::default(),
        }
    }

    pub fn to_hover_params(&self, uri: lsp_types::Url) -> lsp_types::HoverParams {
        lsp_types::HoverParams {
            text_document_position_params: self.to_text_document_position_params(uri),
            work_done_progress_params: Default::default(),
        }
    }

    pub fn to_completion_params(&self, uri: lsp_types::Url) -> lsp_types::CompletionParams {
        lsp_types::CompletionParams {
            text_document_position: self.to_text_document_position_params(uri),
            work_done_progress_params: Default::default(),
            partial_result_params: Default::default(),
            context: None,
        }
    }

    pub fn to_reference_params(&self, uri: lsp_types::Url) -> lsp_types::ReferenceParams {
        lsp_types::ReferenceParams {
            text_document_position: self.to_text_document_position_params(uri),
            work_done_progress_params: Default::default(),
            partial_result_params: Default::default(),
            context: lsp_types::ReferenceContext {
                include_declaration: true,
            },
        }
    }
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(tag = "action")]
pub enum VimAction {
    #[serde(rename = "init")]
    Init { log_file: String },
    #[serde(rename = "jump")]
    Jump {
        file: String,
        line: u32,
        column: u32,
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
    #[serde(rename = "folding_ranges")]
    FoldingRanges { ranges: Vec<FoldingRange> },
    #[serde(rename = "none")]
    None,
    #[serde(rename = "error")]
    Error { message: String },
}

#[derive(Debug, Serialize, Deserialize)]
pub struct CompletionItem {
    pub label: String,
    pub kind: String,
    pub detail: Option<String>,
    pub documentation: Option<String>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct ReferenceLocation {
    pub file: String,
    pub line: u32,
    pub column: u32,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct InlayHint {
    pub line: u32,
    pub column: u32,
    pub label: String,
    pub kind: String,
    pub tooltip: Option<String>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct FileEdit {
    pub file: String,
    pub edits: Vec<TextEdit>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct TextEdit {
    pub start_line: u32,
    pub start_column: u32,
    pub end_line: u32,
    pub end_column: u32,
    pub new_text: String,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct CallHierarchyItem {
    pub name: String,
    pub kind: String,
    pub detail: Option<String>,
    pub file: String,
    pub line: u32,
    pub column: u32,
    pub selection_line: u32,
    pub selection_column: u32,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct DocumentSymbol {
    pub name: String,
    pub kind: String,
    pub detail: Option<String>,
    pub file: String,
    pub line: u32,
    pub column: u32,
    pub selection_line: u32,
    pub selection_column: u32,
    pub children: Vec<DocumentSymbol>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct FoldingRange {
    pub start_line: u32,
    pub start_character: Option<u32>,
    pub end_line: u32,
    pub end_character: Option<u32>,
    pub kind: Option<String>,
    pub collapsed_text: Option<String>,
}

pub struct LspBridge {
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

    pub async fn handle_command(&mut self, command: VimCommand) -> VimAction {
        let file_path = command.file_path();
        let language = Self::detect_language(file_path);

        if self.client.is_none() {
            match self.create_client(&language, file_path).await {
                Ok(client) => self.client = Some(client),
                Err(e) => {
                    return VimAction::Error {
                        message: format!("Failed to create LSP client: {}", e),
                    }
                }
            }
        }

        self.handle_vim_command(command).await
    }

    // Linus 风格：直接的实现，没有过度的泛型抽象
    async fn handle_goto_request(
        &self,
        client: &LspClient,
        pos: &FilePos,
        request_type: &str,
    ) -> VimAction {
        if let Err(e) = self.ensure_file_open(client, &pos.file).await {
            return VimAction::Error {
                message: format!("Failed to open file: {}", e),
            };
        }

        let uri = try_uri!(self, &pos.file);

        let response = match request_type {
            "definition" => {
                use lsp_types::request::GotoDefinition;
                let params = pos.to_goto_definition_params(uri.clone());
                client.request::<GotoDefinition>(params).await
            }
            "declaration" => {
                use lsp_types::request::GotoDeclaration;
                let params = pos.to_goto_definition_params(uri.clone());
                client.request::<GotoDeclaration>(params).await
            }
            "type_definition" => {
                use lsp_types::request::GotoTypeDefinition;
                let type_params = lsp_types::request::GotoTypeDefinitionParams {
                    text_document_position_params: pos
                        .to_text_document_position_params(uri.clone()),
                    work_done_progress_params: Default::default(),
                    partial_result_params: Default::default(),
                };
                client.request::<GotoTypeDefinition>(type_params).await
            }
            "implementation" => {
                use lsp_types::request::GotoImplementation;
                let impl_params = lsp_types::request::GotoImplementationParams {
                    text_document_position_params: pos
                        .to_text_document_position_params(uri.clone()),
                    work_done_progress_params: Default::default(),
                    partial_result_params: Default::default(),
                };
                client.request::<GotoImplementation>(impl_params).await
            }
            _ => {
                return VimAction::Error {
                    message: format!("Unknown request type: {}", request_type),
                }
            }
        };

        match response {
            Ok(Some(goto_response)) => match goto_response {
                lsp_types::GotoDefinitionResponse::Scalar(location) => VimAction::from(location),
                lsp_types::GotoDefinitionResponse::Array(locations) => {
                    if let Some(first) = locations.first() {
                        VimAction::from(first)
                    } else {
                        VimAction::Error {
                            message: "No result found".to_string(),
                        }
                    }
                }
                lsp_types::GotoDefinitionResponse::Link(links) => {
                    if let Some(first) = links.first() {
                        VimAction::from(first)
                    } else {
                        VimAction::Error {
                            message: "No result found".to_string(),
                        }
                    }
                }
            },
            Ok(None) => VimAction::Error {
                message: "No result found".to_string(),
            },
            Err(e) => VimAction::Error {
                message: e.to_string(),
            },
        }
    }

    async fn handle_vim_command(&self, command: VimCommand) -> VimAction {
        if let Some(client) = &self.client {
            match command {
                VimCommand::FileOpen(ref file) => self.handle_file_open(client, file).await,

                // 使用通用函数处理所有 goto 请求
                VimCommand::GotoDefinition(ref pos) => {
                    self.handle_goto_request(client, pos, "definition").await
                }
                VimCommand::GotoDeclaration(ref pos) => {
                    self.handle_goto_request(client, pos, "declaration").await
                }
                VimCommand::GotoTypeDefinition(ref pos) => {
                    self.handle_goto_request(client, pos, "type_definition")
                        .await
                }
                VimCommand::GotoImplementation(ref pos) => {
                    self.handle_goto_request(client, pos, "implementation")
                        .await
                }

                VimCommand::Hover(ref pos) => self.handle_hover(client, pos).await,
                VimCommand::Completion(ref pos) => self.handle_completion(client, pos).await,
                VimCommand::References(ref pos) => self.handle_references(client, pos).await,
                VimCommand::InlayHints(ref file) => self.handle_inlay_hints(client, file).await,
                VimCommand::DocumentSymbols(ref file) => {
                    self.handle_document_symbols(client, file).await
                }
                VimCommand::FoldingRange { ref file } => {
                    self.handle_folding_range(client, file).await
                }
                VimCommand::Rename {
                    ref file,
                    line,
                    column,
                    ref new_name,
                } => {
                    self.handle_rename(client, file, line, column, new_name)
                        .await
                }
                VimCommand::CallHierarchyIncoming(ref pos) => {
                    self.handle_call_hierarchy_incoming(client, pos).await
                }
                VimCommand::CallHierarchyOutgoing(ref pos) => {
                    self.handle_call_hierarchy_outgoing(client, pos).await
                }
                VimCommand::DidSave { ref file, ref text } => {
                    self.handle_did_save(client, file, text.as_deref()).await
                }
                VimCommand::DidChange { ref file, ref text } => {
                    self.handle_did_change(client, file, text).await
                }
                VimCommand::WillSave {
                    ref file,
                    save_reason,
                } => self.handle_will_save(client, file, save_reason).await,
                VimCommand::WillSaveWaitUntil {
                    ref file,
                    save_reason,
                } => {
                    self.handle_will_save_wait_until(client, file, save_reason)
                        .await
                }
                VimCommand::DidClose(ref file) => self.handle_did_close(client, file).await,
            }
        } else {
            VimAction::Error {
                message: "No LSP client available".to_string(),
            }
        }
    }

    async fn handle_hover(&self, client: &LspClient, pos: &FilePos) -> VimAction {
        if let Err(e) = self.ensure_file_open(client, &pos.file).await {
            return VimAction::Error {
                message: format!("Failed to open file: {}", e),
            };
        }

        let uri = try_uri!(self, &pos.file);
        let params = pos.to_hover_params(uri);

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

    async fn handle_completion(&self, client: &LspClient, pos: &FilePos) -> VimAction {
        if let Err(e) = self.ensure_file_open(client, &pos.file).await {
            return VimAction::Error {
                message: format!("Failed to open file: {}", e),
            };
        }

        let uri = try_uri!(self, &pos.file);
        let params = pos.to_completion_params(uri);

        use lsp_types::request::Completion;
        let result = tokio::time::timeout(
            std::time::Duration::from_secs(3),
            client.request::<Completion>(params),
        )
        .await;

        match result {
            Ok(Ok(completions)) => {
                let items = match completions {
                    Some(response) => self.extract_completion_items(&response),
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

    async fn handle_references(&self, client: &LspClient, pos: &FilePos) -> VimAction {
        if let Err(e) = self.ensure_file_open(client, &pos.file).await {
            return VimAction::Error {
                message: format!("Failed to open file: {}", e),
            };
        }

        let uri = try_uri!(self, &pos.file);
        let params = pos.to_reference_params(uri);

        use lsp_types::request::References;
        match client.request::<References>(params).await {
            Ok(Some(locations)) => {
                let ref_locations: Vec<ReferenceLocation> = locations
                    .iter()
                    .filter_map(|loc| {
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

    async fn handle_inlay_hints(&self, client: &LspClient, file: &str) -> VimAction {
        if let Err(e) = self.ensure_file_open(client, file).await {
            return VimAction::Error {
                message: format!("Failed to open file: {}", e),
            };
        }

        let uri = try_uri!(self, file);

        let line_count = match std::fs::read_to_string(file) {
            Ok(content) => content.lines().count() as u32,
            Err(_) => 1000,
        };

        let params = lsp_types::InlayHintParams {
            text_document: lsp_types::TextDocumentIdentifier { uri },
            range: lsp_types::Range {
                start: lsp_types::Position {
                    line: 0,
                    character: 0,
                },
                end: lsp_types::Position {
                    line: line_count,
                    character: 0,
                },
            },
            work_done_progress_params: Default::default(),
        };

        use lsp_types::request::InlayHintRequest;
        match client.request::<InlayHintRequest>(params).await {
            Ok(Some(hints)) => {
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

    async fn handle_rename(
        &self,
        client: &LspClient,
        file: &str,
        line: u32,
        column: u32,
        new_name: &str,
    ) -> VimAction {
        if let Err(e) = self.ensure_file_open(client, file).await {
            return VimAction::Error {
                message: format!("Failed to open file: {}", e),
            };
        }

        let uri = try_uri!(self, file);
        let params = lsp_types::RenameParams {
            text_document_position: lsp_types::TextDocumentPositionParams {
                text_document: lsp_types::TextDocumentIdentifier { uri },
                position: lsp_types::Position {
                    line,
                    character: column,
                },
            },
            new_name: new_name.to_string(),
            work_done_progress_params: Default::default(),
        };

        use lsp_types::request::Rename;
        match client.request::<Rename>(params).await {
            Ok(Some(workspace_edit)) => {
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

    async fn handle_call_hierarchy_incoming(&self, client: &LspClient, pos: &FilePos) -> VimAction {
        match self
            .prepare_call_hierarchy(client, &pos.file, pos.line, pos.column)
            .await
        {
            Ok(Some(items)) => {
                if let Some(first_item) = items.first() {
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

    async fn handle_call_hierarchy_outgoing(&self, client: &LspClient, pos: &FilePos) -> VimAction {
        match self
            .prepare_call_hierarchy(client, &pos.file, pos.line, pos.column)
            .await
        {
            Ok(Some(items)) => {
                if let Some(first_item) = items.first() {
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

    async fn handle_document_symbols(&self, client: &LspClient, file: &str) -> VimAction {
        if let Err(e) = self.ensure_file_open(client, file).await {
            return VimAction::Error {
                message: format!("Failed to open file: {}", e),
            };
        }

        let uri = try_uri!(self, file);
        let params = lsp_types::DocumentSymbolParams {
            text_document: lsp_types::TextDocumentIdentifier { uri },
            work_done_progress_params: Default::default(),
            partial_result_params: Default::default(),
        };

        use lsp_types::request::DocumentSymbolRequest;
        match client.request::<DocumentSymbolRequest>(params).await {
            Ok(Some(response)) => {
                let symbols = self.convert_document_symbols_response(response, file);
                VimAction::DocumentSymbols { symbols }
            }
            Ok(None) => VimAction::DocumentSymbols { symbols: vec![] },
            Err(e) => VimAction::Error {
                message: e.to_string(),
            },
        }
    }

    async fn handle_file_open(&self, client: &LspClient, file: &str) -> VimAction {
        if let Err(e) = self.ensure_file_open(client, file).await {
            return VimAction::Error {
                message: format!("Failed to open file: {}", e),
            };
        }
        VimAction::None
    }

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

    fn extract_completion_items(
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

    fn convert_workspace_edit(&self, workspace_edit: lsp_types::WorkspaceEdit) -> Vec<FileEdit> {
        let mut file_edits = Vec::new();

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
                DocumentChanges::Operations(_) => {}
            }
        }

        file_edits
    }

    fn convert_document_symbols_response(
        &self,
        response: lsp_types::DocumentSymbolResponse,
        file_path: &str,
    ) -> Vec<DocumentSymbol> {
        use lsp_types::DocumentSymbolResponse;

        match response {
            DocumentSymbolResponse::Flat(symbol_infos) => symbol_infos
                .iter()
                .map(|info| DocumentSymbol::from_symbol_info(info, file_path))
                .collect(),
            DocumentSymbolResponse::Nested(document_symbols) => document_symbols
                .iter()
                .map(|symbol| DocumentSymbol::from_lsp_document_symbol(symbol, file_path))
                .collect(),
        }
    }

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

    async fn create_client(&self, language: &str, file_path: &str) -> LspResult<LspClient> {
        use lsp_types::{ClientCapabilities, InitializeParams, WorkspaceFolder};
        use serde_json::json;

        match language {
            "rust" => {
                let client = LspClient::new("rust-analyzer", &[]).await?;
                let workspace_root = Self::find_workspace_root(file_path);

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

    fn file_path_to_uri(&self, file_path: &str) -> Result<lsp_types::Url, VimAction> {
        lsp_types::Url::from_file_path(file_path).map_err(|_| VimAction::Error {
            message: format!("Invalid file path: {}", file_path),
        })
    }

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

    async fn prepare_call_hierarchy(
        &self,
        client: &LspClient,
        file: &str,
        line: u32,
        column: u32,
    ) -> Result<Option<Vec<lsp_types::CallHierarchyItem>>, lsp_client::LspError> {
        use lsp_types::{
            CallHierarchyPrepareParams, Position, TextDocumentIdentifier,
            TextDocumentPositionParams,
        };

        if let Err(e) = self.ensure_file_open(client, file).await {
            return Err(lsp_client::LspError::Protocol(format!(
                "Failed to open file: {}",
                e
            )));
        }

        let uri = match lsp_types::Url::from_file_path(file) {
            Ok(uri) => uri,
            Err(_) => {
                return Err(lsp_client::LspError::Protocol(format!(
                    "Invalid file path: {}",
                    file
                )));
            }
        };

        let params = CallHierarchyPrepareParams {
            text_document_position_params: TextDocumentPositionParams {
                text_document: TextDocumentIdentifier { uri },
                position: Position {
                    line,
                    character: column,
                },
            },
            work_done_progress_params: Default::default(),
        };

        use lsp_types::request::CallHierarchyPrepare;
        client.request::<CallHierarchyPrepare>(params).await
    }

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

    async fn handle_did_save(
        &self,
        client: &LspClient,
        file: &str,
        text: Option<&str>,
    ) -> VimAction {
        use lsp_types::{DidSaveTextDocumentParams, TextDocumentIdentifier};

        let uri = try_uri!(self, file);
        let params = DidSaveTextDocumentParams {
            text_document: TextDocumentIdentifier { uri },
            text: text.map(|t| t.to_string()),
        };

        match client.notify("textDocument/didSave", params).await {
            Ok(_) => VimAction::None,
            Err(e) => VimAction::Error {
                message: format!("Failed to send didSave notification: {}", e),
            },
        }
    }

    async fn handle_did_change(&self, client: &LspClient, file: &str, text: &str) -> VimAction {
        use lsp_types::{
            DidChangeTextDocumentParams, TextDocumentContentChangeEvent,
            VersionedTextDocumentIdentifier,
        };
        use std::sync::atomic::{AtomicI32, Ordering};

        static DOCUMENT_VERSION: AtomicI32 = AtomicI32::new(1);
        let version = DOCUMENT_VERSION.fetch_add(1, Ordering::SeqCst);

        let uri = try_uri!(self, file);
        let params = DidChangeTextDocumentParams {
            text_document: VersionedTextDocumentIdentifier { uri, version },
            content_changes: vec![TextDocumentContentChangeEvent {
                range: None,
                range_length: None,
                text: text.to_string(),
            }],
        };

        match client.notify("textDocument/didChange", params).await {
            Ok(_) => VimAction::None,
            Err(e) => VimAction::Error {
                message: format!("Failed to send didChange notification: {}", e),
            },
        }
    }

    async fn handle_will_save(
        &self,
        client: &LspClient,
        file: &str,
        save_reason: Option<u32>,
    ) -> VimAction {
        use lsp_types::{
            TextDocumentIdentifier, TextDocumentSaveReason, WillSaveTextDocumentParams,
        };

        let uri = try_uri!(self, file);
        let reason = match save_reason.unwrap_or(1) {
            1 => TextDocumentSaveReason::MANUAL,
            2 => TextDocumentSaveReason::AFTER_DELAY,
            3 => TextDocumentSaveReason::FOCUS_OUT,
            _ => TextDocumentSaveReason::MANUAL,
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

    async fn handle_will_save_wait_until(
        &self,
        client: &LspClient,
        file: &str,
        save_reason: Option<u32>,
    ) -> VimAction {
        use lsp_types::{
            TextDocumentIdentifier, TextDocumentSaveReason, WillSaveTextDocumentParams,
        };

        let uri = try_uri!(self, file);
        let reason = match save_reason.unwrap_or(1) {
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
                    let file_edits = vec![FileEdit {
                        file: file.to_string(),
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

    async fn handle_did_close(&self, client: &LspClient, file: &str) -> VimAction {
        use lsp_types::{DidCloseTextDocumentParams, TextDocumentIdentifier};

        let uri = try_uri!(self, file);
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

    async fn handle_folding_range(&self, client: &LspClient, file: &str) -> VimAction {
        if let Err(e) = self.ensure_file_open(client, file).await {
            return VimAction::Error {
                message: format!("Failed to open file: {}", e),
            };
        }

        let uri = try_uri!(self, file);
        let params = lsp_types::FoldingRangeParams {
            text_document: lsp_types::TextDocumentIdentifier { uri },
            work_done_progress_params: Default::default(),
            partial_result_params: Default::default(),
        };

        use lsp_types::request::FoldingRangeRequest;
        match client.request::<FoldingRangeRequest>(params).await {
            Ok(Some(ranges)) => {
                let converted_ranges: Vec<FoldingRange> =
                    ranges.iter().map(FoldingRange::from).collect();
                VimAction::FoldingRanges {
                    ranges: converted_ranges,
                }
            }
            Ok(None) => VimAction::FoldingRanges { ranges: vec![] },
            Err(e) => VimAction::Error {
                message: e.to_string(),
            },
        }
    }
}

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

        let detail = item.detail.clone();
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

impl From<&lsp_types::OneOf<lsp_types::TextEdit, lsp_types::AnnotatedTextEdit>> for TextEdit {
    fn from(edit: &lsp_types::OneOf<lsp_types::TextEdit, lsp_types::AnnotatedTextEdit>) -> Self {
        match edit {
            lsp_types::OneOf::Left(text_edit) => TextEdit::from(text_edit),
            lsp_types::OneOf::Right(annotated_edit) => TextEdit::from(&annotated_edit.text_edit),
        }
    }
}

impl From<&lsp_types::FoldingRange> for FoldingRange {
    fn from(range: &lsp_types::FoldingRange) -> Self {
        let kind = range
            .kind
            .as_ref()
            .map(|k| {
                use lsp_types::FoldingRangeKind;
                match *k {
                    FoldingRangeKind::Comment => "comment",
                    FoldingRangeKind::Imports => "imports",
                    FoldingRangeKind::Region => "region",
                }
            })
            .map(|s| s.to_string());

        FoldingRange {
            start_line: range.start_line,
            start_character: range.start_character,
            end_line: range.end_line,
            end_character: range.end_character,
            kind,
            collapsed_text: range.collapsed_text.clone(),
        }
    }
}

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
            children: vec![],
        }
    }
}
