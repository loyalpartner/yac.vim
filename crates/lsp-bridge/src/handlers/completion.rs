use anyhow::Result;
use async_trait::async_trait;
use lsp_bridge::LspRegistry;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tracing::debug;
use vim::Handler;

#[derive(Debug, Deserialize)]
#[allow(dead_code)]
pub struct CompletionRequest {
    pub file: String,
    pub line: u32,
    pub column: u32,
    pub trigger_character: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct CompletionItem {
    pub label: String,
    pub kind: Option<String>,
    pub detail: Option<String>,
    pub documentation: Option<String>,
    pub insert_text: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct CompletionInfo {
    pub items: Vec<CompletionItem>,
    pub is_incomplete: bool,
}

// Linus-style: CompletionInfo 要么完整存在，要么不存在
pub type CompletionResponse = Option<CompletionInfo>;

impl CompletionItem {
    pub fn new(
        label: String,
        kind: Option<String>,
        detail: Option<String>,
        documentation: Option<String>,
        insert_text: Option<String>,
    ) -> Self {
        Self {
            label,
            kind,
            detail,
            documentation,
            insert_text,
        }
    }
}

impl CompletionInfo {
    pub fn new(items: Vec<CompletionItem>, is_incomplete: bool) -> Self {
        Self {
            items,
            is_incomplete,
        }
    }
}

// Cache entry for storing completion results
#[derive(Debug, Clone)]
struct CompletionCacheEntry {
    items: Vec<CompletionItem>,
    is_incomplete: bool,
    timestamp: Instant,
}

// Cache key for unique completion requests
#[derive(Debug, Hash, PartialEq, Eq)]
struct CompletionCacheKey {
    file: String,
    line: u32,
    column_prefix: String, // Use prefix instead of exact column for better cache hits
}

type CompletionCache = Arc<Mutex<HashMap<CompletionCacheKey, CompletionCacheEntry>>>;

pub struct CompletionHandler {
    lsp_registry: Arc<LspRegistry>,
    cache: CompletionCache,
}

impl CompletionHandler {
    pub fn new(registry: Arc<LspRegistry>) -> Self {
        Self {
            lsp_registry: registry,
            cache: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    // Linus-style: Simple cache cleanup - no complex algorithms
    fn cleanup_cache(&self) {
        let mut cache = self.cache.lock().unwrap();
        let now = Instant::now();
        let cache_ttl = Duration::from_secs(300); // 5 minutes

        cache.retain(|_, entry| now.duration_since(entry.timestamp) < cache_ttl);
    }

    // Extract prefix for better cache key generation
    fn extract_prefix(line_text: &str, column: u32) -> String {
        let col = column as usize;
        if col > line_text.len() {
            return String::new();
        }

        let before_cursor = &line_text[..col];
        // Find the start of the current word
        let word_start = before_cursor
            .rfind(|c: char| !c.is_alphanumeric() && c != '_')
            .map(|i| i + 1)
            .unwrap_or(0);

        before_cursor[word_start..].to_string()
    }

    // Deduplicate completion items by label
    fn deduplicate_items(items: Vec<CompletionItem>) -> Vec<CompletionItem> {
        let mut seen = HashSet::new();
        let mut result = Vec::new();

        for item in items {
            if seen.insert(item.label.clone()) {
                result.push(item);
            }
        }

        result
    }

    fn completion_kind_to_string(kind: Option<lsp_types::CompletionItemKind>) -> Option<String> {
        kind.map(|k| match k {
            lsp_types::CompletionItemKind::TEXT => "Text".to_string(),
            lsp_types::CompletionItemKind::METHOD => "Method".to_string(),
            lsp_types::CompletionItemKind::FUNCTION => "Function".to_string(),
            lsp_types::CompletionItemKind::CONSTRUCTOR => "Constructor".to_string(),
            lsp_types::CompletionItemKind::FIELD => "Field".to_string(),
            lsp_types::CompletionItemKind::VARIABLE => "Variable".to_string(),
            lsp_types::CompletionItemKind::CLASS => "Class".to_string(),
            lsp_types::CompletionItemKind::INTERFACE => "Interface".to_string(),
            lsp_types::CompletionItemKind::MODULE => "Module".to_string(),
            lsp_types::CompletionItemKind::PROPERTY => "Property".to_string(),
            lsp_types::CompletionItemKind::UNIT => "Unit".to_string(),
            lsp_types::CompletionItemKind::VALUE => "Value".to_string(),
            lsp_types::CompletionItemKind::ENUM => "Enum".to_string(),
            lsp_types::CompletionItemKind::KEYWORD => "Keyword".to_string(),
            lsp_types::CompletionItemKind::SNIPPET => "Snippet".to_string(),
            lsp_types::CompletionItemKind::COLOR => "Color".to_string(),
            lsp_types::CompletionItemKind::FILE => "File".to_string(),
            lsp_types::CompletionItemKind::REFERENCE => "Reference".to_string(),
            lsp_types::CompletionItemKind::FOLDER => "Folder".to_string(),
            lsp_types::CompletionItemKind::ENUM_MEMBER => "EnumMember".to_string(),
            lsp_types::CompletionItemKind::CONSTANT => "Constant".to_string(),
            lsp_types::CompletionItemKind::STRUCT => "Struct".to_string(),
            lsp_types::CompletionItemKind::EVENT => "Event".to_string(),
            lsp_types::CompletionItemKind::OPERATOR => "Operator".to_string(),
            lsp_types::CompletionItemKind::TYPE_PARAMETER => "TypeParameter".to_string(),
            _ => "Unknown".to_string(),
        })
    }
}

#[async_trait]
impl Handler for CompletionHandler {
    type Input = CompletionRequest;
    type Output = CompletionResponse;

    async fn handle(
        &self,
        vim: &dyn vim::VimContext,
        input: Self::Input,
    ) -> Result<Option<Self::Output>> {
        // Periodic cache cleanup
        self.cleanup_cache();

        // Get current line for prefix extraction
        let line_content = vim.get_line_content(input.line).await.unwrap_or_default();
        let prefix = Self::extract_prefix(&line_content, input.column);

        // Create cache key
        let cache_key = CompletionCacheKey {
            file: input.file.clone(),
            line: input.line,
            column_prefix: prefix.clone(),
        };

        // Check cache first - Linus style: simple and fast
        {
            let cache = self.cache.lock().unwrap();
            if let Some(entry) = cache.get(&cache_key) {
                let age = entry.timestamp.elapsed();
                if age < Duration::from_secs(30) {
                    // 30 second cache TTL
                    debug!("Cache hit for completion at {}:{}", input.file, input.line);
                    let deduped_items = Self::deduplicate_items(entry.items.clone());
                    return Ok(Some(Some(CompletionInfo::new(
                        deduped_items,
                        entry.is_incomplete,
                    ))));
                }
            }
        }

        // Detect language
        let language = match self.lsp_registry.detect_language(&input.file) {
            Some(lang) => lang,
            None => return Ok(None), // Unsupported file type
        };

        // Ensure client exists
        if self
            .lsp_registry
            .get_client(&language, &input.file)
            .await
            .is_err()
        {
            return Ok(None);
        }

        // Convert file path to URI
        let uri = match super::common::file_path_to_uri(&input.file) {
            Ok(uri) => uri,
            Err(_) => return Ok(None),
        };

        // Prepare LSP completion request
        let mut params = lsp_types::CompletionParams {
            text_document_position: lsp_types::TextDocumentPositionParams {
                text_document: lsp_types::TextDocumentIdentifier {
                    uri: lsp_types::Url::parse(&uri)?,
                },
                position: lsp_types::Position {
                    line: input.line,
                    character: input.column,
                },
            },
            work_done_progress_params: Default::default(),
            partial_result_params: Default::default(),
            context: None,
        };

        // Set trigger context if provided
        if let Some(trigger_char) = input.trigger_character.clone() {
            params.context = Some(lsp_types::CompletionContext {
                trigger_kind: lsp_types::CompletionTriggerKind::TRIGGER_CHARACTER,
                trigger_character: Some(trigger_char),
            });
        }

        let response = match self
            .lsp_registry
            .request::<lsp_types::request::Completion>(&language, params)
            .await
        {
            Ok(response) => response,
            Err(_) => return Ok(None),
        };

        debug!("completion response: {:?}", response);

        let (items, is_incomplete) = match response {
            Some(lsp_types::CompletionResponse::Array(items)) => (items, false),
            Some(lsp_types::CompletionResponse::List(list)) => (list.items, list.is_incomplete),
            None => return Ok(None), // No completions
        };

        if items.is_empty() {
            return Ok(None); // No completion items
        }

        // Convert completion items
        let mut result_items: Vec<CompletionItem> = items
            .into_iter()
            .map(|item| {
                let documentation = match item.documentation {
                    Some(lsp_types::Documentation::String(s)) => Some(s),
                    Some(lsp_types::Documentation::MarkupContent(markup)) => Some(markup.value),
                    None => None,
                };

                let insert_text = item.insert_text.or_else(|| Some(item.label.clone()));

                CompletionItem::new(
                    item.label,
                    Self::completion_kind_to_string(item.kind),
                    item.detail,
                    documentation,
                    insert_text,
                )
            })
            .collect();

        // Linus-style: Do what's necessary, nothing more
        result_items = Self::deduplicate_items(result_items);

        // Store in cache for future requests
        {
            let mut cache = self.cache.lock().unwrap();
            cache.insert(
                cache_key,
                CompletionCacheEntry {
                    items: result_items.clone(),
                    is_incomplete,
                    timestamp: Instant::now(),
                },
            );
        }

        debug!(
            "Cached {} completion items for {}:{}",
            result_items.len(),
            input.file,
            input.line
        );
        Ok(Some(Some(CompletionInfo::new(result_items, is_incomplete))))
    }
}
