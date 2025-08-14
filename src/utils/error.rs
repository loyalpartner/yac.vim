use thiserror::Error;

#[derive(Error, Debug)]
pub enum Error {
    #[error("LSP server error: {0}")]
    LspServer(String),

    #[error("Network error: {0}")]
    Network(#[from] std::io::Error),

    #[error("JSON parsing error: {0}")]
    Json(#[from] serde_json::Error),

    #[error("Configuration error: {message}")]
    Config { message: String },

    #[error("Client not found: {client_id}")]
    ClientNotFound { client_id: String },

    #[error("File not found: {path}")]
    FileNotFound { path: String },

    #[error("Process error: {0}")]
    Process(String),

    #[error("Timeout error: operation timed out")]
    Timeout,

    #[error("Protocol error: {message}")]
    Protocol { message: String },

    #[error("Internal error: {0}")]
    Internal(#[from] anyhow::Error),
}

pub type Result<T> = std::result::Result<T, Error>;

impl Error {
    pub fn config(msg: impl Into<String>) -> Self {
        Self::Config {
            message: msg.into(),
        }
    }

    pub fn protocol(msg: impl Into<String>) -> Self {
        Self::Protocol {
            message: msg.into(),
        }
    }

    pub fn lsp_server(msg: impl Into<String>) -> Self {
        Self::LspServer(msg.into())
    }

    pub fn process(msg: impl Into<String>) -> Self {
        Self::Process(msg.into())
    }

    pub fn client_not_found(client_id: impl Into<String>) -> Self {
        Self::ClientNotFound {
            client_id: client_id.into(),
        }
    }

    pub fn file_not_found(path: impl Into<String>) -> Self {
        Self::FileNotFound { path: path.into() }
    }

    pub fn timeout() -> Self {
        Self::Timeout
    }

    pub fn security(msg: impl Into<String>) -> Self {
        Self::Internal(anyhow::anyhow!(msg.into()))
    }
}
