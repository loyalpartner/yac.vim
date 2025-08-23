use anyhow::Result;
use async_trait::async_trait;
use lsp_client::LspClient;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tokio::sync::Mutex;
use vim::Handler;

#[derive(Debug, Deserialize)]
#[allow(dead_code)]
pub struct FileOpenRequest {
    pub command: String,
    pub file: String,
    pub line: u32,
    pub column: u32,
}

#[derive(Debug, Serialize)]
pub struct FileOpenResponse {
    pub action: String,
    pub message: Option<String>,
}

impl FileOpenResponse {
    pub fn success() -> Self {
        Self {
            action: "none".to_string(),
            message: None,
        }
    }

    pub fn error(message: String) -> Self {
        Self {
            action: "error".to_string(),
            message: Some(message),
        }
    }
}

pub struct FileOpenHandler {
    lsp_client: Arc<Mutex<Option<LspClient>>>,
}

impl FileOpenHandler {
    pub fn new(client: Arc<Mutex<Option<LspClient>>>) -> Self {
        Self { lsp_client: client }
    }

    async fn init_client(&self, file_path: &str) -> Result<()> {
        let mut client_opt = self.lsp_client.lock().await;
        if client_opt.is_none() {
            let client = self.create_rust_analyzer_client(file_path).await?;
            *client_opt = Some(client);
        }
        Ok(())
    }

    async fn create_rust_analyzer_client(&self, file_path: &str) -> Result<LspClient> {
        use lsp_types::{
            request::Initialize, ClientCapabilities, InitializeParams, InitializedParams,
            WorkspaceFolder,
        };

        let client = LspClient::new("rust-analyzer", &[]).await?;
        let workspace_root = self.find_workspace_root(file_path);

        #[allow(deprecated)]
        let params = InitializeParams {
            process_id: Some(std::process::id()),
            root_path: None,
            root_uri: Some(workspace_root.clone()),
            initialization_options: None,
            capabilities: ClientCapabilities::default(),
            trace: None,
            workspace_folders: Some(vec![WorkspaceFolder {
                uri: workspace_root,
                name: "workspace".to_string(),
            }]),
            client_info: None,
            locale: None,
        };

        client.request::<Initialize>(params).await?;
        client.notify("initialized", InitializedParams {}).await?;
        Ok(client)
    }

    fn find_workspace_root(&self, file_path: &str) -> lsp_types::Url {
        let mut path = std::path::Path::new(file_path);
        while let Some(parent) = path.parent() {
            if parent.join("Cargo.toml").exists() {
                return lsp_types::Url::from_file_path(parent).unwrap();
            }
            path = parent;
        }
        // Fallback to file directory
        lsp_types::Url::from_file_path(
            std::path::Path::new(file_path)
                .parent()
                .unwrap_or_else(|| std::path::Path::new(".")),
        )
        .unwrap()
    }

    async fn open_file(&self, client: &LspClient, file_path: &str) -> Result<()> {
        use lsp_types::{DidOpenTextDocumentParams, TextDocumentItem};

        let text = std::fs::read_to_string(file_path)?;
        let uri = super::common::file_path_to_uri(file_path)?;

        let params = DidOpenTextDocumentParams {
            text_document: TextDocumentItem {
                uri: lsp_types::Url::parse(&uri)?,
                language_id: "rust".to_string(),
                version: 1,
                text,
            },
        };

        client.notify("textDocument/didOpen", params).await?;
        Ok(())
    }
}

#[async_trait]
impl Handler for FileOpenHandler {
    type Input = FileOpenRequest;
    type Output = FileOpenResponse;

    async fn handle(
        &self,
        _ctx: &mut dyn vim::VimContext,
        input: Self::Input,
    ) -> Result<Option<Self::Output>> {
        // Ensure LSP client is initialized
        if let Err(e) = self.init_client(&input.file).await {
            return Ok(Some(FileOpenResponse::error(format!(
                "Failed to initialize LSP client: {}",
                e
            ))));
        }

        let client_lock = self.lsp_client.lock().await;
        let client = client_lock.as_ref().unwrap();

        // Open file in LSP
        if let Err(e) = self.open_file(client, &input.file).await {
            return Ok(Some(FileOpenResponse::error(format!(
                "Failed to open file: {}",
                e
            ))));
        }

        Ok(Some(FileOpenResponse::success()))
    }
}
