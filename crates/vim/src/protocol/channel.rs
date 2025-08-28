use anyhow::{Error, Result};
use serde_json::{json, Value};

/// Vim channel commands (client-to-vim)
/// Per Vim channel protocol, client commands use negative IDs
#[derive(Debug, Clone)]
pub enum ChannelCommand {
    /// Call vim function with response: ["call", func, args, id] (id must be negative)
    Call {
        func: String,
        args: Vec<Value>,
        id: i64, // Negative ID for client-to-vim commands
    },
    /// Call vim function without response: ["call", func, args]
    CallAsync { func: String, args: Vec<Value> },
    /// Execute vim expression with response: ["expr", expr, id] (id must be negative)
    Expr {
        expr: String,
        id: i64, // Negative ID for client-to-vim commands
    },
    /// Execute vim expression without response: ["expr", expr]
    ExprAsync { expr: String },
    /// Execute ex command: ["ex", command]
    Ex { command: String },
    /// Execute normal mode command: ["normal", keys]
    Normal { keys: String },
    /// Redraw screen: ["redraw", force?]
    Redraw { force: bool },
}

impl ChannelCommand {
    /// Parse Vim channel command from JSON array
    pub fn parse(arr: &[Value]) -> Result<Self> {
        if arr.is_empty() {
            return Err(Error::msg("Empty channel command"));
        }

        match &arr[0] {
            Value::String(s) if s == "call" && arr.len() >= 3 => {
                let func = arr[1]
                    .as_str()
                    .ok_or_else(|| Error::msg("Invalid call function"))?
                    .to_string();
                let args = arr[2]
                    .as_array()
                    .ok_or_else(|| Error::msg("Invalid call args"))?
                    .clone();

                if arr.len() >= 4 {
                    // ["call", func, args, id] - with response
                    let id = arr[3]
                        .as_i64()
                        .ok_or_else(|| Error::msg("Invalid call id"))?;
                    Ok(ChannelCommand::Call { func, args, id })
                } else {
                    // ["call", func, args] - async
                    Ok(ChannelCommand::CallAsync { func, args })
                }
            }
            Value::String(s) if s == "expr" && arr.len() >= 2 => {
                let expr = arr[1]
                    .as_str()
                    .ok_or_else(|| Error::msg("Invalid expr"))?
                    .to_string();

                if arr.len() >= 3 {
                    // ["expr", expr, id] - with response
                    let id = arr[2]
                        .as_i64()
                        .ok_or_else(|| Error::msg("Invalid expr id"))?;
                    Ok(ChannelCommand::Expr { expr, id })
                } else {
                    // ["expr", expr] - async
                    Ok(ChannelCommand::ExprAsync { expr })
                }
            }
            Value::String(s) if s == "ex" && arr.len() >= 2 => {
                let command = arr[1]
                    .as_str()
                    .ok_or_else(|| Error::msg("Invalid ex command"))?
                    .to_string();
                Ok(ChannelCommand::Ex { command })
            }
            Value::String(s) if s == "normal" && arr.len() >= 2 => {
                let keys = arr[1]
                    .as_str()
                    .ok_or_else(|| Error::msg("Invalid normal keys"))?
                    .to_string();
                Ok(ChannelCommand::Normal { keys })
            }
            Value::String(s) if s == "redraw" => {
                let force = arr.len() >= 2 && arr[1].as_str() == Some("force");
                Ok(ChannelCommand::Redraw { force })
            }
            _ => Err(Error::msg("Invalid channel command format")),
        }
    }

    /// Encode channel command to JSON
    pub fn encode(&self) -> Value {
        match self {
            ChannelCommand::Call { func, args, id } => {
                json!(["call", func, args, id])
            }
            ChannelCommand::CallAsync { func, args } => {
                json!(["call", func, args])
            }
            ChannelCommand::Expr { expr, id } => {
                json!(["expr", expr, id])
            }
            ChannelCommand::ExprAsync { expr } => {
                json!(["expr", expr])
            }
            ChannelCommand::Ex { command } => {
                json!(["ex", command])
            }
            ChannelCommand::Normal { keys } => {
                json!(["normal", keys])
            }
            ChannelCommand::Redraw { force } => {
                if *force {
                    json!(["redraw", "force"])
                } else {
                    json!(["redraw", ""])
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_channel_command_parsing() {
        // Test call with response
        let json = json!(["call", "test_func", ["arg1", 42], -123]);
        let cmd = ChannelCommand::parse(json.as_array().unwrap()).unwrap();
        match cmd {
            ChannelCommand::Call { func, args, id } => {
                assert_eq!(func, "test_func");
                assert_eq!(args, vec![json!("arg1"), json!(42)]);
                assert_eq!(id, -123);
            }
            _ => panic!("Expected Call"),
        }

        // Test async call
        let json = json!(["call", "async_func", ["data"]]);
        let cmd = ChannelCommand::parse(json.as_array().unwrap()).unwrap();
        match cmd {
            ChannelCommand::CallAsync { func, args } => {
                assert_eq!(func, "async_func");
                assert_eq!(args, vec![json!("data")]);
            }
            _ => panic!("Expected CallAsync"),
        }

        // Test expr with response
        let json = json!(["expr", "line('$')", -456]);
        let cmd = ChannelCommand::parse(json.as_array().unwrap()).unwrap();
        match cmd {
            ChannelCommand::Expr { expr, id } => {
                assert_eq!(expr, "line('$')");
                assert_eq!(id, -456);
            }
            _ => panic!("Expected Expr"),
        }
    }

    #[test]
    fn test_channel_command_encoding() {
        // Test call encoding
        let cmd = ChannelCommand::Call {
            func: "test_func".to_string(),
            args: vec![json!("arg1"), json!(42)],
            id: -123,
        };
        let encoded = cmd.encode();
        assert_eq!(
            encoded,
            json!(["call", "test_func", [json!("arg1"), json!(42)], -123])
        );

        // Test redraw encoding
        let cmd = ChannelCommand::Redraw { force: true };
        let encoded = cmd.encode();
        assert_eq!(encoded, json!(["redraw", "force"]));
    }
}
