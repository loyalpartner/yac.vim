use std::collections::VecDeque;
use std::io::{BufRead, BufReader, Write};
use std::process::Child;
use std::sync::{Arc, Mutex};

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
    fn new(queue: MessageQueue<String>, child: Arc<Mutex<Child>>) -> Self {
        Self { queue, child }
    }

    fn send(&self, message: String) {
        self.queue.push(message);
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
                        let message = format!("{}\r\n", message);
                        stdin.write(message.as_bytes()).unwrap();
                        println!("发送消息: {:?}", message);
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
    queue: MessageQueue<String>,
    child: Arc<Mutex<Child>>,
}

impl LspSenderReceiver {
    fn new(queue: MessageQueue<String>, child: Arc<Mutex<Child>>) -> Self {
        Self { queue, child }
    }

    fn run(&self) {
        let stdout = {
            let mut child = self.child.lock().unwrap();
            child.stdout.take().unwrap()
        };
        let mut reader = BufReader::new(stdout);

        loop {
            let status = { self.child.lock().unwrap().try_wait() };
            match status {
                Ok(Some(status)) => {
                    println!("子进程退出: {:?}", status);
                    break;
                }
                Ok(None) => {
                    let mut line = String::new();
                    if let Ok(_) = reader.read_line(&mut line) {
                        println!("接收消息: {:?}", line);
                        self.queue.push(line);
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

fn main() {
    let child = std::process::Command::new("cat")
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    let child = Arc::new(Mutex::new(child));

    let receiver = Arc::new(LspSenderReceiver::new(MessageQueue::new(), child.clone()));
    let sender = Arc::new(LspServerSender::new(MessageQueue::new(), child.clone()));

    let receiver_thread = std::thread::spawn({
        let receiver = receiver.clone();
        move || {
            receiver.run();
        }
    });
    let sender_thread = std::thread::spawn({
        let sender = sender.clone();
        move || {
            sender.run();
        }
    });

    // lsp_types::request::Initialize:

    sender.send("hello".to_string());
    sender.send("hello".to_string());
    // sender.send("hello".to_string());

    sender_thread.join().unwrap();
    receiver_thread.join().unwrap();
    println!("Hello, world!");
}
