use crate::lsp::protocol::{Position, Range, TextDocumentContentChange};
use crate::utils::{Error, Result};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::Path;
use std::time::{Instant, SystemTime, UNIX_EPOCH};
use tracing::{debug, info, warn};

#[derive(Debug, Clone)]
pub struct FileState {
    pub uri: String,
    pub language_id: String,
    pub version: i32,
    pub content: String,
    pub last_modified: Instant,
    pub dirty: bool,
    pub line_count: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FileMetadata {
    pub uri: String,
    pub language_id: String,
    pub size: usize,
    pub last_changed: u64,
    pub version: i32,
}

pub struct FileManager {
    files: HashMap<String, FileState>,
    file_to_servers: HashMap<String, Vec<String>>,
}

impl FileState {
    pub fn new(uri: String, language_id: String, version: i32, content: String) -> Self {
        let line_count = content.lines().count().max(1);

        Self {
            uri,
            language_id,
            version,
            content,
            last_modified: Instant::now(),
            dirty: false,
            line_count,
        }
    }

    pub fn apply_changes(&mut self, changes: Vec<TextDocumentContentChange>) -> Result<()> {
        for change in changes {
            self.apply_single_change(change)?;
        }

        self.version += 1;
        self.last_modified = Instant::now();
        self.dirty = true;
        self.line_count = self.content.lines().count().max(1);

        Ok(())
    }

    fn apply_single_change(&mut self, change: TextDocumentContentChange) -> Result<()> {
        match change.range {
            Some(range) => {
                // Incremental change
                let start_index = self.position_to_index(&range.start)?;
                let end_index = self.position_to_index(&range.end)?;

                if start_index > self.content.len()
                    || end_index > self.content.len()
                    || start_index > end_index
                {
                    return Err(Error::protocol(format!(
                        "Invalid range: start={}, end={}, content_len={}",
                        start_index,
                        end_index,
                        self.content.len()
                    )));
                }

                // Replace the range with new text
                let mut new_content = String::with_capacity(
                    self.content.len() - (end_index - start_index) + change.text.len(),
                );
                new_content.push_str(&self.content[..start_index]);
                new_content.push_str(&change.text);
                new_content.push_str(&self.content[end_index..]);

                self.content = new_content;
                debug!(
                    "Applied incremental change to {}: range {:?}",
                    self.uri, range
                );
            }
            None => {
                // Full document change
                self.content = change.text;
                debug!("Applied full document change to {}", self.uri);
            }
        }

        Ok(())
    }

    fn position_to_index(&self, position: &Position) -> Result<usize> {
        let lines: Vec<&str> = self.content.lines().collect();

        if position.line < 0 {
            return Err(Error::protocol(
                "Line number cannot be negative".to_string(),
            ));
        }

        let line_index = position.line as usize;
        if line_index >= lines.len() {
            return Ok(self.content.len());
        }

        let mut index = 0;
        for i in 0..line_index {
            index += lines[i].len() + 1; // +1 for newline
        }

        let character_index = (position.character as usize).min(lines[line_index].len());
        index += character_index;

        Ok(index.min(self.content.len()))
    }

    pub fn get_line(&self, line_number: usize) -> Option<&str> {
        self.content.lines().nth(line_number)
    }

    pub fn get_lines(&self, start: usize, end: usize) -> Vec<&str> {
        self.content
            .lines()
            .skip(start)
            .take(end.saturating_sub(start))
            .collect()
    }

    pub fn get_text_in_range(&self, range: &Range) -> Result<String> {
        let start_index = self.position_to_index(&range.start)?;
        let end_index = self.position_to_index(&range.end)?;

        Ok(self.content[start_index..end_index].to_string())
    }

    pub fn mark_saved(&mut self) {
        self.dirty = false;
        self.last_modified = Instant::now();
    }

    pub fn get_metadata(&self) -> FileMetadata {
        FileMetadata {
            uri: self.uri.clone(),
            language_id: self.language_id.clone(),
            size: self.content.len(),
            last_changed: SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs(),
            version: self.version,
        }
    }
}

impl Default for FileManager {
    fn default() -> Self {
        Self::new()
    }
}

impl FileManager {
    pub fn new() -> Self {
        Self {
            files: HashMap::new(),
            file_to_servers: HashMap::new(),
        }
    }

    pub fn open_file(
        &mut self,
        uri: String,
        language_id: String,
        version: i32,
        content: String,
    ) -> Result<()> {
        info!("Opening file: {} ({})", uri, language_id);

        let file_state = FileState::new(uri.clone(), language_id, version, content);
        self.files.insert(uri.clone(), file_state);

        // Initialize server mapping
        self.file_to_servers.insert(uri, Vec::new());

        Ok(())
    }

    pub fn close_file(&mut self, uri: &str) -> Result<()> {
        if self.files.remove(uri).is_some() {
            info!("Closed file: {}", uri);
            self.file_to_servers.remove(uri);
            Ok(())
        } else {
            warn!("Attempted to close non-existent file: {}", uri);
            Err(Error::file_not_found(uri))
        }
    }

    pub fn change_file(
        &mut self,
        uri: &str,
        version: i32,
        changes: Vec<TextDocumentContentChange>,
    ) -> Result<()> {
        let file = self
            .files
            .get_mut(uri)
            .ok_or_else(|| Error::file_not_found(uri))?;

        if version <= file.version {
            warn!(
                "Received outdated change for {}: version {} <= current {}",
                uri, version, file.version
            );
            return Ok(());
        }

        file.version = version;
        file.apply_changes(changes)?;

        debug!("Applied changes to file: {} (v{})", uri, version);
        Ok(())
    }

    pub fn save_file(&mut self, uri: &str) -> Result<()> {
        let file = self
            .files
            .get_mut(uri)
            .ok_or_else(|| Error::file_not_found(uri))?;

        file.mark_saved();
        info!("Saved file: {}", uri);
        Ok(())
    }

    pub fn get_file(&self, uri: &str) -> Option<&FileState> {
        self.files.get(uri)
    }

    pub fn get_file_mut(&mut self, uri: &str) -> Option<&mut FileState> {
        self.files.get_mut(uri)
    }

    pub fn get_file_content(&self, uri: &str) -> Option<&str> {
        self.files.get(uri).map(|f| f.content.as_str())
    }

    pub fn get_file_language(&self, uri: &str) -> Option<&str> {
        self.files.get(uri).map(|f| f.language_id.as_str())
    }

    pub fn is_file_open(&self, uri: &str) -> bool {
        self.files.contains_key(uri)
    }

    pub fn get_open_files(&self) -> Vec<&str> {
        self.files.keys().map(|s| s.as_str()).collect()
    }

    pub fn get_files_by_language(&self, language_id: &str) -> Vec<&str> {
        self.files
            .iter()
            .filter(|(_, file)| file.language_id == language_id)
            .map(|(uri, _)| uri.as_str())
            .collect()
    }

    pub fn get_dirty_files(&self) -> Vec<&str> {
        self.files
            .iter()
            .filter(|(_, file)| file.dirty)
            .map(|(uri, _)| uri.as_str())
            .collect()
    }

    pub fn associate_server(&mut self, uri: &str, server_id: String) -> Result<()> {
        let servers = self
            .file_to_servers
            .get_mut(uri)
            .ok_or_else(|| Error::file_not_found(uri))?;

        if !servers.contains(&server_id) {
            servers.push(server_id);
            debug!("Associated server with file: {}", uri);
        }

        Ok(())
    }

    pub fn get_associated_servers(&self, uri: &str) -> Vec<&str> {
        self.file_to_servers
            .get(uri)
            .map(|servers| servers.iter().map(|s| s.as_str()).collect())
            .unwrap_or_default()
    }

    pub fn remove_server_association(&mut self, uri: &str, server_id: &str) {
        if let Some(servers) = self.file_to_servers.get_mut(uri) {
            servers.retain(|s| s != server_id);
        }
    }

    pub fn get_file_count(&self) -> usize {
        self.files.len()
    }

    pub fn get_total_content_size(&self) -> usize {
        self.files.values().map(|f| f.content.len()).sum()
    }

    pub fn detect_language_from_uri(&self, uri: &str) -> String {
        if let Some(path) = uri.strip_prefix("file://") {
            if let Some(extension) = Path::new(path).extension() {
                if let Some(ext_str) = extension.to_str() {
                    return match ext_str {
                        "rs" => "rust".to_string(),
                        "py" => "python".to_string(),
                        "js" | "jsx" => "javascript".to_string(),
                        "ts" | "tsx" => "typescript".to_string(),
                        "go" => "go".to_string(),
                        "c" | "h" => "c".to_string(),
                        "cpp" | "cc" | "cxx" | "hpp" => "cpp".to_string(),
                        "java" => "java".to_string(),
                        "md" => "markdown".to_string(),
                        "json" => "json".to_string(),
                        "toml" => "toml".to_string(),
                        "yaml" | "yml" => "yaml".to_string(),
                        _ => "text".to_string(),
                    };
                }
            }
        }
        "text".to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_file_creation() {
        let content = "fn main() {\n    println!(\"Hello, world!\");\n}";
        let file = FileState::new(
            "file:///test.rs".to_string(),
            "rust".to_string(),
            1,
            content.to_string(),
        );

        assert_eq!(file.uri, "file:///test.rs");
        assert_eq!(file.language_id, "rust");
        assert_eq!(file.version, 1);
        assert_eq!(file.content, content);
        assert_eq!(file.line_count, 3);
        assert!(!file.dirty);
    }

    #[test]
    fn test_position_to_index() {
        let content = "line1\nline2\nline3";
        let file = FileState::new(
            "file:///test.txt".to_string(),
            "text".to_string(),
            1,
            content.to_string(),
        );

        assert_eq!(
            file.position_to_index(&Position {
                line: 0,
                character: 0
            })
            .unwrap(),
            0
        );
        assert_eq!(
            file.position_to_index(&Position {
                line: 0,
                character: 5
            })
            .unwrap(),
            5
        );
        assert_eq!(
            file.position_to_index(&Position {
                line: 1,
                character: 0
            })
            .unwrap(),
            6
        );
        assert_eq!(
            file.position_to_index(&Position {
                line: 2,
                character: 5
            })
            .unwrap(),
            17
        );
    }

    #[test]
    fn test_incremental_change() {
        let content = "fn main() {\n    println!(\"Hello\");\n}";
        let mut file = FileState::new(
            "file:///test.rs".to_string(),
            "rust".to_string(),
            1,
            content.to_string(),
        );

        let change = TextDocumentContentChange {
            range: Some(Range {
                start: Position {
                    line: 1,
                    character: 17,
                },
                end: Position {
                    line: 1,
                    character: 22,
                },
            }),
            text: "World".to_string(),
        };

        file.apply_changes(vec![change]).unwrap();
        assert!(file.content.contains("World"));
        assert_eq!(file.version, 2);
        assert!(file.dirty);
    }
}
