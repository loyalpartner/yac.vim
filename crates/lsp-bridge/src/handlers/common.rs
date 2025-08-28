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

/// SSH path conversion utilities
pub fn extract_ssh_path(file_path: &str) -> (Option<String>, String) {
    if file_path.starts_with("scp://") {
        // Parse scp://user@host//path/file -> (user@host, /path/file)
        if let Some(rest) = file_path.strip_prefix("scp://") {
            if let Some(pos) = rest.find("//") {
                let ssh_host = &rest[..pos];
                let real_path = &rest[pos + 1..]; // Remove one slash, keep the leading slash
                return (Some(ssh_host.to_string()), real_path.to_string());
            }
        }
    }
    (None, file_path.to_string())
}

/// Convert SSH path back to scp:// format
pub fn restore_ssh_path(normal_path: &str, ssh_host: Option<&str>) -> String {
    if let Some(host) = ssh_host {
        format!("scp://{}//{}", host, normal_path)
    } else {
        normal_path.to_string()
    }
}

/// Simple file path to URI conversion - used by most handlers
/// Handles SSH path extraction automatically
pub fn file_path_to_uri(file_path: &str) -> Result<String> {
    let (_, real_path) = extract_ssh_path(file_path);
    let path = Path::new(&real_path);
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
