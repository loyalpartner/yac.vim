use anyhow::Result;
use async_trait::async_trait;
use lsp_bridge::LspRegistry;
use serde::Deserialize;
use serde_json::json;
use std::sync::Arc;
use tracing::debug;
use vim::Handler;

use super::common::{extract_ssh_path, restore_ssh_path, with_lsp_context, HasFilePosition, Location};

#[derive(Debug, Deserialize)]
#[allow(dead_code)]
pub struct GotoRequest {
    pub file: String,
    pub line: u32,
    pub column: u32,
    #[serde(default)]
    pub command: Option<String>,
}

impl HasFilePosition for GotoRequest {
    fn file(&self) -> &str {
        &self.file
    }
    fn line(&self) -> u32 {
        self.line
    }
    fn column(&self) -> u32 {
        self.column
    }
}

#[derive(Debug, Clone)]
pub enum GotoType {
    Definition,
    Declaration,
    TypeDefinition,
    Implementation,
}

impl GotoType {
    fn from_method(method: &str) -> Option<Self> {
        match method {
            "goto_definition" => Some(Self::Definition),
            "goto_declaration" => Some(Self::Declaration),
            "goto_type_definition" => Some(Self::TypeDefinition),
            "goto_implementation" => Some(Self::Implementation),
            _ => None,
        }
    }
}

pub type GotoResponse = Option<Location>;

pub struct GotoHandler {
    lsp_registry: Arc<LspRegistry>,
    goto_type: GotoType,
}

impl GotoHandler {
    pub fn new(registry: Arc<LspRegistry>, method: &str) -> Option<Self> {
        GotoType::from_method(method).map(|goto_type| Self {
            lsp_registry: registry,
            goto_type,
        })
    }
}

#[async_trait]
impl Handler for GotoHandler {
    type Input = GotoRequest;
    type Output = GotoResponse;

    async fn handle(
        &self,
        vim: &dyn vim::VimContext,
        input: Self::Input,
    ) -> Result<Option<Self::Output>> {
        // Save original file path for SSH path restoration
        let original_file = input.file.clone();
        let goto_type = self.goto_type.clone();

        with_lsp_context(&self.lsp_registry, input, |ctx, input| async move {
            let text_document_position = lsp_types::TextDocumentPositionParams {
                text_document: lsp_types::TextDocumentIdentifier { uri: ctx.uri },
                position: lsp_types::Position {
                    line: input.line,
                    character: input.column,
                },
            };

            let response = match goto_type {
                GotoType::Definition => {
                    let params = lsp_types::GotoDefinitionParams {
                        text_document_position_params: text_document_position,
                        work_done_progress_params: Default::default(),
                        partial_result_params: Default::default(),
                    };
                    ctx.registry
                        .request::<lsp_types::request::GotoDefinition>(&ctx.language, params)
                        .await
                }
                GotoType::Declaration => {
                    let params = lsp_types::GotoDefinitionParams {
                        text_document_position_params: text_document_position,
                        work_done_progress_params: Default::default(),
                        partial_result_params: Default::default(),
                    };
                    ctx.registry
                        .request::<lsp_types::request::GotoDeclaration>(&ctx.language, params)
                        .await
                }
                GotoType::TypeDefinition => {
                    let params = lsp_types::request::GotoTypeDefinitionParams {
                        text_document_position_params: text_document_position,
                        work_done_progress_params: Default::default(),
                        partial_result_params: Default::default(),
                    };
                    ctx.registry
                        .request::<lsp_types::request::GotoTypeDefinition>(&ctx.language, params)
                        .await
                }
                GotoType::Implementation => {
                    let params = lsp_types::request::GotoImplementationParams {
                        text_document_position_params: text_document_position,
                        work_done_progress_params: Default::default(),
                        partial_result_params: Default::default(),
                    };
                    ctx.registry
                        .request::<lsp_types::request::GotoImplementation>(&ctx.language, params)
                        .await
                }
            };

            let location_result = match response {
                Ok(Some(response_data)) => match response_data {
                    lsp_types::GotoDefinitionResponse::Scalar(location) => Some(location),
                    lsp_types::GotoDefinitionResponse::Array(locations) => locations.first().cloned(),
                    lsp_types::GotoDefinitionResponse::Link(links) => {
                        links.first().map(|link| lsp_types::Location {
                            uri: link.target_uri.clone(),
                            range: link.target_selection_range,
                        })
                    }
                },
                _ => None,
            };

            debug!("{:?} response: {:?}", goto_type, location_result);

            if let Some(lsp_location) = location_result {
                if let Ok(location) = Location::from_lsp_location(lsp_location) {
                    debug!("location: {:?}", location);

                    let (ssh_host, _) = extract_ssh_path(&original_file);
                    let file_path = restore_ssh_path(&location.file, ssh_host.as_deref());

                    vim.ex(format!("edit {}", file_path).as_str()).await.ok();
                    vim.call(
                        "cursor",
                        vec![json!(location.line + 1), json!(location.column + 1)],
                    )
                    .await
                    .ok();
                }
            }

            Ok(None)
        })
        .await
    }
}
