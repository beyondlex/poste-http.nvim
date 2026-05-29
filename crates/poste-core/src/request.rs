use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub enum Protocol {
    Http,
    Redis,
    Mysql,
    Postgres,
    Mongodb,
    Amqp,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Request {
    pub name: Option<String>,
    pub protocol: Protocol,
    pub connection: String,
    pub body: String,
}
