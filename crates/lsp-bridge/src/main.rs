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
    FoldingRangeHandler,
    GotoHandler,
    HoverHandler,
    InlayHintsHandler,
    // Notification handlers
    NotificationRegistrationHandler,
    ReferencesHandler,
    RenameHandler,
    WillSaveHandler,
};

// Notification handler implementation removed for now to avoid dead code warnings
// The enhanced notification handler is available in the handlers module

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
        .with(
            fmt::layer()
                .with_writer(log_file)
                .with_ansi(false)
                .with_file(true)
                .with_line_number(true),
        )
        .init();

    info!("lsp-bridge starting with log: {}", log_path);

    // Create shared LSP client
    let shared_lsp_client = std::sync::Arc::new(tokio::sync::Mutex::new(None));

    // Create vim client with handler
    let mut vim = Vim::new_stdio();

    // Create dedicated handlers with shared client
    // Core LSP functionality handlers - Linus style: one handler per function
    let file_open_handler = FileOpenHandler::new(shared_lsp_client.clone());
    // Linus-style: 一个构造函数，数据驱动
    let definition_handler =
        GotoHandler::new(shared_lsp_client.clone(), "goto_definition").unwrap();
    let declaration_handler =
        GotoHandler::new(shared_lsp_client.clone(), "goto_declaration").unwrap();
    let type_definition_handler =
        GotoHandler::new(shared_lsp_client.clone(), "goto_type_definition").unwrap();
    let implementation_handler =
        GotoHandler::new(shared_lsp_client.clone(), "goto_implementation").unwrap();
    let hover_handler = HoverHandler::new(shared_lsp_client.clone());
    let completion_handler = CompletionHandler::new(shared_lsp_client.clone());
    let references_handler = ReferencesHandler::new(shared_lsp_client.clone());
    let inlay_hints_handler = InlayHintsHandler::new(shared_lsp_client.clone());
    let rename_handler = RenameHandler::new(shared_lsp_client.clone());
    let document_symbols_handler = DocumentSymbolsHandler::new(shared_lsp_client.clone());
    let folding_range_handler = FoldingRangeHandler::new(shared_lsp_client.clone());
    let diagnostics_handler = DiagnosticsHandler::new(shared_lsp_client.clone());
    let code_action_handler = CodeActionHandler::new(shared_lsp_client.clone());
    let execute_command_handler = ExecuteCommandHandler::new(shared_lsp_client.clone());
    let call_hierarchy_handler = CallHierarchyHandler::new(shared_lsp_client.clone());

    // Document lifecycle handlers
    let did_save_handler = DidSaveHandler::new(shared_lsp_client.clone());
    let did_change_handler = DidChangeHandler::new(shared_lsp_client.clone());
    let will_save_handler = WillSaveHandler::new(shared_lsp_client.clone());
    let did_close_handler = DidCloseHandler::new(shared_lsp_client.clone());

    // Create a channel for LSP server notifications
    let (notification_tx, _notification_rx) = tokio::sync::mpsc::unbounded_channel();

    // Notification registration handler - allows Vim to request specific notification types
    let notification_registration_handler =
        NotificationRegistrationHandler::new(shared_lsp_client.clone(), notification_tx);

    // Register handlers for all supported commands
    // Core LSP functionality - Linus style: type-safe dispatch
    vim.add_handler("file_open", file_open_handler);
    vim.add_handler("hover", hover_handler);
    vim.add_handler("completion", completion_handler);
    vim.add_handler("references", references_handler);
    vim.add_handler("inlay_hints", inlay_hints_handler);
    vim.add_handler("rename", rename_handler);
    vim.add_handler("document_symbols", document_symbols_handler);
    vim.add_handler("folding_range", folding_range_handler);
    vim.add_handler("diagnostics", diagnostics_handler);
    vim.add_handler("code_action", code_action_handler);
    vim.add_handler("execute_command", execute_command_handler);
    vim.add_handler("call_hierarchy_incoming", call_hierarchy_handler.clone());
    vim.add_handler("call_hierarchy_outgoing", call_hierarchy_handler);

    // Notification handlers
    vim.add_handler("goto_definition", definition_handler);
    vim.add_handler("goto_declaration", declaration_handler);
    vim.add_handler("goto_type_definition", type_definition_handler);
    vim.add_handler("goto_implementation", implementation_handler);

    // Document lifecycle handlers
    vim.add_handler("did_save", did_save_handler);
    vim.add_handler("did_change", did_change_handler);
    vim.add_handler("will_save", will_save_handler);
    vim.add_handler("did_close", did_close_handler);

    // Notification management handlers
    vim.add_handler("register_notifications", notification_registration_handler);

    info!("vim client configured, starting message loop...");

    // For now, we'll integrate notification handling into the main vim message loop
    // The enhanced notification handler will use the channel to send VimActions
    // which will be processed by the LSP bridge and forwarded appropriately

    // Run the vim client - this replaces the manual stdin/stdout loop
    // The notification handling is integrated into the LSP client background task
    vim.run().await?;

    info!("lsp-bridge shutting down...");
    Ok(())
}
