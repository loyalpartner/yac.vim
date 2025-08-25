use lsp_bridge::LspRegistry;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tracing::info;
use vim::Vim;

mod handlers;
use handlers::{
    // Core LSP functionality handlers - Linus style: simple and clear
    CallHierarchyHandler,
    CodeActionHandler,
    CompletionHandler,
    DiagnosticsHandler,
    // Document lifecycle handlers
    DidChangeHandler,
    DidCloseHandler,
    DidSaveHandler,
    DocumentSymbolsHandler,
    ExecuteCommandHandler,
    FileOpenHandler,
    FileSearchHandler,
    FoldingRangeHandler,
    GotoHandler,
    HoverHandler,
    InlayHintsHandler,
    ReferencesHandler,
    RenameHandler,
    WillSaveHandler,
};

/// Stdio to Unix socket forwarder for local bridge mode
/// This function implements proper stdio-to-socket forwarding:
/// - stdin (vim messages) -> Unix socket -> remote lsp-bridge
/// - remote lsp-bridge -> Unix socket -> stdout (vim)
///
/// Local bridge executes NO LSP logic - just forwards data through socket
async fn run_stdio_to_socket_forwarder(
    socket_path: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    info!("Starting stdio-to-socket forwarder for: {}", socket_path);

    use tokio::net::UnixStream;

    // Connect to the Unix socket (established via SSH tunnel)
    let socket = match UnixStream::connect(socket_path).await {
        Ok(s) => {
            info!("Successfully connected to Unix socket: {}", socket_path);
            s
        }
        Err(e) => {
            info!("Failed to connect to Unix socket {}: {}", socket_path, e);
            return Err(e.into());
        }
    };

    let (socket_reader, socket_writer) = socket.into_split();

    let mut stdin = BufReader::new(tokio::io::stdin());
    let mut stdout = tokio::io::stdout();
    let mut socket_reader = BufReader::new(socket_reader);
    let mut socket_writer = tokio::io::BufWriter::new(socket_writer);

    info!("Setting up bidirectional stdio-socket forwarding");

    // Forward stdin to socket
    let stdin_to_socket = async {
        let mut line = String::new();
        loop {
            line.clear();
            match stdin.read_line(&mut line).await {
                Ok(0) => {
                    info!("stdin EOF - closing socket writer");
                    let _ = socket_writer.shutdown().await;
                    break;
                }
                Ok(_) => {
                    if let Err(e) = socket_writer.write_all(line.as_bytes()).await {
                        info!("Failed to write to socket: {}", e);
                        break;
                    }
                    if let Err(e) = socket_writer.flush().await {
                        info!("Failed to flush socket: {}", e);
                        break;
                    }
                }
                Err(e) => {
                    info!("stdin read error: {}", e);
                    break;
                }
            }
        }
    };

    // Forward socket to stdout
    let socket_to_stdout = async {
        let mut line = String::new();
        loop {
            line.clear();
            match socket_reader.read_line(&mut line).await {
                Ok(0) => {
                    info!("Socket EOF");
                    break;
                }
                Ok(_) => {
                    if let Err(e) = stdout.write_all(line.as_bytes()).await {
                        info!("Failed to write to stdout: {}", e);
                        break;
                    }
                    if let Err(e) = stdout.flush().await {
                        info!("Failed to flush stdout: {}", e);
                        break;
                    }
                }
                Err(e) => {
                    info!("Socket read error: {}", e);
                    break;
                }
            }
        }
    };

    // Run both forwarding directions concurrently
    tokio::select! {
        _ = stdin_to_socket => {
            info!("stdin to socket forwarding completed");
        },
        _ = socket_to_stdout => {
            info!("socket to stdout forwarding completed");
        }
    }

    info!("Stdio-socket forwarder terminated");
    Ok(())
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    use std::fs::OpenOptions;
    use tracing_subscriber::{fmt, layer::SubscriberExt, util::SubscriberInitExt};

    let pid = std::process::id();
    let log_path = format!("/tmp/lsp-bridge-{}.log", pid);

    let log_file = OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .open(&log_path)?;

    tracing_subscriber::registry()
        .with(fmt::layer().with_writer(log_file).with_ansi(false))
        .init();

    info!("LSP Bridge started with PID: {}", pid);
    info!("Log file: {}", log_path);

    let lsp_registry = std::sync::Arc::new(LspRegistry::new());

    // Bridge mode selection:
    // - YAC_REMOTE_SOCKET set: Local bridge (stdio-to-socket forwarder)
    // - YAC_UNIX_SOCKET set: Remote bridge (server mode for LSP processing)
    // - Neither set: Standard local mode (stdio)

    // Check for local bridge forwarding mode first
    if let Ok(remote_socket) = std::env::var("YAC_REMOTE_SOCKET") {
        info!(
            "Starting local bridge mode (stdio-to-socket): {}",
            remote_socket
        );
        run_stdio_to_socket_forwarder(&remote_socket).await?;
        return Ok(()); // Pure forwarder - no vim client needed
    }

    let mut vim = if let Ok(socket_path) = std::env::var("YAC_UNIX_SOCKET") {
        info!(
            "Starting Unix socket server mode (remote bridge): {}",
            socket_path
        );
        Vim::new_unix_socket_server(&socket_path).await?
    } else {
        info!("Starting stdio mode (standard local)");
        Vim::new_stdio()
    };

    // Proactively communicate log file path to Vim via call_async
    // This implements the hybrid approach suggested by loyalpartner
    if let Err(e) = vim
        .call_async("yac#set_log_file", vec![log_path.clone().into()])
        .await
    {
        info!("Failed to set log file path in Vim: {}", e);
    } else {
        info!("Successfully communicated log path to Vim: {}", log_path);
    }

    // Create dedicated handlers with multi-language registry
    // Core LSP functionality handlers - Linus style: one handler per function
    let file_open_handler = FileOpenHandler::new(lsp_registry.clone());
    let file_search_handler = FileSearchHandler::new(lsp_registry.clone());
    // Linus-style: 一个构造函数，数据驱动
    let definition_handler = GotoHandler::new(lsp_registry.clone(), "goto_definition").unwrap();
    let declaration_handler = GotoHandler::new(lsp_registry.clone(), "goto_declaration").unwrap();
    let type_definition_handler =
        GotoHandler::new(lsp_registry.clone(), "goto_type_definition").unwrap();
    let implementation_handler =
        GotoHandler::new(lsp_registry.clone(), "goto_implementation").unwrap();
    let hover_handler = HoverHandler::new(lsp_registry.clone());
    let completion_handler = CompletionHandler::new(lsp_registry.clone());
    let references_handler = ReferencesHandler::new(lsp_registry.clone());
    let inlay_hints_handler = InlayHintsHandler::new(lsp_registry.clone());
    let rename_handler = RenameHandler::new(lsp_registry.clone());
    let code_action_handler = CodeActionHandler::new(lsp_registry.clone());
    let execute_command_handler = ExecuteCommandHandler::new(lsp_registry.clone());
    let document_symbols_handler = DocumentSymbolsHandler::new(lsp_registry.clone());
    let call_hierarchy_handler = CallHierarchyHandler::new(lsp_registry.clone());
    let folding_range_handler = FoldingRangeHandler::new(lsp_registry.clone());
    let diagnostics_handler = DiagnosticsHandler::new(lsp_registry.clone());

    // Document lifecycle handlers
    let did_change_handler = DidChangeHandler::new(lsp_registry.clone());
    let did_close_handler = DidCloseHandler::new(lsp_registry.clone());
    let did_save_handler = DidSaveHandler::new(lsp_registry.clone());
    let will_save_handler = WillSaveHandler::new(lsp_registry.clone());

    // Register all handlers using the vim crate API
    vim.add_handler("file_open", file_open_handler);
    vim.add_handler("file_search", file_search_handler);
    vim.add_handler("goto_definition", definition_handler);
    vim.add_handler("goto_declaration", declaration_handler);
    vim.add_handler("goto_type_definition", type_definition_handler);
    vim.add_handler("goto_implementation", implementation_handler);
    vim.add_handler("hover", hover_handler);
    vim.add_handler("completion", completion_handler);
    vim.add_handler("references", references_handler);
    vim.add_handler("inlay_hints", inlay_hints_handler);
    vim.add_handler("rename", rename_handler);
    vim.add_handler("code_action", code_action_handler);
    vim.add_handler("execute_command", execute_command_handler);
    vim.add_handler("document_symbols", document_symbols_handler);
    vim.add_handler("call_hierarchy", call_hierarchy_handler);
    vim.add_handler("folding_range", folding_range_handler);
    vim.add_handler("diagnostics", diagnostics_handler);

    // Document lifecycle handlers
    vim.add_handler("did_change", did_change_handler);
    vim.add_handler("did_close", did_close_handler);
    vim.add_handler("did_save", did_save_handler);
    vim.add_handler("will_save", will_save_handler);

    // Start the message processing loop
    vim.run().await?;

    Ok(())
}
