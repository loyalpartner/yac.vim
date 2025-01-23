use std::io::{self, BufRead, Write};

fn main() -> io::Result<()> {
    // 获取标准输入和标准输出的句柄
    let stdin = io::stdin();
    let mut stdout = io::stdout();

    // 创建一个 BufReader 来逐行读取标准输入
    let mut reader = stdin.lock();

    // 无限循环，持续读取输入
    loop {
        // 创建一个字符串缓冲区来存储输入
        let mut input = String::new();

        // 读取一行输入
        reader.read_line(&mut input)?;

        // 将输入的内容写入标准输出
        write!(stdout, "{}", input)?;

        // 刷新标准输出，确保内容立即显示
        stdout.flush()?;
    }
}
