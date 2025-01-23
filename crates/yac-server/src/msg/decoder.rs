use serde::{Deserialize, Deserializer};
use serde_json::Value;

use super::{Message, Notification, Request, RequestId, Response};

impl<'de> Deserialize<'de> for Message {
    fn deserialize<D>(deserializer: D) -> Result<Message, D::Error>
    where
        D: Deserializer<'de>,
    {
        let arr: Vec<Value> = Vec::deserialize(deserializer)?;

        if arr.len() != 3 {
            return Err(serde::de::Error::custom("Invalid message"));
        }

        let id = arr[0].as_i64().ok_or_else(|| serde::de::Error::custom("Invalid id"))?;
        let method =
            arr[1].as_str().ok_or_else(|| serde::de::Error::custom("Invalid method"))?.to_string();
        let params = arr[2].clone();

        let clone_id = id.clone();
        let id = RequestId::from(clone_id as i32);

        match clone_id {
            1.. => Ok(Message::from(Request::new(id, method, params))),
            0 => Ok(Message::from(Notification::new(method, params))),
            ..0 => Ok(Message::from(Response::new(id, method, params))),
        }
    }
}
