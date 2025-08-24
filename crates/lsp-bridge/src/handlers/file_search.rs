//! File search handler for Ctrl+P functionality
//!
//! Provides asynchronous file discovery with pagination to avoid overwhelming Vim.
//! Supports filtering and workspace-aware file discovery.

use anyhow;
use async_trait::async_trait;
use lsp_bridge::LspRegistry;
use serde::{Deserialize, Serialize};
use std::{
    collections::{HashSet, VecDeque},
    path::{Path, PathBuf},
    sync::Arc,
};
use tokio::fs;
use tokio::sync::{Mutex, OnceCell};
use tracing::{debug, info};
use vim::{Handler, VimContext};

// Constants to eliminate magic numbers
const DEFAULT_PAGE_SIZE: usize = 50;
const MAX_RECENT_FILES: usize = 20;
const RECENT_FILE_BASE_BOOST: f64 = 200.0;
const RECENT_FILE_DECAY_RATE: f64 = 9.0;
const BASE_SCORE: f64 = 1.0;
const EXACT_MATCH_SCORE: f64 = 100.0;
const PREFIX_MATCH_BASE: f64 = 50.0;
const PREFIX_MATCH_BONUS: f64 = 30.0;
const CONTAINS_MATCH_BASE: f64 = 25.0;
const CONTAINS_MATCH_BONUS: f64 = 15.0;
const PATH_MATCH_BASE: f64 = 10.0;
const PATH_MATCH_BONUS: f64 = 5.0;
const PATH_DEPTH_PENALTY: f64 = 0.1;

#[derive(Debug, Clone, Deserialize)]
pub struct FileSearchInput {
    #[serde(default)]
    pub query: String,
    #[serde(default)]
    pub page: usize,
    #[serde(default = "default_page_size")]
    pub page_size: usize,
    #[serde(default)]
    pub workspace_root: Option<String>,
    #[serde(default)]
    pub selected_file: Option<String>,
}

fn default_page_size() -> usize {
    DEFAULT_PAGE_SIZE
}

#[derive(Debug, Clone, Serialize)]
pub struct FileSearchOutput {
    pub files: Vec<FileItem>,
    pub total_count: usize,
    pub has_more: bool,
    pub page: usize,
}

#[derive(Debug, Clone, Serialize)]
pub struct FileItem {
    pub path: String,
    pub relative_path: String,
    pub score: f64, // For relevance scoring
}

#[derive(Clone)]
pub struct FileSearchHandler {
    _lsp_registry: Arc<LspRegistry>,
    file_cache: Arc<OnceCell<Vec<PathBuf>>>,
    recent_files: Arc<Mutex<VecDeque<String>>>,
}

impl FileSearchHandler {
    pub fn new(lsp_registry: Arc<LspRegistry>) -> Self {
        Self {
            _lsp_registry: lsp_registry,
            file_cache: Arc::new(OnceCell::new()),
            recent_files: Arc::new(Mutex::new(VecDeque::new())),
        }
    }

    /// Add a file to the recent selection history
    async fn add_to_recent_files(&self, file_path: &str) {
        let mut recent = self.recent_files.lock().await;

        // Remove if already exists to avoid duplicates
        if let Some(pos) = recent.iter().position(|x| x == file_path) {
            recent.remove(pos);
        }

        // Add to front
        recent.push_front(file_path.to_string());

        // Keep only last N files
        while recent.len() > MAX_RECENT_FILES {
            recent.pop_back();
        }

        debug!(
            "Added '{}' to recent files (total: {}). Recent list: {:?}",
            file_path,
            recent.len(),
            recent.iter().take(5).collect::<Vec<_>>()
        );
    }

    /// Discover files in workspace root, with common exclusions
    async fn discover_files(&self, root: &Path) -> anyhow::Result<Vec<PathBuf>> {
        let mut files = Vec::new();

        // Use constants for maintainable exclusion lists
        const EXCLUDED_DIRS: &[&str] = &[
            ".git",
            "node_modules",
            "target",
            "build",
            ".vscode",
            ".idea",
            "dist",
            "out",
            "__pycache__",
            ".next",
            "coverage",
        ];
        const EXCLUDED_EXTENSIONS: &[&str] = &[".o", ".so", ".dylib", ".dll", ".exe"];

        // Use a work queue to avoid deep recursion
        let mut queue = vec![root.to_path_buf()];
        let mut visited = HashSet::new();

        while let Some(current_dir) = queue.pop() {
            if visited.contains(&current_dir) {
                continue;
            }
            visited.insert(current_dir.clone());

            let mut entries = match fs::read_dir(&current_dir).await {
                Ok(entries) => entries,
                Err(e) => {
                    debug!("Failed to read directory {:?}: {}", current_dir, e);
                    continue;
                }
            };

            while let Some(entry) = entries.next_entry().await.unwrap_or(None) {
                let path = entry.path();
                let metadata = match entry.metadata().await {
                    Ok(metadata) => metadata,
                    Err(_) => continue,
                };

                if metadata.is_dir() {
                    // Skip excluded directories
                    if let Some(dir_name) = path.file_name() {
                        if !EXCLUDED_DIRS.iter().any(|&excluded| dir_name == excluded) {
                            queue.push(path);
                        }
                    }
                } else if metadata.is_file() {
                    // Skip excluded file extensions
                    if let Some(extension) = path.extension() {
                        if EXCLUDED_EXTENSIONS
                            .iter()
                            .any(|&ext| extension == ext.trim_start_matches('.'))
                        {
                            continue;
                        }
                    }
                    files.push(path);
                }
            }
        }

        info!("Discovered {} files in workspace", files.len());
        Ok(files)
    }

    /// Calculate relevance score for a file based on query
    async fn calculate_score(&self, file_path: &str, query: &str) -> f64 {
        let mut score = BASE_SCORE; // Start with base score for all files

        // Apply fuzzy matching score if there's a query
        if !query.is_empty() {
            let query_lower = query.to_lowercase();
            let file_lower = file_path.to_lowercase();
            let basename = Path::new(file_path)
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("")
                .to_lowercase();

            // Exact basename match gets highest score
            if basename == query_lower {
                score += EXACT_MATCH_SCORE;
            }
            // Basename starts with query
            else if basename.starts_with(&query_lower) {
                score += PREFIX_MATCH_BASE
                    + (query.len() as f64 / basename.len() as f64) * PREFIX_MATCH_BONUS;
            }
            // Query is contained in basename
            else if basename.contains(&query_lower) {
                score += CONTAINS_MATCH_BASE
                    + (query.len() as f64 / basename.len() as f64) * CONTAINS_MATCH_BONUS;
            }
            // Full path contains query
            else if file_lower.contains(&query_lower) {
                score += PATH_MATCH_BASE
                    + (query.len() as f64 / file_lower.len() as f64) * PATH_MATCH_BONUS;
            }

            // Prefer files closer to root (shorter paths)
            let path_segments = file_path.split('/').count() as f64;
            score -= path_segments * PATH_DEPTH_PENALTY;
        }

        // ALWAYS boost score for recently selected files
        let recent = self.recent_files.lock().await;

        // Debug: show comparison details
        debug!(
            "Scoring file '{}' (query: '{}'), recent files: {:?}",
            file_path,
            query,
            recent.iter().take(3).collect::<Vec<_>>()
        );

        if let Some(position) = recent
            .iter()
            .position(|recent_file| recent_file == file_path)
        {
            // Most recent file gets highest boost, decreasing for older files
            let recency_boost = RECENT_FILE_BASE_BOOST - (position as f64 * RECENT_FILE_DECAY_RATE);
            score += recency_boost;
            debug!(
                "Applied recency boost of {:.1} to '{}' (position: {}, final score: {:.1})",
                recency_boost, file_path, position, score
            );
        }

        score.max(0.0)
    }

    /// Find workspace root by looking for common project files
    fn find_workspace_root(&self, current_dir: &Path) -> PathBuf {
        let project_files = [
            "Cargo.toml",
            "package.json",
            ".git",
            "pyproject.toml",
            "go.mod",
            "pom.xml",
            "build.gradle",
            "Makefile",
            "CMakeLists.txt",
        ];

        let mut dir = current_dir;
        loop {
            for project_file in &project_files {
                if dir.join(project_file).exists() {
                    return dir.to_path_buf();
                }
            }

            if let Some(parent) = dir.parent() {
                dir = parent;
            } else {
                break;
            }
        }

        // Fallback to current directory if no project root found
        current_dir.to_path_buf()
    }
}

#[async_trait]
impl Handler for FileSearchHandler {
    type Input = FileSearchInput;
    type Output = FileSearchOutput;

    async fn handle(
        &self,
        _ctx: &mut dyn VimContext,
        input: Self::Input,
    ) -> anyhow::Result<Option<Self::Output>> {
        debug!(
            "File search request: query='{}', page={}, page_size={}, selected_file={:?}",
            input.query, input.page, input.page_size, input.selected_file
        );

        // If a file was selected, add it to recent history
        if let Some(ref selected_file) = input.selected_file {
            self.add_to_recent_files(selected_file).await;
        }

        // Determine workspace root
        let workspace_root = if let Some(root) = input.workspace_root {
            PathBuf::from(root)
        } else {
            // Use current working directory as fallback
            let current_dir = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
            self.find_workspace_root(&current_dir)
        };

        debug!("Using workspace root: {:?}", workspace_root);

        // Get or discover files (race-condition-free caching)
        let all_files = self
            .file_cache
            .get_or_try_init(|| self.discover_files(&workspace_root))
            .await?;

        // Filter and score files (chunked async processing to avoid blocking)
        let mut scored_files: Vec<FileItem> = Vec::new();
        const CHUNK_SIZE: usize = 100; // Process files in chunks to yield control

        for chunk in all_files.chunks(CHUNK_SIZE) {
            for path in chunk {
                let path_str = path.to_string_lossy();
                let relative_path = path
                    .strip_prefix(&workspace_root)
                    .unwrap_or(path)
                    .to_string_lossy()
                    .to_string();

                let score = self.calculate_score(&relative_path, &input.query).await;

                // Only include files that match the query (score > 0) or when no query is provided
                if input.query.is_empty() || score > 0.0 {
                    scored_files.push(FileItem {
                        path: path_str.to_string(),
                        relative_path,
                        score,
                    });
                }
            }
            // Yield control back to the async runtime after each chunk
            tokio::task::yield_now().await;
        }

        // Sort by score (descending) and then by path length (ascending)
        scored_files.sort_by(|a, b| {
            b.score
                .partial_cmp(&a.score)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then_with(|| a.relative_path.len().cmp(&b.relative_path.len()))
        });

        // Debug: show top files and their scores
        debug!(
            "Top 5 files after scoring: {:?}",
            scored_files
                .iter()
                .take(5)
                .map(|f| (f.relative_path.as_str(), f.score))
                .collect::<Vec<_>>()
        );

        let total_count = scored_files.len();
        let start_index = input.page * input.page_size;
        let end_index = std::cmp::min(start_index + input.page_size, total_count);

        let has_more = end_index < total_count;
        let page_files = if start_index < total_count {
            scored_files[start_index..end_index].to_vec()
        } else {
            Vec::new()
        };

        debug!(
            "Returning {} files (page {} of ~{})",
            page_files.len(),
            input.page,
            total_count.div_ceil(input.page_size)
        );

        Ok(Some(FileSearchOutput {
            files: page_files,
            total_count,
            has_more,
            page: input.page,
        }))
    }
}
