use anyhow::Result;
use async_trait::async_trait;
use lsp_bridge::LspRegistry;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tracing::debug;
use vim::Handler;

#[derive(Debug, Deserialize)]
#[allow(dead_code)]
pub struct DiagnosticsRequest {
    pub file: String,
}

#[derive(Debug, Serialize)]
#[allow(dead_code)]
pub struct Diagnostic {
    pub range: Range,
    pub severity: Option<String>,
    pub code: Option<String>,
    pub source: Option<String>,
    pub message: String,
    pub related_information: Option<Vec<DiagnosticRelatedInformation>>,
}

#[derive(Debug, Serialize)]
#[allow(dead_code)]
pub struct Range {
    pub start_line: u32,
    pub start_column: u32,
    pub end_line: u32,
    pub end_column: u32,
}

#[derive(Debug, Serialize)]
#[allow(dead_code)]
pub struct DiagnosticRelatedInformation {
    pub location: Location,
    pub message: String,
}

#[derive(Debug, Serialize)]
#[allow(dead_code)]
pub struct Location {
    pub file: String,
    pub range: Range,
}

#[derive(Debug, Serialize)]
#[allow(dead_code)]
pub struct DiagnosticsInfo {
    pub diagnostics: Vec<Diagnostic>,
}

// Linus-style: DiagnosticsInfo 要么完整存在，要么不存在
pub type DiagnosticsResponse = Option<DiagnosticsInfo>;

impl Range {
    #[allow(dead_code)]
    pub fn new(start_line: u32, start_column: u32, end_line: u32, end_column: u32) -> Self {
        Self {
            start_line,
            start_column,
            end_line,
            end_column,
        }
    }

    #[allow(dead_code)]
    pub fn from_lsp_range(range: lsp_types::Range) -> Self {
        Self::new(
            range.start.line,
            range.start.character,
            range.end.line,
            range.end.character,
        )
    }
}

impl Location {
    #[allow(dead_code)]
    pub fn new(file: String, range: Range) -> Self {
        Self { file, range }
    }
}

impl DiagnosticRelatedInformation {
    #[allow(dead_code)]
    pub fn new(location: Location, message: String) -> Self {
        Self { location, message }
    }
}

impl Diagnostic {
    #[allow(dead_code)]
    pub fn new(
        range: Range,
        severity: Option<String>,
        code: Option<String>,
        source: Option<String>,
        message: String,
        related_information: Option<Vec<DiagnosticRelatedInformation>>,
    ) -> Self {
        Self {
            range,
            severity,
            code,
            source,
            message,
            related_information,
        }
    }

    #[allow(dead_code)]
    pub fn from_lsp_diagnostic(diagnostic: lsp_types::Diagnostic) -> Result<Self> {
        let severity = diagnostic.severity.map(|s| match s {
            lsp_types::DiagnosticSeverity::ERROR => "Error".to_string(),
            lsp_types::DiagnosticSeverity::WARNING => "Warning".to_string(),
            lsp_types::DiagnosticSeverity::INFORMATION => "Information".to_string(),
            lsp_types::DiagnosticSeverity::HINT => "Hint".to_string(),
            _ => "Unknown".to_string(),
        });

        let code = diagnostic.code.map(|c| match c {
            lsp_types::NumberOrString::Number(n) => n.to_string(),
            lsp_types::NumberOrString::String(s) => s,
        });

        let related_information = diagnostic.related_information.map(|info_list| {
            info_list
                .into_iter()
                .filter_map(|info| {
                    let file_path = info.location.uri.to_file_path().ok()?;
                    let location = Location::new(
                        file_path.to_string_lossy().to_string(),
                        Range::from_lsp_range(info.location.range),
                    );
                    Some(DiagnosticRelatedInformation::new(location, info.message))
                })
                .collect()
        });

        Ok(Self::new(
            Range::from_lsp_range(diagnostic.range),
            severity,
            code,
            diagnostic.source,
            diagnostic.message,
            related_information,
        ))
    }
}

impl DiagnosticsInfo {
    #[allow(dead_code)]
    pub fn new(diagnostics: Vec<Diagnostic>) -> Self {
        Self { diagnostics }
    }
}

pub struct DiagnosticsHandler {
    #[allow(dead_code)]
    lsp_registry: Arc<LspRegistry>,
}

impl DiagnosticsHandler {
    pub fn new(registry: Arc<LspRegistry>) -> Self {
        Self {
            lsp_registry: registry,
        }
    }
}

#[async_trait]
impl Handler for DiagnosticsHandler {
    type Input = DiagnosticsRequest;
    type Output = DiagnosticsResponse;

    async fn handle(
        &self,
        _vim: &dyn vim::VimContext,
        input: Self::Input,
    ) -> Result<Option<Self::Output>> {
        // Note: Diagnostics are typically pushed by the server, not requested by client
        // This handler is for cases where we want to explicitly request diagnostics
        // Most LSP servers publish diagnostics automatically, so this might not be used often

        debug!("Diagnostics requested for file: {}", input.file);

        // In most cases, diagnostics are handled via server notifications
        // For now, return empty response since we handle diagnostics via push notifications
        // In the vim plugin's s:handle_response function

        Ok(Some(None)) // No diagnostics to return for pull-based requests
    }
}
