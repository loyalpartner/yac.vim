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

        let result = tokio::time::timeout(
            std::time::Duration::from_secs(3),
            client.request("textDocument/definition", json!(params)),
        )
        .await;

        match result {
            Ok(Ok(locations)) => {
                use tracing::debug;
                debug!("Got LSP result: {:?}", locations);
                // 解析位置信息
                if let Some(locations) = locations.as_array() {
                    debug!("Locations array length: {}", locations.len());
                    if let Some(first_location) = locations.first() {
                        if let (Some(uri), Some(range)) = (
                            first_location.get("uri").and_then(|u| u.as_str()),
                            first_location.get("range"),
                        ) {
                            if let Some(start) = range.get("start") {
                                if let (Some(line), Some(character)) = (
                                    start.get("line").and_then(|l| l.as_u64()),
                                    start.get("character").and_then(|c| c.as_u64()),
                                ) {
                                    if let Ok(url) = lsp_types::Url::parse(uri) {
                                        if let Ok(path) = url.to_file_path() {
                                            return VimAction::Jump {
                                                file: path.to_string_lossy().to_string(),
                                                line: line as u32,
                                                column: character as u32,
                                            };
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                VimAction::Error {
                    message: "No definition found".to_string(),
                }
            }
            Ok(Err(e)) => VimAction::Error {
                message: format!("LSP error: {}", e),
            },
            Err(_) => VimAction::Error {
                message: "Request timed out".to_string(),
            },
        }
    }

    /// 处理悬停信息
    async fn handle_hover(&self, client: &LspClient, command: &VimCommand) -> VimAction {
        use lsp_types::{
            HoverParams, Position, TextDocumentIdentifier, TextDocumentPositionParams,
        };
        use serde_json::json;

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

        match client.request("textDocument/hover", json!(params)).await {
            Ok(result) => {
                if let Some(contents) = result.get("contents") {
                    let content = self.extract_hover_content(contents);
                    VimAction::ShowHover { content }
                } else {
                    VimAction::Error {
                        message: "No hover information available".to_string(),
                    }
                }
            }
            Err(e) => VimAction::Error {
                message: format!("Hover failed: {}", e),
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

    /// 从悬停结果中提取内容
    fn extract_hover_content(&self, contents: &Value) -> String {
        // 简化实现：直接转换为字符串
        if let Some(s) = contents.as_str() {
            s.to_string()
        } else if let Some(obj) = contents.as_object() {
            if let Some(value) = obj.get("value").and_then(|v| v.as_str()) {
                value.to_string()
            } else {
                serde_json::to_string_pretty(contents).unwrap_or_default()
            }
        } else {
            serde_json::to_string_pretty(contents).unwrap_or_default()
        }
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
                    work_done_progress_params: Default::default(),
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
