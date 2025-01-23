use log::debug;
use lsp_types::*;
use yac_server::{Connection, Message};

fn main() -> anyhow::Result<()> {
    // let mut buffer = String::new();
    // let mut stdin = std::io::stdin();
    // let mut stdin = stdin.lock();

    // stdin.read_line(&mut buffer);
    // stdin.read_line(&mut buffer);
    // println!("buffer: {}", buffer);

    env_logger::init();
    debug!("hello");
    let (connection, _io_threads) = Connection::stdio();

    // Run the server
    println!("initialize");

    let msg: Message = connection.receiver.recv()?;
    println!("msg: {:?}", msg);
    let (id, params) = connection.initialize_start()?;

    let init_params: InitializeParams = serde_json::from_value(params).unwrap();
    let _client_capabilities: ClientCapabilities = init_params.capabilities;
    let server_capabilities = ServerCapabilities::default();

    let initialize_data = serde_json::json!({
        "capabilities": server_capabilities,
        "serverInfo": {
            "name": "lsp-server-test",
            "version": "0.1"
        }
    });

    connection.initialize_finish(id, initialize_data)?;
    Ok(())
}
