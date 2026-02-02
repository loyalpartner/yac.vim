pub mod lsp_registry;
pub use lsp_registry::{LspRegistry, LspServerConfig};

// ============================================================================
// Error Types - Linus style: explicit, structured errors
// ============================================================================

#[derive(Debug, thiserror::Error)]
pub enum LspBridgeError {
    #[error("Unsupported language: {0}")]
    UnsupportedLanguage(String),

    #[error("Unsupported file type: {0}")]
    UnsupportedFileType(String),

    #[error("Invalid file path: {0}")]
    InvalidFilePath(String),

    #[error("Invalid file URI: {0}")]
    InvalidFileUri(String),

    #[error("No LSP client for language: {0}")]
    NoClientForLanguage(String),

    #[error("LSP client error: {0}")]
    LspClient(#[from] lsp_client::LspError),

    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),

    #[error("URL parse error: {0}")]
    UrlParse(#[from] url::ParseError),
}

pub type Result<T> = std::result::Result<T, LspBridgeError>;
