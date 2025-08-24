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
use tracing::{debug, info};
use vim::{Handler, VimContext};

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
    50
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
    file_cache: Arc<tokio::sync::RwLock<Option<Vec<PathBuf>>>>,
    recent_files: Arc<tokio::sync::RwLock<VecDeque<String>>>,
}

impl FileSearchHandler {
    pub fn new(lsp_registry: Arc<LspRegistry>) -> Self {
        Self {
            _lsp_registry: lsp_registry,
            file_cache: Arc::new(tokio::sync::RwLock::new(None)),
            recent_files: Arc::new(tokio::sync::RwLock::new(VecDeque::new())),
        }
    }

    /// Add a file to the recent selection history
    async fn add_to_recent_files(&self, file_path: &str) {
        let mut recent = self.recent_files.write().await;

        // Remove if already exists to avoid duplicates
        if let Some(pos) = recent.iter().position(|x| x == file_path) {
            recent.remove(pos);
        }

        // Add to front
        recent.push_front(file_path.to_string());

        // Keep only last 20 files
        const MAX_RECENT_FILES: usize = 20;
        while recent.len() > MAX_RECENT_FILES {
            recent.pop_back();
        }

        debug!(
            "Added '{}' to recent files (total: {})",
            file_path,
            recent.len()
        );
    }

    /// Discover files in workspace root, with common exclusions
    async fn discover_files(&self, root: &Path) -> anyhow::Result<Vec<PathBuf>> {
        let mut files = Vec::new();
        let excluded_dirs = [
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
        let excluded_extensions = [".o", ".so", ".dylib", ".dll", ".exe"];

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
                        if !excluded_dirs.iter().any(|&excluded| dir_name == excluded) {
                            queue.push(path);
                        }
                    }
                } else if metadata.is_file() {
                    // Skip excluded file extensions
                    if let Some(extension) = path.extension() {
                        if excluded_extensions
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
        if query.is_empty() {
            return 1.0;
        }

        let query_lower = query.to_lowercase();
        let file_lower = file_path.to_lowercase();
        let basename = Path::new(file_path)
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("")
            .to_lowercase();

        let mut score = 0.0;

        // Exact basename match gets highest score
        if basename == query_lower {
            score += 100.0;
        }
        // Basename starts with query
        else if basename.starts_with(&query_lower) {
            score += 50.0 + (query.len() as f64 / basename.len() as f64) * 30.0;
        }
        // Query is contained in basename
        else if basename.contains(&query_lower) {
            score += 25.0 + (query.len() as f64 / basename.len() as f64) * 15.0;
        }
        // Full path contains query
        else if file_lower.contains(&query_lower) {
            score += 10.0 + (query.len() as f64 / file_lower.len() as f64) * 5.0;
        }

        // Prefer files closer to root (shorter paths)
        let path_segments = file_path.split('/').count() as f64;
        score -= path_segments * 0.1;

        // Boost score for recently selected files
        let recent = self.recent_files.read().await;
        if let Some(position) = recent
            .iter()
            .position(|recent_file| recent_file == file_path)
        {
            // Most recent file gets highest boost, decreasing for older files
            let recency_boost = 200.0 - (position as f64 * 9.0); // 200, 191, 182, 173, etc.
            score += recency_boost;
            debug!(
                "Applied recency boost of {:.1} to '{}'",
                recency_boost, file_path
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

        // Get or discover files
        let all_files = {
            let cache = self.file_cache.read().await;
            if let Some(ref cached_files) = *cache {
                cached_files.clone()
            } else {
                drop(cache);

                // Discover files and cache them
                let discovered = self.discover_files(&workspace_root).await?;
                let mut cache = self.file_cache.write().await;
                *cache = Some(discovered.clone());
                discovered
            }
        };

        // Filter and score files (async)
        let mut scored_files: Vec<FileItem> = Vec::new();
        for path in &all_files {
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

        // Sort by score (descending) and then by path length (ascending)
        scored_files.sort_by(|a, b| {
            b.score
                .partial_cmp(&a.score)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then_with(|| a.relative_path.len().cmp(&b.relative_path.len()))
        });

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
