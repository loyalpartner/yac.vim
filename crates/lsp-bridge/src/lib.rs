use lsp_client::{LspClient, Result as LspResult};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::path::PathBuf;

// Legacy structs removed - now using VimCommand only

// 新的简化命令格式
#[derive(Debug, Serialize, Deserialize)]
pub struct VimCommand {
    pub command: String, // goto_definition, hover, completion
    pub file: String,    // 绝对文件路径
    pub line: u32,       // 0-based 行号
    pub column: u32,     // 0-based 列号
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
    #[serde(rename = "none")]
    None,
    #[serde(rename = "error")]
    Error { message: String },
}

#[derive(Debug, Serialize, Deserialize)]
pub struct CompletionItem {
    pub label: String,
    pub kind: String,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct ReferenceLocation {
    pub file: String,
    pub line: u32,    // 0-based
    pub column: u32,  // 0-based
}

// Using VimAction directly - no legacy support

pub struct LspBridge {
    // 暂时只支持单个客户端，后续可扩展
    client: Option<LspClient>,
}

impl LspBridge {
    pub fn new() -> Self {
        Self { client: None }
    }

    /// Legacy method removed - use handle_command instead

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

    /// Legacy unified request handler removed

    /// Legacy request handler removed

    /// 处理高层Vim命令
    async fn handle_vim_command(&self, command: VimCommand) -> VimAction {
        if let Some(client) = &self.client {
            match command.command.as_str() {
                "file_open" => self.handle_file_open(client, &command).await,
                "goto_definition" => self.handle_goto_definition(client, &command).await,
                "hover" => self.handle_hover(client, &command).await,
                "completion" => self.handle_completion(client, &command).await,
                "references" => self.handle_references(client, &command).await,
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

        match client.goto_definition(params).await {
            Ok(Some(response)) => {
                use tracing::debug;
                debug!("Got LSP definition response: {:?}", response);

                // 处理 GotoDefinitionResponse (可能是 Location 或 LocationLink)
                match response {
                    lsp_types::GotoDefinitionResponse::Scalar(location) => {
                        location.to_vim_action()
                    }
                    lsp_types::GotoDefinitionResponse::Array(locations) => {
                        if let Some(first) = locations.first() {
                            first.to_vim_action()
                        } else {
                            VimAction::Error {
                                message: "No definition found".to_string(),
                            }
                        }
                    }
                    lsp_types::GotoDefinitionResponse::Link(links) => {
                        if let Some(first_link) = links.first() {
                            first_link.to_vim_action()
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

    /// 处理悬停信息
    async fn handle_hover(&self, client: &LspClient, command: &VimCommand) -> VimAction {
        use lsp_types::{HoverParams, Position, TextDocumentIdentifier, TextDocumentPositionParams};

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

        match client.hover(params).await {
            Ok(Some(hover)) => {
                let content = hover.to_hover_content();
                VimAction::ShowHover { content }
            }
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
        use serde_json::json;

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

        let result = tokio::time::timeout(
            std::time::Duration::from_secs(3),
            client.request("textDocument/completion", json!(params)),
        )
        .await;

        match result {
            Ok(Ok(completions)) => {
                use tracing::debug;
                debug!("Got LSP completion result: {:?}", completions);

                let items = self.extract_completion_items(&completions);
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

        match client.references(params).await {
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
            Ok(None) => VimAction::References {
                locations: vec![],
            },
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
        use serde_json::json;

        let text = std::fs::read_to_string(file_path)
            .map_err(|e| format!("Failed to read file: {}", e))?;

        let params = json!({
            "textDocument": {
                "uri": format!("file://{}", file_path),
                "languageId": Self::detect_language(file_path),
                "version": 1,
                "text": text
            }
        });

        client
            .notify("textDocument/didOpen", params)
            .await
            .map_err(|e| e.to_string())?;

        Ok(())
    }


    /// 从补全结果中提取补全项
    fn extract_completion_items(&self, completions: &Value) -> Vec<CompletionItem> {
        let mut items = Vec::new();

        // 处理 CompletionList 或 CompletionItem[]
        let completion_items = if let Some(list) = completions.get("items") {
            // CompletionList 格式
            list.as_array()
        } else {
            // 直接是 CompletionItem[] 格式
            completions.as_array()
        };

        if let Some(items_array) = completion_items {
            for item in items_array {
                if let Some(label) = item.get("label").and_then(|l| l.as_str()) {
                    let kind = item
                        .get("kind")
                        .and_then(|k| k.as_u64())
                        .map(|k| self.completion_kind_to_string(k))
                        .unwrap_or_else(|| "Unknown".to_string());

                    items.push(CompletionItem {
                        label: label.to_string(),
                        kind,
                    });
                }
            }
        }

        items
    }



    /// 将LSP CompletionItemKind转换为字符串
    fn completion_kind_to_string(&self, kind: u64) -> String {
        match kind {
            1 => "Text".to_string(),
            2 => "Method".to_string(),
            3 => "Function".to_string(),
            4 => "Constructor".to_string(),
            5 => "Field".to_string(),
            6 => "Variable".to_string(),
            7 => "Class".to_string(),
            8 => "Interface".to_string(),
            9 => "Module".to_string(),
            10 => "Property".to_string(),
            11 => "Unit".to_string(),
            12 => "Value".to_string(),
            13 => "Enum".to_string(),
            14 => "Keyword".to_string(),
            15 => "Snippet".to_string(),
            16 => "Color".to_string(),
            17 => "File".to_string(),
            18 => "Reference".to_string(),
            _ => "Unknown".to_string(),
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

    /// Legacy is_notification method removed

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
                client
                    .request("initialize", serde_json::to_value(init_params)?)
                    .await?;
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
}

// Type conversion implementations using From trait for our own types - Linus approved!

impl From<&lsp_types::Location> for ReferenceLocation {
    fn from(location: &lsp_types::Location) -> Self {
        // Only convert if URI is valid, otherwise this will panic
        // Caller should validate before using this conversion
        let path = location.uri.to_file_path().expect("Invalid file URI");
        ReferenceLocation {
            file: path.to_string_lossy().to_string(),
            line: location.range.start.line,
            column: location.range.start.character,
        }
    }
}

// Helper trait for type conversion - avoids orphan rule issues
trait ToVimAction {
    fn to_vim_action(&self) -> VimAction;
}

impl ToVimAction for lsp_types::Location {
    fn to_vim_action(&self) -> VimAction {
        match self.uri.to_file_path() {
            Ok(path) => VimAction::Jump {
                file: path.to_string_lossy().to_string(),
                line: self.range.start.line,
                column: self.range.start.character,
            },
            Err(_) => VimAction::Error {
                message: "Invalid file URI".to_string(),
            },
        }
    }
}

impl ToVimAction for lsp_types::LocationLink {
    fn to_vim_action(&self) -> VimAction {
        match self.target_uri.to_file_path() {
            Ok(path) => VimAction::Jump {
                file: path.to_string_lossy().to_string(),
                line: self.target_selection_range.start.line,
                column: self.target_selection_range.start.character,
            },
            Err(_) => VimAction::Error {
                message: "Invalid file URI".to_string(),
            },
        }
    }
}

trait ToHoverContent {
    fn to_hover_content(&self) -> String;
}

impl ToHoverContent for lsp_types::Hover {
    fn to_hover_content(&self) -> String {
        use lsp_types::HoverContents;
        
        match &self.contents {
            HoverContents::Scalar(content) => match content {
                lsp_types::MarkedString::String(s) => s.clone(),
                lsp_types::MarkedString::LanguageString(ls) => ls.value.clone(),
            },
            HoverContents::Array(contents) => {
                let mut result = String::new();
                for content in contents {
                    match content {
                        lsp_types::MarkedString::String(s) => {
                            if !result.is_empty() {
                                result.push('\n');
                            }
                            result.push_str(s);
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
            HoverContents::Markup(markup) => markup.value.clone(),
        }
    }
}
