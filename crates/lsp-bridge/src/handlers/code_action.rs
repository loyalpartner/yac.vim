use anyhow::Result;
use async_trait::async_trait;
use lsp_bridge::LspRegistry;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tracing::debug;
use vim::{Handler, HandlerResult};

#[derive(Debug, Deserialize)]
#[allow(dead_code)]
pub struct CodeActionRequest {
    pub file: String,
    pub start_line: u32,
    pub start_column: u32,
    pub end_line: u32,
    pub end_column: u32,
    pub context: Option<CodeActionContext>,
}

#[derive(Debug, Deserialize)]
pub struct CodeActionContext {
    #[allow(dead_code)]
    pub diagnostics: Vec<String>, // Simplified - just diagnostic messages
    pub only: Option<Vec<String>>, // Filter by action kinds
}

#[derive(Debug, Serialize)]
pub struct CodeAction {
    pub title: String,
    pub kind: Option<String>,
    pub diagnostics: Option<Vec<String>>,
    pub edit: Option<WorkspaceEdit>,
    pub command: Option<Command>,
    pub is_preferred: Option<bool>,
}

#[derive(Debug, Serialize)]
pub struct WorkspaceEdit {
    pub edits: Vec<TextEdit>,
}

#[derive(Debug, Serialize)]
pub struct TextEdit {
    pub file: String,
    pub start_line: u32,
    pub start_column: u32,
    pub end_line: u32,
    pub end_column: u32,
    pub new_text: String,
}

#[derive(Debug, Serialize)]
pub struct Command {
    pub title: String,
    pub command: String,
    pub arguments: Option<Vec<serde_json::Value>>,
}

#[derive(Debug, Serialize)]
pub struct CodeActionInfo {
    pub actions: Vec<CodeAction>,
}

pub type CodeActionResponse = CodeActionInfo;

impl TextEdit {
    pub fn new(
        file: String,
        start_line: u32,
        start_column: u32,
        end_line: u32,
        end_column: u32,
        new_text: String,
    ) -> Self {
        Self {
            file,
            start_line,
            start_column,
            end_line,
            end_column,
            new_text,
        }
    }
}

impl WorkspaceEdit {
    pub fn new(edits: Vec<TextEdit>) -> Self {
        Self { edits }
    }
}

impl Command {
    pub fn new(title: String, command: String, arguments: Option<Vec<serde_json::Value>>) -> Self {
        Self {
            title,
            command,
            arguments,
        }
    }
}

impl CodeAction {
    pub fn new(
        title: String,
        kind: Option<String>,
        diagnostics: Option<Vec<String>>,
        edit: Option<WorkspaceEdit>,
        command: Option<Command>,
        is_preferred: Option<bool>,
    ) -> Self {
        Self {
            title,
            kind,
            diagnostics,
            edit,
            command,
            is_preferred,
        }
    }
}

impl CodeActionInfo {
    pub fn new(actions: Vec<CodeAction>) -> Self {
        Self { actions }
    }
}

pub struct CodeActionHandler {
    lsp_registry: Arc<LspRegistry>,
}

impl CodeActionHandler {
    pub fn new(registry: Arc<LspRegistry>) -> Self {
        Self {
            lsp_registry: registry,
        }
    }

    fn code_action_kind_to_string(kind: Option<lsp_types::CodeActionKind>) -> Option<String> {
        kind.map(|k| k.as_str().to_string())
    }

    fn convert_workspace_edit(edit: lsp_types::WorkspaceEdit) -> Option<WorkspaceEdit> {
        let mut text_edits = Vec::new();

        // Handle changes map
        if let Some(changes) = edit.changes {
            for (uri, edits) in changes {
                let file_path = match uri.to_file_path() {
                    Ok(path) => path.to_string_lossy().to_string(),
                    Err(_) => continue,
                };

                for text_edit in edits {
                    text_edits.push(TextEdit::new(
                        file_path.clone(),
                        text_edit.range.start.line,
                        text_edit.range.start.character,
                        text_edit.range.end.line,
                        text_edit.range.end.character,
                        text_edit.new_text,
                    ));
                }
            }
        }

        // Handle document changes
        if let Some(document_changes) = edit.document_changes {
            match document_changes {
                lsp_types::DocumentChanges::Edits(edits) => {
                    for edit in edits {
                        let file_path = match edit.text_document.uri.to_file_path() {
                            Ok(path) => path.to_string_lossy().to_string(),
                            Err(_) => continue,
                        };

                        for text_edit in edit.edits {
                            let lsp_types::OneOf::Left(text_edit) = text_edit else {
                                continue; // Skip complex AnnotatedTextEdit
                            };

                            text_edits.push(TextEdit::new(
                                file_path.clone(),
                                text_edit.range.start.line,
                                text_edit.range.start.character,
                                text_edit.range.end.line,
                                text_edit.range.end.character,
                                text_edit.new_text,
                            ));
                        }
                    }
                }
                lsp_types::DocumentChanges::Operations(_) => {
                    // Skip file operations for now
                }
            }
        }

        if text_edits.is_empty() {
            None
        } else {
            Some(WorkspaceEdit::new(text_edits))
        }
    }

    fn convert_command(command: lsp_types::Command) -> Command {
        Command::new(command.title, command.command, command.arguments)
    }
}

#[async_trait]
impl Handler for CodeActionHandler {
    type Input = CodeActionRequest;
    type Output = CodeActionResponse;

    async fn handle(
        &self,
        _vim: &dyn vim::VimContext,
        input: Self::Input,
    ) -> Result<HandlerResult<Self::Output>> {
        // Detect language
        let language = match self.lsp_registry.detect_language(&input.file) {
            Some(lang) => lang,
            None => return Ok(HandlerResult::Empty),
        };

        // Ensure client exists
        if self
            .lsp_registry
            .get_client(&language, &input.file)
            .await
            .is_err()
        {
            return Ok(HandlerResult::Empty);
        }

        // Convert file path to URI
        let uri = match super::common::file_path_to_uri(&input.file) {
            Ok(uri) => uri,
            Err(_) => return Ok(HandlerResult::Empty),
        };

        // Make LSP code action request
        let params = lsp_types::CodeActionParams {
            text_document: lsp_types::TextDocumentIdentifier {
                uri: lsp_types::Url::parse(&uri)?,
            },
            range: lsp_types::Range {
                start: lsp_types::Position {
                    line: input.start_line,
                    character: input.start_column,
                },
                end: lsp_types::Position {
                    line: input.end_line,
                    character: input.end_column,
                },
            },
            context: lsp_types::CodeActionContext {
                diagnostics: Vec::new(), // TODO: Convert from input.context.diagnostics
                only: input.context.and_then(|ctx| {
                    ctx.only.map(|kinds| {
                        kinds
                            .into_iter()
                            .map(lsp_types::CodeActionKind::from)
                            .collect()
                    })
                }),
                trigger_kind: None,
            },
            work_done_progress_params: Default::default(),
            partial_result_params: Default::default(),
        };

        let response = match self
            .lsp_registry
            .request::<lsp_types::request::CodeActionRequest>(&language, params)
            .await
        {
            Ok(response) => response,
            Err(_) => return Ok(HandlerResult::Empty),
        };

        debug!("code action response: {:?}", response);

        let actions = match response {
            Some(actions) => actions,
            None => return Ok(HandlerResult::Empty),
        };

        if actions.is_empty() {
            return Ok(HandlerResult::Empty);
        }

        // Convert code actions
        let result_actions: Vec<CodeAction> = actions
            .into_iter()
            .map(|action| match action {
                lsp_types::CodeActionOrCommand::CodeAction(action) => {
                    let edit = action.edit.and_then(Self::convert_workspace_edit);
                    let command = action.command.map(Self::convert_command);

                    CodeAction::new(
                        action.title,
                        Self::code_action_kind_to_string(action.kind),
                        None, // TODO: Convert diagnostics
                        edit,
                        command,
                        action.is_preferred,
                    )
                }
                lsp_types::CodeActionOrCommand::Command(command) => {
                    let cmd = Self::convert_command(command);
                    CodeAction::new(
                        cmd.title.clone(),
                        Some("command".to_string()),
                        None,
                        None,
                        Some(cmd),
                        None,
                    )
                }
            })
            .collect();

        if result_actions.is_empty() {
            return Ok(HandlerResult::Empty);
        }

        Ok(HandlerResult::Data(CodeActionInfo::new(result_actions)))
    }
}
