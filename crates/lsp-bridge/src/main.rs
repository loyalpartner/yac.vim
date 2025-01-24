use std::collections::{HashMap, VecDeque};
use std::io::{BufRead, BufReader, Read, Write};
use std::process::Child;
use std::str::FromStr;
use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;

use lsp_bridge::{Message, Notification, Request, RequestId, Response};
use serde::Serialize;

struct MessageQueue<T> {
    queue: Arc<Mutex<VecDeque<T>>>,
}

impl<T> MessageQueue<T> {
    fn new() -> Self {
        Self { queue: Arc::new(Mutex::new(VecDeque::new())) }
    }

    fn push(&self, message: T) {
        let mut queue = self.queue.lock().unwrap();
        queue.push_back(message);
    }

    fn pop(&self) -> Option<T> {
        let mut queue = self.queue.lock().unwrap();
        queue.pop_front()
    }
}

struct LspServerSender {
    queue: MessageQueue<String>,
    child: Arc<Mutex<Child>>,
}

impl LspServerSender {
    fn new(child: Arc<Mutex<Child>>) -> Self {
        Self { queue: MessageQueue::new(), child }
    }

    fn send_request(&self, id: RequestId, method: String, params: impl Serialize) {
        let msg =
            Message::Request(Request { id, method, params: serde_json::to_value(params).unwrap() });
        self.send(msg);
    }

    fn send(&self, message: Message) {
        self.queue.push(serde_json::to_string(&message).unwrap());
    }

    fn run(&self) {
        let mut stdin = {
            let mut child = self.child.lock().unwrap();
            child.stdin.take().unwrap()
        };
        loop {
            let status = { self.child.lock().unwrap().try_wait() };
            match status {
                Ok(Some(status)) => {
                    println!("子进程退出: {:?}", status);
                    break;
                }
                Ok(None) => {
                    if let Some(message) = self.queue.pop() {
                        let message =
                            format!("Content-Length: {}\r\n\r\n{}", message.len(), message);
                        stdin.write(message.as_bytes()).unwrap();
                        log::debug!("发送消息: {:?}", message);
                    }
                }
                Err(e) => {
                    println!("等待子进程退出失败: {:?}", e);
                    break;
                }
            }
        }
    }
}

struct LspSenderReceiver {
    queue: MessageQueue<Message>,
    event_sender: Sender<Event>,
    child: Arc<Mutex<Child>>,
}

impl LspSenderReceiver {
    fn new(child: Arc<Mutex<Child>>, event_sender: Sender<Event>) -> Self {
        Self { queue: MessageQueue::new(), child, event_sender }
    }

    fn emit(&self, event: Event) {
        self.event_sender.send(event).unwrap();
    }

    fn get_message(&self) -> Option<Message> {
        self.queue.pop()
    }

    fn run(&self) {
        let stdout = {
            let mut child = self.child.lock().unwrap();
            child.stdout.take().unwrap()
        };
        let mut reader = BufReader::new(stdout);

        let mut content_length = None;
        let mut buffer = String::new();

        loop {
            let status = { self.child.lock().unwrap().try_wait() };
            match status {
                Ok(Some(status)) => {
                    println!("子进程退出: {:?}", status);
                    break;
                }
                Ok(None) => match content_length {
                    None => {
                        if buffer.starts_with("Content-Length: ") {
                            content_length = buffer
                                .trim()
                                .strip_prefix("Content-Length: ")
                                .and_then(|s| usize::from_str(s).ok());
                            // strip \r\n
                            if content_length.is_some() {
                                reader.read_line(&mut buffer).unwrap();
                            }
                            buffer.clear();
                        } else {
                            let mut line = String::new();
                            reader.read_line(&mut line).unwrap();
                            buffer.push_str(&line);
                        }
                    }

                    Some(l) => {
                        let mut buf = vec![0; l];
                        reader.read_exact(&mut buf).unwrap();
                        buffer = String::from_utf8(buf).unwrap();
                        log::info!("接收消息: {:?}", &buffer);

                        match serde_json::from_str::<Message>(&buffer) {
                            Ok(Message::Response(response)) => {
                                self.emit(Event::EventResponse(response))
                            }
                            Ok(Message::Notification(notification)) => {
                                self.emit(Event::EventNotification(notification))
                            }
                            Ok(_) => {
                                unreachable!()
                            }
                            Err(e) => {
                                log::error!("反序列化失败: {:?}", e);
                            }
                        }

                        content_length = None;
                        buffer.clear();
                    }
                },
                Err(e) => {
                    log::error!("等待子进程退出失败: {:?}", e);
                    break;
                }
            }
        }
    }
}

#[derive(Debug, Clone)]
enum Event {
    EventResponse(Response),
    EventNotification(Notification),
}

struct LspServer {
    sender: Arc<LspServerSender>,
    receiver: Arc<LspSenderReceiver>,

    event_sender: Sender<Event>,

    send_thread: JoinHandle<()>,
    receive_thread: JoinHandle<()>,
}

impl LspServer {
    fn new(event_sender: Sender<Event>) -> Self {
        let child = std::process::Command::new("rust-analyzer")
            // let child = std::process::Command::new("cat")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();

        let child = Arc::new(Mutex::new(child));

        let receiver = LspSenderReceiver::new(child.clone(), event_sender.clone());
        let sender = LspServerSender::new(child.clone());

        let receiver = Arc::new(receiver);
        let sender = Arc::new(sender);

        let send_thread = std::thread::spawn({
            let sender = sender.clone();
            move || {
                sender.run();
            }
        });
        let receive_thread = std::thread::spawn({
            let receiver = receiver.clone();
            move || {
                receiver.run();
            }
        });

        Self { sender, receiver, send_thread, receive_thread, event_sender }
    }

    fn dispatch_lsp_message(&self) {
        loop {
            match self.receiver.get_message() {
                Some(message) => self.handle_recv_message(message),
                None => {
                    log::error!("接收消息失败");
                    break;
                }
            }
        }
    }

    fn send_inittialize_request(&self) {
        let initialize_params = lsp_types::InitializeParams {
            process_id: Some(std::process::id()),
            root_path: Some("/tmp/hello".to_string()),
            root_uri: Some(lsp_types::Uri::from_str(r#"file:///tmp/hello"#).unwrap()),
            client_info: Some(lsp_types::ClientInfo {
                name: "lsp-bridge".to_string(),
                version: Some("0.1".to_string()),
            }),

            ..lsp_types::InitializeParams::default()
        };

        self.sender.send_request(RequestId::from(1), "initialize".into(), initialize_params);
    }

    fn handle_recv_message(&self, message: Message) {
        // let request: Value = serde_json::from_str(&message);
        match message {
            Message::Request(_) => unreachable!(),
            Message::Notification(notif) => self.handle_notification(notif),
            Message::Response(response) => self.handle_response(response),
        }
    }

    fn handle_notification(&self, notification: Notification) {
        self.event_sender.send(Event::EventNotification(notification)).unwrap();
    }

    fn handle_response(&self, response: Response) {
        println!("处理请求: {:?}", response);

        if matches!(response.error, Some(_)) {
            log::error!("请求失败: {:?}", response.error);
            return;
        }

        if let Some(result) = response.result.clone() {
            log::info!("请求成功: {:?}", result);
            self.event_sender.send(Event::EventResponse(response)).unwrap();
        }
    }
}

struct LspBridge {
    event_sender: Sender<Event>,
    event_receiver: Receiver<Event>,

    lsp_servers: HashMap<String, Arc<LspServer>>,
}

impl LspBridge {
    fn new() -> Self {
        let (event_sender, event_receiver) = channel::<Event>();
        Self { event_sender, event_receiver, lsp_servers: HashMap::new() }
    }

    fn init_lsp_servers(&mut self) {
        let lsp_server = Arc::new(LspServer::new(self.event_sender.clone()));
        std::thread::spawn({
            let lsp_server = lsp_server.clone();
            move || {
                lsp_server.dispatch_lsp_message();
            }
        });

        lsp_server.send_inittialize_request();
        self.lsp_servers.insert("i......".into(), lsp_server);
    }

    #[allow(dead_code)]
    fn send_request(&self, message: String) {
        // self.event_sender.send(message).unwrap();
    }

    #[allow(dead_code)]
    fn try_completion(&self) {
        // self.send_request("completion".to_string());
    }
}

fn main() {
    env_logger::init();

    let mut lsp_bridge = LspBridge::new();
    lsp_bridge.init_lsp_servers();

    // lsp_bridge.try_completion();
    loop {
        let event = lsp_bridge.event_receiver.recv().unwrap();
        log::info!("收到消息: {:?}", event);
    }
}
