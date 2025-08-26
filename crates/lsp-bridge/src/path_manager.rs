use regex::Regex;
use std::sync::OnceLock;

/// Path context for handling local vs remote file paths
#[derive(Debug, Clone, PartialEq)]
pub enum PathContext {
    Local,
    Remote { user: String, host: String },
}

/// Centralized SSH path conversion manager
/// Follows Linus "Good Taste" principles: eliminates special cases through better data structures
#[derive(Debug, Clone)]
pub struct PathManager {
    context: PathContext,
}

impl PathManager {
    pub fn new(context: PathContext) -> Self {
        Self { context }
    }

    /// Parse SSH path and extract context + local path
    /// Format: scp://user@host//absolute/path/file.rs
    pub fn parse_ssh_path(path: &str) -> Result<(PathContext, String), anyhow::Error> {
        static SSH_REGEX: OnceLock<Regex> = OnceLock::new();
        let regex = SSH_REGEX.get_or_init(|| {
            Regex::new(r"^s(?:cp|ftp)://([^@]+)@([^/]+)//(.*)$").expect("Invalid SSH path regex")
        });

        if let Some(captures) = regex.captures(path) {
            let user = captures.get(1).unwrap().as_str().to_string();
            let host = captures.get(2).unwrap().as_str().to_string();
            let local_path = format!("/{}", captures.get(3).unwrap().as_str());

            Ok((PathContext::Remote { user, host }, local_path))
        } else {
            // Not an SSH path, treat as local
            Ok((PathContext::Local, path.to_string()))
        }
    }

    /// Convert local path back to appropriate format for Vim
    /// Local: /path/file.rs -> /path/file.rs  
    /// Remote: /path/file.rs -> scp://user@host//path/file.rs
    pub fn to_vim_path(&self, local_path: &str) -> String {
        match &self.context {
            PathContext::Local => local_path.to_string(),
            PathContext::Remote { user, host } => {
                // Ensure path starts with / for absolute paths
                let clean_path = local_path.strip_prefix('/').unwrap_or(local_path);
                format!("scp://{}@{}//{}", user, host, clean_path)
            }
        }
    }

    /// Get the path context
    pub fn context(&self) -> &PathContext {
        &self.context
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_local_path() {
        let (context, local_path) =
            PathManager::parse_ssh_path("/home/user/project/src/main.rs").unwrap();
        assert_eq!(context, PathContext::Local);
        assert_eq!(local_path, "/home/user/project/src/main.rs");
    }

    #[test]
    fn test_parse_scp_path() {
        let (context, local_path) =
            PathManager::parse_ssh_path("scp://dev@server//home/user/project/src/main.rs").unwrap();
        assert_eq!(
            context,
            PathContext::Remote {
                user: "dev".to_string(),
                host: "server".to_string()
            }
        );
        assert_eq!(local_path, "/home/user/project/src/main.rs");
    }

    #[test]
    fn test_parse_sftp_path() {
        let (context, local_path) =
            PathManager::parse_ssh_path("sftp://user@example.com//opt/project/lib.rs").unwrap();
        assert_eq!(
            context,
            PathContext::Remote {
                user: "user".to_string(),
                host: "example.com".to_string()
            }
        );
        assert_eq!(local_path, "/opt/project/lib.rs");
    }

    #[test]
    fn test_to_vim_path_local() {
        let manager = PathManager::new(PathContext::Local);
        let vim_path = manager.to_vim_path("/home/user/file.rs");
        assert_eq!(vim_path, "/home/user/file.rs");
    }

    #[test]
    fn test_to_vim_path_remote() {
        let manager = PathManager::new(PathContext::Remote {
            user: "dev".to_string(),
            host: "server".to_string(),
        });
        let vim_path = manager.to_vim_path("/home/user/file.rs");
        assert_eq!(vim_path, "scp://dev@server//home/user/file.rs");
    }
}
