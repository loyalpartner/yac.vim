use anyhow::Result;
use async_trait::async_trait;
use lsp_bridge::LspRegistry;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::Arc;
use tracing::debug;
use vim::{Handler, HandlerResult};

use super::common::{convert_workspace_edit, with_lsp_file, HasFile, HasFilePosition};

#[derive(Debug, Deserialize)]
#[allow(dead_code)]
pub struct RenameRequest {
    pub file: String,
    pub line: u32,
    pub column: u32,
    pub new_name: String,
}

impl HasFile for RenameRequest {
    fn file(&self) -> &str {
        &self.file
    }
}

impl HasFilePosition for RenameRequest {
    fn line(&self) -> u32 {
        self.line
    }
    fn column(&self) -> u32 {
        self.column
    }
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

pub type RenameResponse = RenameInfo;

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
        _vim: &dyn vim::VimContext,
        input: Self::Input,
    ) -> Result<HandlerResult<Self::Output>> {
        with_lsp_file(&self.lsp_registry, input, |ctx, input| async move {
            let params = lsp_types::RenameParams {
                text_document_position: lsp_types::TextDocumentPositionParams {
                    text_document: lsp_types::TextDocumentIdentifier { uri: ctx.uri },
                    position: lsp_types::Position {
                        line: input.line,
                        character: input.column,
                    },
                },
                new_name: input.new_name,
                work_done_progress_params: Default::default(),
            };

            let response = match ctx
                .registry
                .request::<lsp_types::request::Rename>(&ctx.language, params)
                .await
            {
                Ok(response) => response,
                Err(_) => return Ok(HandlerResult::Empty),
            };

            debug!("rename response: {:?}", response);

            let workspace_edit = match response {
                Some(edit) => edit,
                None => return Ok(HandlerResult::Empty),
            };

            let flat_edits = convert_workspace_edit(workspace_edit);
            if flat_edits.is_empty() {
                return Ok(HandlerResult::Empty);
            }

            // Group by file for rename response format
            let mut grouped: HashMap<String, Vec<TextEdit>> = HashMap::new();
            for e in flat_edits {
                grouped.entry(e.file).or_default().push(TextEdit {
                    start_line: e.start_line,
                    start_column: e.start_column,
                    end_line: e.end_line,
                    end_column: e.end_column,
                    new_text: e.new_text,
                });
            }

            let file_edits: Vec<FileEdit> = grouped
                .into_iter()
                .map(|(file, edits)| FileEdit { file, edits })
                .collect();

            Ok(HandlerResult::Data(RenameInfo { edits: file_edits }))
        })
        .await
    }
}
