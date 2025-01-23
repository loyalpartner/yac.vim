use serde::de::DeserializeOwned;
use serde_derive::{Deserialize, Serialize};

use crate::RequestId;
use crate::error::ExtractError;

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct Notification {
    pub id: RequestId,
    pub method: String,
    #[serde(default = "serde_json::Value::default")]
    #[serde(skip_serializing_if = "serde_json::Value::is_null")]
    pub params: serde_json::Value,
}

impl Notification {
    pub fn new(method: String, params: impl serde::Serialize) -> Notification {
        Notification {
            id: RequestId::from(0),
            method,
            params: serde_json::to_value(params).unwrap(),
        }
    }
    pub fn extract<P: DeserializeOwned>(
        self,
        method: &str,
    ) -> Result<P, ExtractError<Notification>> {
        if self.method != method {
            return Err(ExtractError::MethodMismatch(self));
        }
        match serde_json::from_value(self.params) {
            Ok(params) => Ok(params),
            Err(error) => Err(ExtractError::JsonError { method: self.method, error }),
        }
    }
    #[allow(dead_code)]
    pub(crate) fn is_exit(&self) -> bool {
        self.method == "exit"
    }
    #[allow(dead_code)]
    pub(crate) fn is_initialized(&self) -> bool {
        self.method == "initialized"
    }
}
