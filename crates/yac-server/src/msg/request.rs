use serde::de::DeserializeOwned;
use serde_derive::{Deserialize, Serialize};

use crate::RequestId;
use crate::error::ExtractError;

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct Request {
    pub id: RequestId,
    pub method: String,
    #[serde(default = "serde_json::Value::default")]
    #[serde(skip_serializing_if = "serde_json::Value::is_null")]
    pub params: serde_json::Value,
}

impl Request {
    pub fn new<P: serde::Serialize>(id: RequestId, method: String, params: P) -> Request {
        Request { id, method, params: serde_json::to_value(params).unwrap() }
    }
    pub fn extract<P: DeserializeOwned>(
        self,
        method: &str,
    ) -> Result<(RequestId, P), ExtractError<Request>> {
        if self.method != method {
            return Err(ExtractError::MethodMismatch(self));
        }
        match serde_json::from_value(self.params) {
            Ok(params) => Ok((self.id, params)),
            Err(error) => Err(ExtractError::JsonError { method: self.method, error }),
        }
    }

    pub(crate) fn is_shutdown(&self) -> bool {
        self.method == "shutdown"
    }
    pub(crate) fn is_initialize(&self) -> bool {
        self.method == "initialize"
    }
}
