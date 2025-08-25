use anyhow::Result;
use lsp_client::LspClient;
use lsp_types::{
    request::Initialize, ClientCapabilities, CompletionClientCapabilities,
    CompletionItemCapability, InitializeParams, MarkupKind, TextDocumentClientCapabilities,
    WorkspaceFolder,
};
use serde::{Deserialize, Serialize};
use std::{collections::HashMap, path::Path, sync::Arc};
use tokio::sync::Mutex;
use tracing::{debug, info, warn};

/// Language server configuration - Linus style: data-driven approach
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LspServerConfig {
    pub command: String,
    pub args: Vec<String>,
    pub language_id: String,
    pub file_patterns: Vec<String>,
    pub workspace_patterns: Vec<String>,
}

impl LspServerConfig {
    pub fn rust_analyzer() -> Self {
        Self {
            command: "rust-analyzer".to_string(),
            args: vec![],
            language_id: "rust".to_string(),
            file_patterns: vec!["*.rs".to_string()],
            workspace_patterns: vec!["Cargo.toml".to_string()],
        }
    }

    pub fn pyright() -> Self {
        Self {
            command: "pyright-langserver".to_string(),
            args: vec!["--stdio".to_string()],
            language_id: "python".to_string(),
            file_patterns: vec!["*.py".to_string()],
            workspace_patterns: vec!["pyproject.toml".to_string(), "setup.py".to_string()],
        }
    }

    pub fn typescript_language_server() -> Self {
        Self {
            command: "typescript-language-server".to_string(),
            args: vec!["--stdio".to_string()],
            language_id: "typescript".to_string(),
            file_patterns: vec!["*.ts".to_string(), "*.js".to_string(), "*.tsx".to_string()],
            workspace_patterns: vec!["package.json".to_string(), "tsconfig.json".to_string()],
        }
    }

    pub fn gopls() -> Self {
        Self {
            command: "gopls".to_string(),
            args: vec![],
            language_id: "go".to_string(),
            file_patterns: vec!["*.go".to_string()],
            workspace_patterns: vec!["go.mod".to_string()],
        }
    }

    /// Check if this config handles the given file
    pub fn handles_file(&self, file_path: &str) -> bool {
        let file_name = Path::new(file_path)
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("");

        self.file_patterns.iter().any(|pattern| {
            // Simple glob matching - could be enhanced with proper glob library
            if let Some(extension) = pattern.strip_prefix("*.") {
                file_name.ends_with(extension)
            } else {
                file_name == pattern
            }
        })
    }

    /// Find workspace root for this language server
    pub fn find_workspace_root(&self, file_path: &str) -> Option<lsp_types::Url> {
        let mut path = Path::new(file_path);

        while let Some(parent) = path.parent() {
            for pattern in &self.workspace_patterns {
                if parent.join(pattern).exists() {
                    return lsp_types::Url::from_file_path(parent).ok();
                }
            }
            path = parent;
        }

        // Fallback to file directory
        lsp_types::Url::from_file_path(
            Path::new(file_path)
                .parent()
                .unwrap_or_else(|| Path::new(".")),
        )
        .ok()
    }
}

/// Multi-language LSP client registry
/// Linus style: "good taste" - let data structures eliminate complexity
pub struct LspRegistry {
    // Map of language -> LSP client
    clients: Arc<Mutex<HashMap<String, LspClient>>>,
    // Available server configurations
    configs: HashMap<String, LspServerConfig>,
}

impl Default for LspRegistry {
    fn default() -> Self {
        Self::new()
    }
}

impl LspRegistry {
    pub fn new() -> Self {
        let mut configs = HashMap::new();

        // Register built-in language servers
        configs.insert("rust".to_string(), LspServerConfig::rust_analyzer());
        configs.insert("python".to_string(), LspServerConfig::pyright());
        configs.insert(
            "typescript".to_string(),
            LspServerConfig::typescript_language_server(),
        );
        configs.insert(
            "javascript".to_string(),
            LspServerConfig::typescript_language_server(),
        );
        configs.insert("go".to_string(), LspServerConfig::gopls());

        Self {
            clients: Arc::new(Mutex::new(HashMap::new())),
            configs,
        }
    }

    /// Detect language from file path
    pub fn detect_language(&self, file_path: &str) -> Option<String> {
        // Simple extension-based detection
        if file_path.ends_with(".rs") {
            Some("rust".to_string())
        } else if file_path.ends_with(".py") {
            Some("python".to_string())
        } else if file_path.ends_with(".ts") {
            Some("typescript".to_string())
        } else if file_path.ends_with(".js") {
            Some("javascript".to_string())
        } else if file_path.ends_with(".go") {
            Some("go".to_string())
        } else {
            None
        }
    }

    /// Get or create LSP client for a language
    pub async fn get_client(&self, language: &str, file_path: &str) -> Result<()> {
        let mut clients = self.clients.lock().await;

        if clients.contains_key(language) {
            // Client already exists
            debug!("Using existing {} language server", language);
            return Ok(());
        }

        // Create new client
        let config = self
            .configs
            .get(language)
            .ok_or_else(|| anyhow::anyhow!("Unsupported language: {}", language))?;

        info!("Creating new {} language server", language);
        let client = self.create_client(config, file_path).await?;
        clients.insert(language.to_string(), client);

        Ok(())
    }

    /// Create a new LSP client for the given configuration
    async fn create_client(&self, config: &LspServerConfig, file_path: &str) -> Result<LspClient> {
        let args: Vec<&str> = config.args.iter().map(|s| s.as_str()).collect();
        let client = LspClient::new(&config.command, &args).await?;
        let workspace_root = config.find_workspace_root(file_path);

        debug!(
            "Initializing {} with workspace: {:?}",
            config.command, workspace_root
        );
        debug!("LSP client capabilities include completion resolve support");

        // Create proper client capabilities for auto-import support
        let capabilities = ClientCapabilities {
            text_document: Some(TextDocumentClientCapabilities {
                completion: Some(CompletionClientCapabilities {
                    dynamic_registration: Some(false),
                    completion_item: Some(CompletionItemCapability {
                        snippet_support: Some(true),
                        commit_characters_support: Some(true),
                        documentation_format: Some(vec![
                            MarkupKind::Markdown,
                            MarkupKind::PlainText,
                        ]),
                        deprecated_support: Some(true),
                        preselect_support: Some(true),
                        tag_support: None,
                        insert_replace_support: Some(true),
                        resolve_support: Some(lsp_types::CompletionItemCapabilityResolveSupport {
                            properties: vec![
                                "documentation".to_string(),
                                "detail".to_string(),
                                "additionalTextEdits".to_string(),
                            ],
                        }),
                        insert_text_mode_support: None,
                        label_details_support: Some(true),
                    }),
                    completion_item_kind: None,
                    context_support: Some(true),
                    insert_text_mode: None,
                    completion_list: None,
                }),
                ..Default::default()
            }),
            ..Default::default()
        };

        #[allow(deprecated)]
        let params = InitializeParams {
            process_id: Some(std::process::id()),
            root_path: None,
            root_uri: workspace_root.clone(),
            initialization_options: None,
            capabilities,
            trace: None,
            workspace_folders: workspace_root.map(|uri| {
                vec![WorkspaceFolder {
                    uri: uri.clone(),
                    name: Path::new(file_path)
                        .parent()
                        .and_then(|p| p.file_name())
                        .and_then(|name| name.to_str())
                        .unwrap_or("workspace")
                        .to_string(),
                }]
            }),
            client_info: None,
            locale: None,
        };

        client.request::<Initialize>(params).await?;
        client
            .notify("initialized", lsp_types::InitializedParams {})
            .await?;

        info!(
            "Successfully initialized {} language server",
            config.language_id
        );
        Ok(client)
    }

    /// Open a file in the appropriate language server
    pub async fn open_file(&self, file_path: &str) -> Result<()> {
        self.open_file_with_content(file_path, None).await
    }

    /// Open a file with optional content override (for new buffers)
    pub async fn open_file_with_content(
        &self,
        file_path: &str,
        content: Option<&str>,
    ) -> Result<()> {
        let language = self
            .detect_language(file_path)
            .ok_or_else(|| anyhow::anyhow!("Unsupported file type: {}", file_path))?;

        // Ensure client exists
        self.get_client(&language, file_path).await?;

        // Use provided content or read from disk
        let text = if let Some(content) = content {
            debug!("Using provided buffer content for {}", file_path);
            content.to_string()
        } else {
            std::fs::read_to_string(file_path).unwrap_or_else(|_| {
                debug!(
                    "File {} doesn't exist on disk yet, using empty content",
                    file_path
                );
                String::new()
            })
        };

        let uri = lsp_types::Url::from_file_path(file_path)
            .map_err(|_| anyhow::anyhow!("Invalid file path: {}", file_path))?;

        let config = self.configs.get(&language).unwrap(); // Safe because we got it from detect_language

        let params = lsp_types::DidOpenTextDocumentParams {
            text_document: lsp_types::TextDocumentItem {
                uri,
                language_id: config.language_id.clone(),
                version: 1,
                text,
            },
        };

        // Execute the notification through the registry
        self.notify(&language, "textDocument/didOpen", params)
            .await?;

        debug!("Opened {} in {} language server", file_path, language);
        Ok(())
    }

    /// Execute a notification with the client for a specific language
    pub async fn notify<T>(&self, language: &str, method: &str, params: T) -> Result<()>
    where
        T: serde::Serialize,
    {
        let clients = self.clients.lock().await;
        let client = clients
            .get(language)
            .ok_or_else(|| anyhow::anyhow!("No client for language: {}", language))?;

        client
            .notify(method, params)
            .await
            .map_err(|e| anyhow::anyhow!("{}", e))
    }

    /// Execute a request with the client for a specific language
    pub async fn request<R>(&self, language: &str, params: R::Params) -> Result<R::Result>
    where
        R: lsp_types::request::Request,
        R::Params: serde::Serialize + Send + 'static,
        R::Result: serde::de::DeserializeOwned,
    {
        let clients = self.clients.lock().await;
        let client = clients
            .get(language)
            .ok_or_else(|| anyhow::anyhow!("No client for language: {}", language))?;

        client
            .request::<R>(params)
            .await
            .map_err(|e| anyhow::anyhow!("{}", e))
    }

    /// Get client for a specific language (if it exists)
    pub async fn get_existing_client(&self, language: &str) -> bool {
        let clients = self.clients.lock().await;
        clients.contains_key(language)
    }

    /// Shutdown a language server
    pub async fn shutdown_language(&self, language: &str) -> Result<()> {
        let mut clients = self.clients.lock().await;
        if let Some(client) = clients.remove(language) {
            // Send shutdown request
            match client.request::<lsp_types::request::Shutdown>(()).await {
                Ok(_) => {
                    // Send exit notification
                    client.notify("exit", ()).await.ok();
                    info!("Shut down {} language server", language);
                }
                Err(e) => {
                    warn!("Failed to shutdown {} language server: {}", language, e);
                }
            }
        }
        Ok(())
    }

    /// Shutdown all language servers
    pub async fn shutdown_all(&self) -> Result<()> {
        let languages: Vec<String> = {
            let clients = self.clients.lock().await;
            clients.keys().cloned().collect()
        };

        for language in languages {
            self.shutdown_language(&language).await.ok();
        }
        Ok(())
    }

    /// List active language servers
    pub async fn list_active_languages(&self) -> Vec<String> {
        let clients = self.clients.lock().await;
        clients.keys().cloned().collect()
    }

    /// Add a custom language server configuration
    pub fn add_language_config(&mut self, language: String, config: LspServerConfig) {
        self.configs.insert(language, config);
    }

    /// Get supported languages
    pub fn supported_languages(&self) -> Vec<&String> {
        self.configs.keys().collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_language_detection() {
        let registry = LspRegistry::new();

        assert_eq!(
            registry.detect_language("test.rs"),
            Some("rust".to_string())
        );
        assert_eq!(
            registry.detect_language("test.py"),
            Some("python".to_string())
        );
        assert_eq!(
            registry.detect_language("test.ts"),
            Some("typescript".to_string())
        );
        assert_eq!(
            registry.detect_language("test.js"),
            Some("javascript".to_string())
        );
        assert_eq!(registry.detect_language("test.go"), Some("go".to_string()));
        assert_eq!(registry.detect_language("test.txt"), None);
    }

    #[test]
    fn test_file_pattern_matching() {
        let config = LspServerConfig::rust_analyzer();
        assert!(config.handles_file("/path/to/file.rs"));
        assert!(!config.handles_file("/path/to/file.py"));
    }

    #[test]
    fn test_workspace_detection() {
        // This would need actual filesystem setup for proper testing
        // For now, just test the basic structure
        let config = LspServerConfig::rust_analyzer();
        assert_eq!(config.workspace_patterns, vec!["Cargo.toml"]);
    }
}
