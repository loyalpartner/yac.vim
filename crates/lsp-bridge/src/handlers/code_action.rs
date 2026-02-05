use anyhow::Result;
use async_trait::async_trait;
use lsp_bridge::LspRegistry;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tracing::debug;
use vim::{Handler, HandlerResult};

use super::common::{with_lsp_file, HasFile};

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

impl HasFile for CodeActionRequest {
    fn file(&self) -> &str {
        &self.file
    }
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

use super::common::{convert_workspace_edit, FileTextEdit};

#[derive(Debug, Serialize)]
pub struct WorkspaceEdit {
    pub edits: Vec<FileTextEdit>,
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

impl WorkspaceEdit {
    pub fn new(edits: Vec<FileTextEdit>) -> Self {
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

    fn lsp_workspace_edit_to_edit(edit: lsp_types::WorkspaceEdit) -> Option<WorkspaceEdit> {
        let edits = convert_workspace_edit(edit);
        if edits.is_empty() {
            None
        } else {
            Some(WorkspaceEdit::new(edits))
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
        with_lsp_file(&self.lsp_registry, input, |ctx, input| async move {
            let params = lsp_types::CodeActionParams {
                text_document: lsp_types::TextDocumentIdentifier { uri: ctx.uri },
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
                    diagnostics: Vec::new(),
                    only: input.context.and_then(|c| {
                        c.only.map(|kinds| {
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

            let response = match ctx
                .registry
                .request::<lsp_types::request::CodeActionRequest>(&ctx.language, params)
                .await
            {
                Ok(response) => response,
                Err(_) => return Ok(HandlerResult::Empty),
            };

            debug!("code action response: {:?}", response);

            let actions = match response {
                Some(actions) if !actions.is_empty() => actions,
                _ => return Ok(HandlerResult::Empty),
            };

            let result_actions: Vec<CodeAction> = actions
                .into_iter()
                .map(|action| match action {
                    lsp_types::CodeActionOrCommand::CodeAction(action) => {
                        let edit =
                            action.edit.and_then(CodeActionHandler::lsp_workspace_edit_to_edit);
                        let command = action.command.map(CodeActionHandler::convert_command);

                        CodeAction::new(
                            action.title,
                            CodeActionHandler::code_action_kind_to_string(action.kind),
                            None,
                            edit,
                            command,
                            action.is_preferred,
                        )
                    }
                    lsp_types::CodeActionOrCommand::Command(command) => {
                        let cmd = CodeActionHandler::convert_command(command);
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
        })
        .await
    }
}
