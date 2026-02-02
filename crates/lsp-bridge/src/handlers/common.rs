use anyhow::Result;
use lsp_bridge::{LspBridgeError, LspRegistry};
use serde::Serialize;
use std::future::Future;
use std::path::Path;

// ============================================================================
// LSP Context Middleware - Linus style: eliminate boilerplate
// ============================================================================

/// LSP 请求上下文 - 包含所有 handler 需要的通用信息
pub struct LspContext<'a> {
    pub language: String,
    pub uri: lsp_types::Url,
    pub registry: &'a LspRegistry,
}

/// 通用的位置输入 trait - 大多数 LSP 请求都需要 file/line/column
pub trait HasFilePosition {
    fn file(&self) -> &str;
    fn line(&self) -> u32;
    fn column(&self) -> u32;
}

/// 中间件：处理通用的 LSP 前置检查
/// 消除 14 个 handler 中重复的 ~20 行模板代码
pub async fn with_lsp_context<'a, I, F, Fut, O>(
    registry: &'a LspRegistry,
    input: I,
    handler: F,
) -> Result<Option<O>>
where
    I: HasFilePosition,
    F: FnOnce(LspContext<'a>, I) -> Fut,
    Fut: Future<Output = Result<Option<O>>>,
{
    // 1. 检测语言
    let language = match registry.detect_language(input.file()) {
        Some(lang) => lang,
        None => return Ok(None),
    };

    // 2. 确保客户端存在
    if registry.get_client(&language, input.file()).await.is_err() {
        return Ok(None);
    }

    // 3. 转换文件路径到 URI
    let uri = match file_path_to_uri(input.file()) {
        Ok(uri_str) => lsp_types::Url::parse(&uri_str)?,
        Err(_) => return Ok(None),
    };

    let ctx = LspContext {
        language,
        uri,
        registry,
    };

    handler(ctx, input).await
}

// ============================================================================
// Shared Types
// ============================================================================

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
