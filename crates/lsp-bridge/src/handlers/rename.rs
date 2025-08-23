use anyhow::Result;
use async_trait::async_trait;
use lsp_bridge::LspRegistry;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tracing::debug;
use vim::Handler;

#[derive(Debug, Deserialize)]
#[allow(dead_code)]
pub struct RenameRequest {
    pub file: String,
    pub line: u32,
    pub column: u32,
    pub new_name: String,
}

#[derive(Debug, Serialize)]
pub struct TextEdit {
    pub start_line: u32,
    pub start_column: u32,
    pub end_line: u32,
    pub end_column: u32,
    pub new_text: String,
}

#[derive(Debug, Serialize)]
pub struct FileEdit {
    pub file: String,
    pub edits: Vec<TextEdit>,
}

#[derive(Debug, Serialize)]
pub struct RenameInfo {
    pub edits: Vec<FileEdit>,
}

// Linus-style: RenameInfo 要么完整存在，要么不存在
pub type RenameResponse = Option<RenameInfo>;

impl TextEdit {
    pub fn new(
        start_line: u32,
        start_column: u32,
        end_line: u32,
        end_column: u32,
        new_text: String,
    ) -> Self {
        Self {
            start_line,
            start_column,
            end_line,
            end_column,
            new_text,
        }
    }
}

impl FileEdit {
    pub fn new(file: String, edits: Vec<TextEdit>) -> Self {
        Self { file, edits }
    }
}

impl RenameInfo {
    pub fn new(edits: Vec<FileEdit>) -> Self {
        Self { edits }
    }
}

pub struct RenameHandler {
    lsp_registry: Arc<LspRegistry>,
}

impl RenameHandler {
    pub fn new(registry: Arc<LspRegistry>) -> Self {
        Self {
            lsp_registry: registry,
        }
    }
}

#[async_trait]
impl Handler for RenameHandler {
    type Input = RenameRequest;
    type Output = RenameResponse;

    async fn handle(
        &self,
        _ctx: &mut dyn vim::VimContext,
        input: Self::Input,
    ) -> Result<Option<Self::Output>> {
        // Detect language
        let language = match self.lsp_registry.detect_language(&input.file) {
            Some(lang) => lang,
            None => return Ok(Some(None)), // Unsupported file type
        };

        // Ensure client exists
        if self
            .lsp_registry
            .get_client(&language, &input.file)
            .await
            .is_err()
        {
            return Ok(Some(None));
        }

        // Convert file path to URI
        let uri = match super::common::file_path_to_uri(&input.file) {
            Ok(uri) => uri,
            Err(_) => return Ok(Some(None)), // 处理了请求，但转换失败
        };

        // Make LSP rename request
        let params = lsp_types::RenameParams {
            text_document_position: lsp_types::TextDocumentPositionParams {
                text_document: lsp_types::TextDocumentIdentifier {
                    uri: lsp_types::Url::parse(&uri)?,
                },
                position: lsp_types::Position {
                    line: input.line,
                    character: input.column,
                },
            },
            new_name: input.new_name,
            work_done_progress_params: Default::default(),
        };

        let response = match self
            .lsp_registry
            .request::<lsp_types::request::Rename>(&language, params)
            .await
        {
            Ok(response) => response,
            Err(_) => return Ok(Some(None)), // 处理了请求，但 LSP 错误
        };

        debug!("rename response: {:?}", response);

        let workspace_edit = match response {
            Some(edit) => edit,
            None => return Ok(Some(None)), // 处理了请求，但没有重命名操作
        };

        let mut file_edits_map: std::collections::HashMap<String, Vec<TextEdit>> =
            std::collections::HashMap::new();

        // Extract changes from workspace edit
        if let Some(changes) = workspace_edit.changes {
            for (uri, text_edits) in changes {
                let file_path = match uri.to_file_path() {
                    Ok(path) => path.to_string_lossy().to_string(),
                    Err(_) => continue, // 跳过无效的 URI
                };

                let edits_for_file = file_edits_map.entry(file_path).or_default();
                for text_edit in text_edits {
                    edits_for_file.push(TextEdit::new(
                        text_edit.range.start.line,
                        text_edit.range.start.character,
                        text_edit.range.end.line,
                        text_edit.range.end.character,
                        text_edit.new_text,
                    ));
                }
            }
        }

        // Extract document changes (more complex structure)
        if let Some(document_changes) = workspace_edit.document_changes {
            match document_changes {
                lsp_types::DocumentChanges::Edits(edits) => {
                    for edit in edits {
                        let file_path = match edit.text_document.uri.to_file_path() {
                            Ok(path) => path.to_string_lossy().to_string(),
                            Err(_) => continue,
                        };

                        let edits_for_file = file_edits_map.entry(file_path).or_default();
                        for text_edit in edit.edits {
                            let lsp_types::OneOf::Left(text_edit) = text_edit else {
                                continue; // 跳过复杂的 AnnotatedTextEdit
                            };

                            edits_for_file.push(TextEdit::new(
                                text_edit.range.start.line,
                                text_edit.range.start.character,
                                text_edit.range.end.line,
                                text_edit.range.end.character,
                                text_edit.new_text,
                            ));
                        }
                    }
                }
                lsp_types::DocumentChanges::Operations(_ops) => {
                    // TODO: 处理文件操作（创建、删除、重命名文件）
                    // 目前跳过这些复杂操作
                }
            }
        }

        if file_edits_map.is_empty() {
            return Ok(Some(None)); // 处理了请求，但没有编辑操作
        }

        // 转换为 FileEdit 结构
        let result_file_edits: Vec<FileEdit> = file_edits_map
            .into_iter()
            .map(|(file_path, edits)| FileEdit::new(file_path, edits))
            .collect();

        Ok(Some(Some(RenameInfo::new(result_file_edits))))
    }
}
