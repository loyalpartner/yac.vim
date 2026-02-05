use lsp_bridge::LspRegistry;
use tracing::info;
use vim::VimClient;

mod handlers;
use handlers::*;

/// Register a handler: construct with registry and add to vim client
macro_rules! register {
    ($vim:expr, $reg:expr, $($name:expr => $handler:ty),+ $(,)?) => {
        $( $vim.add_handler($name, <$handler>::new($reg.clone())); )+
    };
}

// Removed: Complex stdio-to-socket forwarder
// SSH Master mode eliminates need for socket forwarding - direct SSH stdio connection

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

    // Simplified: SSH Master mode uses direct stdio communication
    // No need for complex socket forwarding - SSH handles the transport
    info!("Starting lsp-bridge in stdio mode");
    let mut vim = VimClient::new_stdio();

    // Register handlers - data-driven goto uses its own constructor
    for method in [
        "goto_definition",
        "goto_declaration",
        "goto_type_definition",
        "goto_implementation",
    ] {
        vim.add_handler(
            method,
            GotoHandler::new(lsp_registry.clone(), method).unwrap(),
        );
    }

    register!(vim, lsp_registry,
        "file_open"        => FileOpenHandler,
        "hover"            => HoverHandler,
        "completion"       => CompletionHandler,
        "references"       => ReferencesHandler,
        "inlay_hints"      => InlayHintsHandler,
        "rename"           => RenameHandler,
        "code_action"      => CodeActionHandler,
        "execute_command"   => ExecuteCommandHandler,
        "document_symbols" => DocumentSymbolsHandler,
        "call_hierarchy"   => CallHierarchyHandler,
        "folding_range"    => FoldingRangeHandler,
        "diagnostics"      => DiagnosticsHandler,
        "did_change"       => DidChangeHandler,
        "did_close"        => DidCloseHandler,
        "did_save"         => DidSaveHandler,
        "will_save"        => WillSaveHandler,
    );

    // Start the message processing loop
    vim.run().await?;

    Ok(())
}
