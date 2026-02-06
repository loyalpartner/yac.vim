use anyhow::Result;
use lsp_bridge::{LspBridgeError, LspRegistry};
use serde::Serialize;
use std::future::Future;
use std::path::Path;
use vim::HandlerResult;

// ============================================================================
// LSP Context Middleware - Linus style: eliminate boilerplate
// ============================================================================

/// LSP 请求上下文 - 包含所有 handler 需要的通用信息
pub struct LspContext<'a> {
    pub language: String,
    pub uri: lsp_types::Url,
    pub registry: &'a LspRegistry,
    /// SSH host from scp:// path, if any
    pub ssh_host: Option<String>,
}

impl LspContext<'_> {
    /// Restore SSH path prefix if the original request came via SSH
    pub fn restore_ssh_path(&self, path: &str) -> String {
        restore_ssh_path(path, self.ssh_host.as_deref())
    }
}

/// Minimal trait - input has a file path
pub trait HasFile {
    fn file(&self) -> &str;
}

/// Extended trait - input has file + position
/// Methods used by handlers to build LSP position params
#[allow(dead_code)]
pub trait HasFilePosition: HasFile {
    fn line(&self) -> u32;
    fn column(&self) -> u32;
}

/// Core middleware: detect language, ensure client, resolve URI
/// Handles SSH path extraction centrally — handlers get real paths + ssh_host in context
pub async fn with_lsp_file<'a, I, F, Fut, O>(
    registry: &'a LspRegistry,
    input: I,
    handler: F,
) -> Result<HandlerResult<O>>
where
    I: HasFile,
    F: FnOnce(LspContext<'a>, I) -> Fut,
    Fut: Future<Output = Result<HandlerResult<O>>>,
{
    // Centralized SSH path extraction — handlers never need to deal with scp:// paths
    let (ssh_host, real_path) = extract_ssh_path(input.file());

    let language = match registry.detect_language(&real_path) {
        Some(lang) => lang,
        None => return Ok(HandlerResult::Empty),
    };

    if registry.get_client(&language, &real_path).await.is_err() {
        return Ok(HandlerResult::Empty);
    }

    let uri = match file_path_to_uri(&real_path) {
        Ok(uri_str) => lsp_types::Url::parse(&uri_str)?,
        Err(_) => return Ok(HandlerResult::Empty),
    };

    handler(LspContext { language, uri, registry, ssh_host }, input).await
}

/// Convenience alias for handlers that need file + position
pub async fn with_lsp_context<'a, I, F, Fut, O>(
    registry: &'a LspRegistry,
    input: I,
    handler: F,
) -> Result<HandlerResult<O>>
where
    I: HasFilePosition,
    F: FnOnce(LspContext<'a>, I) -> Fut,
    Fut: Future<Output = Result<HandlerResult<O>>>,
{
    with_lsp_file(registry, input, handler).await
}

// ============================================================================
// Shared Types
// ============================================================================

/// Convert LSP SymbolKind to human-readable string
pub fn symbol_kind_name(kind: lsp_types::SymbolKind) -> &'static str {
    match kind {
        lsp_types::SymbolKind::FILE => "File",
        lsp_types::SymbolKind::MODULE => "Module",
        lsp_types::SymbolKind::NAMESPACE => "Namespace",
        lsp_types::SymbolKind::PACKAGE => "Package",
        lsp_types::SymbolKind::CLASS => "Class",
        lsp_types::SymbolKind::METHOD => "Method",
        lsp_types::SymbolKind::PROPERTY => "Property",
        lsp_types::SymbolKind::FIELD => "Field",
        lsp_types::SymbolKind::CONSTRUCTOR => "Constructor",
        lsp_types::SymbolKind::ENUM => "Enum",
        lsp_types::SymbolKind::INTERFACE => "Interface",
        lsp_types::SymbolKind::FUNCTION => "Function",
        lsp_types::SymbolKind::VARIABLE => "Variable",
        lsp_types::SymbolKind::CONSTANT => "Constant",
        lsp_types::SymbolKind::STRING => "String",
        lsp_types::SymbolKind::NUMBER => "Number",
        lsp_types::SymbolKind::BOOLEAN => "Boolean",
        lsp_types::SymbolKind::ARRAY => "Array",
        lsp_types::SymbolKind::OBJECT => "Object",
        lsp_types::SymbolKind::KEY => "Key",
        lsp_types::SymbolKind::NULL => "Null",
        lsp_types::SymbolKind::ENUM_MEMBER => "EnumMember",
        lsp_types::SymbolKind::STRUCT => "Struct",
        lsp_types::SymbolKind::EVENT => "Event",
        lsp_types::SymbolKind::OPERATOR => "Operator",
        lsp_types::SymbolKind::TYPE_PARAMETER => "TypeParameter",
        _ => "Unknown",
    }
}

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
            .map_err(|_| LspBridgeError::InvalidFileUri(location.uri.to_string()))?;

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
        .map_err(|_| LspBridgeError::InvalidFileUri(uri.to_string()))?;
    Ok(file_path.to_string_lossy().to_string())
}

// ============================================================================
// Shared Workspace Edit Types
// ============================================================================

/// A text edit with file path — flat representation of workspace edits
#[derive(Debug, Serialize, Clone)]
pub struct FileTextEdit {
    pub file: String,
    pub start_line: u32,
    pub start_column: u32,
    pub end_line: u32,
    pub end_column: u32,
    pub new_text: String,
}

/// Convert LSP WorkspaceEdit to flat list of file text edits
pub fn convert_workspace_edit(edit: lsp_types::WorkspaceEdit) -> Vec<FileTextEdit> {
    let mut result = Vec::new();

    if let Some(changes) = edit.changes {
        for (uri, edits) in changes {
            let file_path = match uri.to_file_path() {
                Ok(path) => path.to_string_lossy().to_string(),
                Err(_) => continue,
            };
            for text_edit in edits {
                result.push(FileTextEdit {
                    file: file_path.clone(),
                    start_line: text_edit.range.start.line,
                    start_column: text_edit.range.start.character,
                    end_line: text_edit.range.end.line,
                    end_column: text_edit.range.end.character,
                    new_text: text_edit.new_text,
                });
            }
        }
    }

    if let Some(document_changes) = edit.document_changes {
        match document_changes {
            lsp_types::DocumentChanges::Edits(edits) => {
                for edit in edits {
                    let file_path = match edit.text_document.uri.to_file_path() {
                        Ok(path) => path.to_string_lossy().to_string(),
                        Err(_) => continue,
                    };
                    for text_edit in edit.edits {
                        let lsp_types::OneOf::Left(text_edit) = text_edit else {
                            continue;
                        };
                        result.push(FileTextEdit {
                            file: file_path.clone(),
                            start_line: text_edit.range.start.line,
                            start_column: text_edit.range.start.character,
                            end_line: text_edit.range.end.line,
                            end_column: text_edit.range.end.character,
                            new_text: text_edit.new_text,
                        });
                    }
                }
            }
            lsp_types::DocumentChanges::Operations(_) => {}
        }
    }

    result
}
