// Test data for LSP goto definition
use std::collections::HashMap;

/// Simple struct for testing LSP features
#[derive(Debug, Clone)]
pub struct User {
    pub id: u32,
    pub name: String,
    pub email: String,
}

impl User {
    /// Constructor
    pub fn new(id: u32, name: String, email: String) -> Self {
        Self { id, name, email }
    }
    
    /// Get user name
    pub fn get_name(&self) -> &str {
        &self.name
    }
    
    /// Validate user
    pub fn is_valid(&self) -> bool {
        !self.name.is_empty() && self.email.contains('@')
    }
}

/// Create user map
pub fn create_user_map() -> HashMap<u32, User> {
    let mut users = HashMap::new();
    users.insert(1, User::new(1, "Alice".to_string(), "alice@test.com".to_string()));
    users.insert(2, User::new(2, "Bob".to_string(), "bob@test.com".to_string()));
    users
}

/// Test function
pub fn process_user(user: &User) -> String {
    format!("Processing user: {}", user.get_name())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_user_creation() {
        let user = User::new(1, "Test".to_string(), "test@example.com".to_string());
        assert_eq!(user.get_name(), "Test");
        assert!(user.is_valid());
    }
    
    #[test]
    fn test_user_map() {
        let users = create_user_map();
        assert_eq!(users.len(), 2);
    }
}
