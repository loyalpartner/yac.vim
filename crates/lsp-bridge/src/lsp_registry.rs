use crate::{LspBridgeError, Result};
use lsp_client::LspClient;
use lsp_types::{request::Initialize, InitializeParams, WorkspaceFolder};
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
            file_patterns: vec!["*.ts".to_string(), "*.tsx".to_string()],
            workspace_patterns: vec!["package.json".to_string(), "tsconfig.json".to_string()],
        }
    }

    pub fn javascript_language_server() -> Self {
        Self {
            command: "typescript-language-server".to_string(),
            args: vec!["--stdio".to_string()],
            language_id: "javascript".to_string(),
            file_patterns: vec!["*.js".to_string(), "*.jsx".to_string()],
            workspace_patterns: vec!["package.json".to_string()],
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
            if let Some(extension) = pattern.strip_prefix('*') {
                // extension includes the dot, e.g. ".rs"
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
    // Map of language -> LSP client (Arc allows clone-and-release to avoid holding lock during requests)
    clients: Arc<Mutex<HashMap<String, Arc<LspClient>>>>,
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
        let mut configs = Self::builtin_configs();

        // User config overrides builtins
        if let Some(user_configs) = Self::load_user_configs() {
            for (lang, config) in user_configs {
                configs.insert(lang, config);
            }
        }

        Self {
            clients: Arc::new(Mutex::new(HashMap::new())),
            configs,
        }
    }

    fn builtin_configs() -> HashMap<String, LspServerConfig> {
        let mut configs = HashMap::new();
        configs.insert("rust".to_string(), LspServerConfig::rust_analyzer());
        configs.insert("python".to_string(), LspServerConfig::pyright());
        configs.insert(
            "typescript".to_string(),
            LspServerConfig::typescript_language_server(),
        );
        configs.insert(
            "javascript".to_string(),
            LspServerConfig::javascript_language_server(),
        );
        configs.insert("go".to_string(), LspServerConfig::gopls());
        configs
    }

    /// Load user configs from ~/.config/yac/servers.json
    fn load_user_configs() -> Option<HashMap<String, LspServerConfig>> {
        let home = std::env::var("HOME").ok()?;
        let config_path = Path::new(&home).join(".config/yac/servers.json");
        let content = std::fs::read_to_string(&config_path).ok()?;
        match serde_json::from_str(&content) {
            Ok(configs) => {
                info!("Loaded user config from {}", config_path.display());
                Some(configs)
            }
            Err(e) => {
                warn!("Failed to parse {}: {}", config_path.display(), e);
                None
            }
        }
    }

    /// Detect language from file path - data-driven via configs
    pub fn detect_language(&self, file_path: &str) -> Option<String> {
        self.configs
            .iter()
            .find(|(_, config)| config.handles_file(file_path))
            .map(|(lang, _)| lang.clone())
    }

    /// Get or create LSP client for a language, returns Arc for lock-free usage
    pub async fn get_client(&self, language: &str, file_path: &str) -> Result<Arc<LspClient>> {
        // Fast path: client already exists, clone Arc and release lock immediately
        {
            let clients = self.clients.lock().await;
            if let Some(client) = clients.get(language) {
                debug!("Using existing {} language server", language);
                return Ok(client.clone());
            }
        }

        // Slow path: create new client (lock released during LSP server startup)
        let config = self
            .configs
            .get(language)
            .ok_or_else(|| LspBridgeError::UnsupportedLanguage(language.to_string()))?;

        info!("Creating new {} language server", language);
        let client = Arc::new(self.create_client(config, file_path).await?);

        let mut clients = self.clients.lock().await;
        clients.insert(language.to_string(), client.clone());
        Ok(client)
    }

    /// Build client capabilities matching the features we actually implement
    fn client_capabilities() -> lsp_types::ClientCapabilities {
        use lsp_types::*;

        ClientCapabilities {
            text_document: Some(TextDocumentClientCapabilities {
                completion: Some(CompletionClientCapabilities {
                    completion_item: Some(CompletionItemCapability {
                        documentation_format: Some(vec![
                            MarkupKind::Markdown,
                            MarkupKind::PlainText,
                        ]),
                        snippet_support: Some(false),
                        ..Default::default()
                    }),
                    ..Default::default()
                }),
                hover: Some(HoverClientCapabilities {
                    content_format: Some(vec![MarkupKind::Markdown, MarkupKind::PlainText]),
                    ..Default::default()
                }),
                definition: Some(GotoCapability {
                    link_support: Some(false),
                    ..Default::default()
                }),
                declaration: Some(GotoCapability {
                    link_support: Some(false),
                    ..Default::default()
                }),
                type_definition: Some(GotoCapability {
                    link_support: Some(false),
                    ..Default::default()
                }),
                implementation: Some(GotoCapability {
                    link_support: Some(false),
                    ..Default::default()
                }),
                references: Some(DynamicRegistrationClientCapabilities {
                    dynamic_registration: Some(false),
                }),
                rename: Some(RenameClientCapabilities {
                    prepare_support: Some(false),
                    ..Default::default()
                }),
                code_action: Some(CodeActionClientCapabilities {
                    code_action_literal_support: Some(CodeActionLiteralSupport {
                        code_action_kind: CodeActionKindLiteralSupport {
                            value_set: vec![
                                CodeActionKind::QUICKFIX.as_str().to_string(),
                                CodeActionKind::REFACTOR.as_str().to_string(),
                                CodeActionKind::SOURCE.as_str().to_string(),
                            ],
                        },
                    }),
                    ..Default::default()
                }),
                document_symbol: Some(DocumentSymbolClientCapabilities {
                    hierarchical_document_symbol_support: Some(true),
                    ..Default::default()
                }),
                publish_diagnostics: Some(PublishDiagnosticsClientCapabilities {
                    related_information: Some(true),
                    ..Default::default()
                }),
                synchronization: Some(TextDocumentSyncClientCapabilities {
                    did_save: Some(true),
                    will_save: Some(true),
                    ..Default::default()
                }),
                inlay_hint: Some(InlayHintClientCapabilities {
                    ..Default::default()
                }),
                call_hierarchy: Some(CallHierarchyClientCapabilities {
                    ..Default::default()
                }),
                folding_range: Some(FoldingRangeClientCapabilities {
                    ..Default::default()
                }),
                ..Default::default()
            }),
            workspace: Some(WorkspaceClientCapabilities {
                apply_edit: Some(true),
                workspace_edit: Some(WorkspaceEditClientCapabilities {
                    document_changes: Some(true),
                    ..Default::default()
                }),
                ..Default::default()
            }),
            ..Default::default()
        }
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

        #[allow(deprecated)]
        let params = InitializeParams {
            process_id: Some(std::process::id()),
            root_path: None,
            root_uri: workspace_root.clone(),
            initialization_options: None,
            capabilities: Self::client_capabilities(),
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
            client_info: Some(lsp_types::ClientInfo {
                name: "yac.vim".to_string(),
                version: Some(env!("CARGO_PKG_VERSION").to_string()),
            }),
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
    /// Handles SSH paths (scp://host//path) transparently
    pub async fn open_file(&self, file_path: &str) -> Result<()> {
        let real_path = Self::extract_real_path(file_path);

        let language = self
            .detect_language(&real_path)
            .ok_or_else(|| LspBridgeError::UnsupportedFileType(file_path.to_string()))?;

        let client = self.get_client(&language, &real_path).await?;

        let text = tokio::fs::read_to_string(&real_path).await?;
        let uri = lsp_types::Url::from_file_path(&real_path)
            .map_err(|_| LspBridgeError::InvalidFilePath(file_path.to_string()))?;

        let config = self
            .configs
            .get(&language)
            .ok_or_else(|| LspBridgeError::UnsupportedLanguage(language.to_string()))?;

        let params = lsp_types::DidOpenTextDocumentParams {
            text_document: lsp_types::TextDocumentItem {
                uri,
                language_id: config.language_id.clone(),
                version: 1,
                text,
            },
        };

        client
            .notify("textDocument/didOpen", params)
            .await
            .map_err(LspBridgeError::LspClient)?;

        debug!("Opened {} in {} language server", real_path, language);
        Ok(())
    }

    /// Extract real filesystem path from potentially SSH-prefixed path
    /// scp://user@host//path/file -> /path/file
    fn extract_real_path(file_path: &str) -> String {
        if let Some(rest) = file_path.strip_prefix("scp://") {
            if let Some(pos) = rest.find("//") {
                return rest[pos + 1..].to_string();
            }
        }
        file_path.to_string()
    }

    /// Execute a notification — clone Arc and release lock before sending
    pub async fn notify<T>(&self, language: &str, method: &str, params: T) -> Result<()>
    where
        T: serde::Serialize,
    {
        let client = {
            let clients = self.clients.lock().await;
            clients
                .get(language)
                .ok_or_else(|| LspBridgeError::NoClientForLanguage(language.to_string()))?
                .clone()
        };
        client.notify(method, params).await?;
        Ok(())
    }

    /// Execute a request — clone Arc and release lock before waiting for response
    pub async fn request<R>(&self, language: &str, params: R::Params) -> Result<R::Result>
    where
        R: lsp_types::request::Request,
        R::Params: serde::Serialize + Send + 'static,
        R::Result: serde::de::DeserializeOwned,
    {
        let client = {
            let clients = self.clients.lock().await;
            clients
                .get(language)
                .ok_or_else(|| LspBridgeError::NoClientForLanguage(language.to_string()))?
                .clone()
        };
        Ok(client.request::<R>(params).await?)
    }

    /// Get client for a specific language (if it exists)
    pub async fn get_existing_client(&self, language: &str) -> bool {
        let clients = self.clients.lock().await;
        clients.contains_key(language)
    }

    /// Shutdown a language server
    pub async fn shutdown_language(&self, language: &str) -> Result<()> {
        let client = {
            let mut clients = self.clients.lock().await;
            clients.remove(language)
        };
        if let Some(client) = client {
            match client.request::<lsp_types::request::Shutdown>(()).await {
                Ok(_) => {
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
