use std::collections::HashMap;


/// A user in the system
#[derive(Debug, Clone)]
pub struct User {
    id: i32,
    name: String,
    email: String,
}

impl User {
    /// Create a new user
    pub fn new(id: i32, name: String, email: String) -> Self {
        User { id, name, email }
    }

    /// Get the user's name
    pub fn get_name(&self) -> &str {
        &self.name
    }

    /// Get the user's email
    pub fn get_email(&self) -> &str {
        &self.email
    }
}

/// Create user map
pub fn create_user_map() -> HashMap<i32, User> {
    let mut users = HashMap::new();
    users.insert(1, User::new(1, "Alice".to_string(), "alice@example.com".to_string()));
    users.insert(2, User::new(2, "Bob".to_string(), "bob@example.com".to_string()));
    users.insert(3, User::new(3, "Charlie".to_string(), "charlie@example.com".to_string()));
    users
}

/// Get a user by their id
pub fn get_user_by_id(users: &HashMap<i32, User>, id: i32) -> Option<&User> {
    users.get(&id)
}

/// Process a user
pub fn process_user(user: &User) -> String {
    let result = format!("User: {}", user.get_name());
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_user_creation() {
        let user = User::new(1, "Test".to_string(), "test@example.com".to_string());
        assert_eq!(user.get_name(), "Test");
        assert_eq!(user.get_email(), "test@example.com");
    }

    #[test]
    fn test_create_user_map() {
        let users = create_user_map();
        assert_eq!(users.len(), 3);
        assert!(users.contains_key(&1));
    }

    #[test]
    fn test_process_user() {
        let user = User::new(1, "Alice".to_string(), "alice@example.com".to_string());
        let result = process_user(&user);
        assert!(result.contains("Alice"));
    }
}
