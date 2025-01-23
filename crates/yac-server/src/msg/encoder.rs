use std::fmt::{self};

use serde::de::{self, Visitor};

use super::Message;

struct MessageVisitor;

impl<'de> Visitor<'de> for MessageVisitor {
    type Value = Message;

    fn expecting(&self, formatter: &mut fmt::Formatter) -> fmt::Result {
        formatter.write_str("a message must be a Request, Response, or Notification")
    }

    fn visit_seq<A>(self, seq: A) -> Result<Self::Value, A::Error>
    where
        A: de::SeqAccess<'de>,
    {
        let (id, method, params) = (
            seq.next_element()?.ok_or_else(|| de::Error::invalid_length(0, &self))?,
            seq.next_element()?.ok_or_else(|| de::Error::invalid_length(0, &self))?,
            seq.next_element()?.ok_or_else(|| de::Error::invalid_length(0, &self))?,
        );
    }
}
