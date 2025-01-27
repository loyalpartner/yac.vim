#![feature(mpmc_channel)]

use std::collections::HashMap;
use std::env;
use std::fs::File;
use std::io::{BufRead, BufReader, Read, Write};
use std::path::PathBuf;
use std::process::Child;
use std::str::FromStr;
use std::sync::mpmc::{Receiver, Sender, channel};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;

use anyhow::Result;
use derive_builder::Builder;
use lsp_bridge::{Message, Notification, Request, RequestId, Response};
use serde::{Deserialize, Serialize};

struct MessageQueue<T> {
    message_sender: Sender<T>,
    message_receiver: Receiver<T>,
}

impl<T> MessageQueue<T> {
    fn new() -> Self {
        let (message_sender, message_receiver) = std::sync::mpmc::channel();
        Self { message_sender, message_receiver }
    }

    fn enqueue(&self, message: T) {
        self.message_sender.send(message).unwrap();
    }

    fn dequeue(&self) -> Option<T> {
        self.message_receiver.recv().ok()
    }
}

struct LspServerSender {
    queue: MessageQueue<String>,
    child: Arc<Mutex<Child>>,
    server_name: String,
    project_name: String,
}

impl LspServerSender {
    fn new(child: &Arc<Mutex<Child>>, server_name: &str, project_name: &str) -> Self {
        Self {
            queue: MessageQueue::new(),
            child: child.clone(),
            server_name: server_name.to_string(),
            project_name: project_name.to_string(),
        }
    }

    fn send_request(&self, id: RequestId, method: String, params: impl Serialize) {
        let msg =
            Message::Request(Request { id, method, params: serde_json::to_value(params).unwrap() });
        self.send(msg);
    }

    fn send(&self, message: Message) {
        self.queue.enqueue(serde_json::to_string(&message).unwrap());
    }

    fn start(&self) {
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
                    if let Some(message) = self.queue.dequeue() {
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
    fn new(child: &Arc<Mutex<Child>>, event_sender: &Sender<Event>) -> Self {
        Self {
            queue: MessageQueue::new(),
            child: child.clone(),
            event_sender: event_sender.clone(),
        }
    }

    fn emit(&self, event: Event) {
        self.event_sender.send(event).unwrap();
    }

    fn get_message(&self) -> Option<Message> {
        self.queue.dequeue()
    }

    fn start(&self) {
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
                        log::info!("接收消息: {}", &buffer);

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

#[derive(Debug, Serialize, Deserialize, Default)]
struct LspConfig {
    name: String,
    language_id: String,
    command: Option<Vec<String>>,
    settings: Option<serde_json::Value>,
    initialization_options: Option<serde_json::Value>,
}

#[derive(Debug, Clone)]
enum Event {
    EventResponse(Response),
    EventNotification(Notification),
    EventAction,
}

enum Action {}

#[derive(Builder)]
struct LspServer {
    sender: Arc<LspServerSender>,
    receiver: Arc<LspSenderReceiver>,

    event_sender: Sender<Event>,

    // send_thread: Option<JoinHandle<()>>,
    // receive_thread: Option<JoinHandle<()>>,
    project_path: String,
    project_name: String,
    lsp_config: Arc<LspConfig>,
    initialize_id: RequestId,
    // server_name: String,
    // enable_diagnostics: bool,
    request_map: HashMap<RequestId, String>,
    // root_path: String,
    // workspace_folder: Option<String>,
    // completion_resolve_provider,
    // rename_prepare_provider
    // code_action_provider
    // code_format_provider
    // range_format_provider
    // signature_help_provider
    // workspace_symbol_provider
    // inlay_hint_provider
    // semantic_tokens_provider
}

impl LspServer {
    fn server_name(&self) -> String {
        format!("{}#{}", self.project_path, self.lsp_config.name)
    }
}

impl LspServer {
    fn new(event_sender: &Sender<Event>, lsp_config: LspConfig, project_path: &str) -> Self {
        let child = std::process::Command::new("rust-analyzer")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();

        let child = Arc::new(Mutex::new(child));

        // TODO: refactor
        let project_name = project_path
            .parse::<PathBuf>()
            .unwrap()
            .file_name()
            .unwrap()
            .to_string_lossy()
            .to_string();

        let receiver = LspSenderReceiver::new(&child, event_sender);
        let sender = LspServerSender::new(&child, &lsp_config.name, &project_name);

        let receiver = Arc::new(receiver);
        let sender = Arc::new(sender);

        let lsp = LspServerBuilder::default()
            .sender(sender.clone())
            .receiver(receiver.clone())
            .event_sender(event_sender.clone())
            .project_path(project_path.into())
            .project_name(project_name)
            .lsp_config(Arc::new(lsp_config))
            .initialize_id(RequestId::generate_id())
            .request_map(HashMap::new())
            .build()
            .unwrap();

        std::thread::spawn(move || sender.start());
        std::thread::spawn(move || receiver.start());

        lsp
    }

    fn lsp_message_loop(&self) {
        while let Some(message) = self.receiver.get_message() {
            self.handle_recv_message(message);
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

        self.sender.send_request(RequestId::generate_id(), "initialize".into(), initialize_params);
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

struct IoThreads {
    reader: std::thread::JoinHandle<std::io::Result<()>>,
    writer: std::thread::JoinHandle<std::io::Result<()>>,
}

impl IoThreads {
    pub fn join(self) -> std::io::Result<()> {
        match self.reader.join() {
            Ok(r) => r?,
            Err(err) => std::panic::panic_any(err),
        }

        match self.writer.join() {
            Ok(w) => w,
            Err(err) => std::panic::panic_any(err),
        }
    }
}

struct LspBridge {
    event_chan: (Sender<Event>, Receiver<Event>),

    // msg_chan: (Sender<Ev>)
    lsp_servers: HashMap<String, Arc<LspServer>>,

    io_threads: IoThreads,

    msg_sender: Sender<String>,     // msg send to vim
    msg_receiver: Receiver<String>, // msg recv from vim
}

impl LspBridge {
    fn new() -> Self {
        let (sender, receiver, io_threads) = Self::stdio();

        Self {
            event_chan: channel(),
            lsp_servers: HashMap::new(),
            msg_sender: sender,
            msg_receiver: receiver,
            io_threads,
        }
    }

    fn stdio() -> (Sender<String>, Receiver<String>, IoThreads) {
        let (writer_sender, writer_receiver) = channel::<String>();
        let write_thread = std::thread::Builder::new()
            .name("LspBridgeWriter".to_owned())
            .spawn(move || {
                let stdout = std::io::stdout();
                let mut stdout = stdout.lock();
                writer_receiver.into_iter().try_for_each(|it| {
                    stdout
                        .write(it.as_bytes())
                        .map(|_| ())
                        .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))
                })
            })
            .unwrap();

        let (reader_sender, reader_receiver) = channel::<String>();
        let read_thread = std::thread::Builder::new()
            .name("LspBridgeReader".to_owned())
            .spawn(move || {
                let stdin = std::io::stdin();
                let mut stdin = stdin.lock();

                let mut line = String::new();
                while let Ok(n) = stdin.read_line(&mut line) {
                    log::info!("read line {} size", n);
                    // TODO: 处理退出消息
                    if let Err(e) = reader_sender.send(line.clone()) {
                        log::error!("handle vim message error");
                        return Err(std::io::Error::new(std::io::ErrorKind::Other, e));
                    }
                    line.clear();
                }
                Ok(())
            })
            .unwrap();

        let threads = IoThreads { reader: read_thread, writer: write_thread };

        (writer_sender, reader_receiver, threads)
    }

    fn init_lsp_servers(&mut self) {
        let lsp_config = LspConfig::default();
        let lsp_server = Arc::new(LspServer::new(&self.event_chan.0, lsp_config, "/home/lee"));
        std::thread::spawn({
            let lsp_server = lsp_server.clone();
            move || lsp_server.lsp_message_loop()
        });

        lsp_server.send_inittialize_request();
        self.lsp_servers.insert("i......".into(), lsp_server);
    }

    fn message_loop(&self) -> JoinHandle<()> {
        let msg_receiver = self.msg_receiver.clone();
        std::thread::Builder::new()
            .name("LspBridgeMessageLoop".into())
            .spawn(move || {
                loop {
                    match msg_receiver.recv() {
                        Err(e) => log::error!("error {:?}", e),
                        Ok(msg) => {
                            log::info!("recv msg from vim {}.", msg);
                        }
                    }
                }
            })
            .unwrap()
    }

    fn event_loop(&self) -> JoinHandle<()> {
        let event_receiver = self.event_chan.1.clone();
        std::thread::Builder::new()
            .name("LspBridgeMessageLoop".into())
            .spawn(move || {
                loop {
                    match event_receiver.recv() {
                        Ok(Event::EventAction) => log::info!("action"),
                        Ok(_) => log::info!("other"),
                        Err(e) => log::error!("error {:?}", e),
                    }
                }
            })
            .unwrap()
    }

    #[allow(dead_code)]
    fn try_completion(&self) {
        self.event_chan.0.send(Event::EventAction).unwrap();
    }
}

fn main() -> Result<()> {
    let env = env_logger::Env::default().default_filter_or("info");

    if let Ok(logfile) = env::var("LSP_BRIDGE_LOG_FILE") {
        let target = Box::new(File::create(logfile)?);
        env_logger::Builder::from_env(env).target(env_logger::Target::Pipe(target)).init();
    } else {
        env_logger::Builder::from_env(env).init();
    }

    let mut lsp_bridge = LspBridge::new();
    lsp_bridge.init_lsp_servers();

    // let
    lsp_bridge.try_completion();
    let event_handle = lsp_bridge.event_loop();
    let msg_handle = lsp_bridge.message_loop();

    event_handle.join().unwrap();
    msg_handle.join().unwrap();

    Ok(())
}
