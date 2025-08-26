use anyhow::Result;
use lsp_bridge::path_manager::{PathContext, PathManager};
use serde::Serialize;
use std::path::Path;

/// Shared Location type - Linus style: one definition for all handlers
/// Enhanced with PathContext for SSH path support
#[derive(Debug, Serialize, Clone)]
pub struct Location {
    pub file: String, // Always local path for LSP
    pub line: u32,
    pub column: u32,
    #[serde(skip)] // Hidden from JSON, used for conversion
    pub context: PathContext,
}

impl Location {
    pub fn new(file: String, line: u32, column: u32) -> Self {
        Self {
            file,
            line,
            column,
            context: PathContext::Local,
        }
    }

    /// Create new location with path context
    pub fn new_with_context(file: String, line: u32, column: u32, context: PathContext) -> Self {
        Self {
            file,
            line,
            column,
            context,
        }
    }

    /// Convert from LSP Location - used by multiple handlers
    pub fn from_lsp_location(location: lsp_types::Location) -> Result<Self> {
        let file_path = location
            .uri
            .to_file_path()
            .map_err(|_| anyhow::anyhow!("Invalid file URI"))?;

        Ok(Self::new(
            file_path.to_string_lossy().to_string(),
            location.range.start.line,
            location.range.start.character,
        ))
    }

    /// Convert from LSP Location with path context
    pub fn from_lsp_location_with_context(
        location: lsp_types::Location,
        context: PathContext,
    ) -> Result<Self> {
        let file_path = location
            .uri
            .to_file_path()
            .map_err(|_| anyhow::anyhow!("Invalid file URI"))?;

        Ok(Self::new_with_context(
            file_path.to_string_lossy().to_string(),
            location.range.start.line,
            location.range.start.character,
            context,
        ))
    }

    /// Get path appropriate for Vim commands
    pub fn vim_path(&self) -> String {
        PathManager::new(self.context.clone()).to_vim_path(&self.file)
    }
}

/// Simple file path to URI conversion - used by most handlers
pub fn file_path_to_uri(file_path: &str) -> Result<String> {
    let path = Path::new(file_path);
    let canonical = path.canonicalize()?;
    Ok(format!("file://{}", canonical.display()))
}

/// Convert URI to file path - used by handlers that need to convert LSP URIs back to paths
pub fn uri_to_file_path(uri: &str) -> Result<String> {
    let lsp_uri = lsp_types::Url::parse(uri)?;
    let file_path = lsp_uri
        .to_file_path()
        .map_err(|_| anyhow::anyhow!("Invalid file URI"))?;
    Ok(file_path.to_string_lossy().to_string())
}
