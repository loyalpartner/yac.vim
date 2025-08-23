use anyhow::Result;
use serde::Serialize;
use std::path::Path;

/// Shared Location type - Linus style: one definition for all handlers
#[derive(Debug, Serialize, Clone)]
pub struct Location {
    pub file: String,
    pub line: u32,
    pub column: u32,
}

impl Location {
    pub fn new(file: String, line: u32, column: u32) -> Self {
        Self { file, line, column }
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
}

/// Simple file path to URI conversion - used by most handlers
pub fn file_path_to_uri(file_path: &str) -> Result<String> {
    let path = Path::new(file_path);
    let canonical = path.canonicalize()?;
    Ok(format!("file://{}", canonical.display()))
}
