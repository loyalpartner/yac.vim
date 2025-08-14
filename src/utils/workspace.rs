use std::path::{Path, PathBuf};
use tracing::debug;

/// 根据文件路径查找项目根目录
/// 支持Rust项目的常见根目录标识文件
pub fn find_workspace_root(file_path: &str) -> Option<String> {
    let path = if file_path.starts_with("file://") {
        &file_path[7..]
    } else {
        file_path
    };
    
    let file_path = Path::new(path);
    let mut current_dir = if file_path.is_file() {
        file_path.parent()?
    } else {
        file_path
    };

    // 常见的根目录标识文件
    let root_markers = ["Cargo.toml", "Cargo.lock", "rust-project.json", ".git"];
    
    loop {
        for marker in &root_markers {
            let marker_path = current_dir.join(marker);
            if marker_path.exists() {
                debug!("Found workspace root at: {} (marker: {})", current_dir.display(), marker);
                return Some(format!("file://{}", current_dir.display()));
            }
        }
        
        // 向上移动到父目录
        if let Some(parent) = current_dir.parent() {
            current_dir = parent;
        } else {
            break;
        }
    }
    
    debug!("No workspace root found for: {}", file_path.display());
    None
}

/// 检查路径是否是Rust项目根目录
pub fn is_rust_project_root(path: &Path) -> bool {
    path.join("Cargo.toml").exists() || 
    path.join("Cargo.lock").exists() || 
    path.join("rust-project.json").exists()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::tempdir;

    #[test]
    fn test_find_workspace_root() {
        let temp_dir = tempdir().unwrap();
        let root_path = temp_dir.path();
        
        // 创建项目结构
        let src_dir = root_path.join("src");
        fs::create_dir(&src_dir).unwrap();
        
        let cargo_toml = root_path.join("Cargo.toml");
        fs::write(&cargo_toml, "[package]\nname = \"test\"\nversion = \"0.1.0\"").unwrap();
        
        let lib_rs = src_dir.join("lib.rs");
        fs::write(&lib_rs, "// test file").unwrap();
        
        // 测试从lib.rs找到项目根目录
        let root_uri = find_workspace_root(&lib_rs.to_string_lossy());
        assert!(root_uri.is_some());
        assert!(root_uri.unwrap().contains(&root_path.to_string_lossy().to_string()));
    }
    
    #[test]
    fn test_is_rust_project_root() {
        let temp_dir = tempdir().unwrap();
        let root_path = temp_dir.path();
        
        // 没有Cargo.toml时不是项目根目录
        assert!(!is_rust_project_root(root_path));
        
        // 有Cargo.toml时是项目根目录
        let cargo_toml = root_path.join("Cargo.toml");
        fs::write(&cargo_toml, "[package]\nname = \"test\"\nversion = \"0.1.0\"").unwrap();
        assert!(is_rust_project_root(root_path));
    }
}