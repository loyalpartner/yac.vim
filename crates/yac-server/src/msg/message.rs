use std::io::{self, BufRead, Write};

use serde_derive::Serialize;

use crate::{Notification, Request, Response};

#[derive(Serialize, Debug, Clone)]
#[serde(untagged)]
pub enum Message {
    Request(Request),
    Response(Response),
    Notification(Notification),
}

impl From<Request> for Message {
    fn from(request: Request) -> Message {
        Message::Request(request)
    }
}

impl From<Response> for Message {
    fn from(response: Response) -> Message {
        Message::Response(response)
    }
}

impl From<Notification> for Message {
    fn from(notification: Notification) -> Message {
        Message::Notification(notification)
    }
}

fn invalid_data(error: impl Into<Box<dyn std::error::Error + Send + Sync>>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, error)
}

macro_rules! invalid_data {
    ($($tt:tt)*) => (invalid_data(format!($($tt)*)))
}

impl Message {
    pub fn read(r: &mut impl BufRead) -> io::Result<Option<Message>> {
        Message::_read(r)
    }
    fn _read(r: &mut dyn BufRead) -> io::Result<Option<Message>> {
        let text = match read_msg_text(r)? {
            None => return Ok(None),
            Some(text) => text,
        };

        let msg = match serde_json::from_str(&text) {
            Ok(msg) => msg,
            Err(e) => {
                return Err(invalid_data!("malformed LSP payload: {:?}", e));
            }
        };

        Ok(Some(msg))
    }
    pub fn write(self, w: &mut impl Write) -> io::Result<()> {
        self._write(w)
    }
    fn _write(self, w: &mut dyn Write) -> io::Result<()> {
        #[derive(Serialize)]
        struct JsonRpc {
            jsonrpc: &'static str,
            #[serde(flatten)]
            msg: Message,
        }
        let text = serde_json::to_string(&JsonRpc { jsonrpc: "2.0", msg: self })?;
        write_msg_text(w, &text)
    }
}

fn read_msg_text(inp: &mut dyn BufRead) -> io::Result<Option<String>> {
    let mut buf = String::new();
    inp.read_line(&mut buf)?;
    log::debug!("< {}", buf);
    Ok(Some(buf))
}

fn write_msg_text(out: &mut dyn Write, msg: &str) -> io::Result<()> {
    log::debug!("> {}", msg);
    write!(out, "Content-Length: {}\r\n\r\n", msg.len())?;
    out.write_all(msg.as_bytes())?;
    out.flush()?;
    Ok(())
}

// #[cfg(test)]
// mod tests {
//     use super::{Message, Notification, Request, RequestId};

//     #[test]
//     fn shutdown_with_explicit_null() {
//         let text = "{\"jsonrpc\": \"2.0\",\"id\": 3,\"method\": \"shutdown\", \"params\": null }";
//         let msg: Message = serde_json::from_str(text).unwrap();

//         assert!(
//             matches!(msg, Message::Request(req) if req.id == 3.into() && req.method == "shutdown")
//         );
//     }

//     #[test]
//     fn shutdown_with_no_params() {
//         let text = "{\"jsonrpc\": \"2.0\",\"id\": 3,\"method\": \"shutdown\"}";
//         let msg: Message = serde_json::from_str(text).unwrap();

//         assert!(
//             matches!(msg, Message::Request(req) if req.id == 3.into() && req.method == "shutdown")
//         );
//     }

//     #[test]
//     fn notification_with_explicit_null() {
//         let text = "{\"jsonrpc\": \"2.0\",\"method\": \"exit\", \"params\": null }";
//         let msg: Message = serde_json::from_str(text).unwrap();

//         assert!(matches!(msg, Message::Notification(not) if not.method == "exit"));
//     }

//     #[test]
//     fn notification_with_no_params() {
//         let text = "{\"jsonrpc\": \"2.0\",\"method\": \"exit\"}";
//         let msg: Message = serde_json::from_str(text).unwrap();

//         assert!(matches!(msg, Message::Notification(not) if not.method == "exit"));
//     }

//     #[test]
//     fn serialize_request_with_null_params() {
//         let msg = Message::Request(Request {
//             id: RequestId::from(3),
//             method: "shutdown".into(),
//             params: serde_json::Value::Null,
//         });
//         let serialized = serde_json::to_string(&msg).unwrap();

//         assert_eq!("{\"id\":3,\"method\":\"shutdown\"}", serialized);
//     }

//     #[test]
//     fn serialize_notification_with_null_params() {
//         let msg = Message::Notification(Notification {
//             method: "exit".into(),
//             params: serde_json::Value::Null,
//         });
//         let serialized = serde_json::to_string(&msg).unwrap();

//         assert_eq!("{\"method\":\"exit\"}", serialized);
//     }
// }
