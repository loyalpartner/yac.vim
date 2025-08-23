//! LSP request handlers
//!
//! This module contains all LSP request handlers organized by functionality.
//! Each handler implements the `Handler` trait from the vim crate.

// Common types and utilities - Linus-style: only truly shared code
pub mod common;

// Core LSP functionality handlers - simple and clear
pub mod call_hierarchy;
pub mod code_action;
pub mod completion;
pub mod diagnostics;
pub mod document_symbols;
pub mod execute_command;
pub mod file_open;
pub mod folding_range;
pub mod goto; // Unified handler for all goto operations
pub mod goto_definition_notification;
pub mod hover;
pub mod inlay_hints;
pub mod references;
pub mod rename;

// Document lifecycle handlers
pub mod did_change;
pub mod did_close;
pub mod did_save;
pub mod will_save;

// Re-export main handler types used in main.rs - Linus style: clear and simple
pub use call_hierarchy::CallHierarchyHandler;
pub use code_action::CodeActionHandler;
pub use completion::CompletionHandler;
pub use diagnostics::DiagnosticsHandler;
pub use document_symbols::DocumentSymbolsHandler;
pub use execute_command::ExecuteCommandHandler;
pub use file_open::FileOpenHandler;
pub use folding_range::FoldingRangeHandler;
pub use goto::GotoHandler; // Unified goto handler
pub use goto_definition_notification::GotoDefinitionNotificationHandler;
pub use hover::HoverHandler;
pub use inlay_hints::InlayHintsHandler;
pub use references::ReferencesHandler;
pub use rename::RenameHandler;

// Document lifecycle handlers
pub use did_change::DidChangeHandler;
pub use did_close::DidCloseHandler;
pub use did_save::DidSaveHandler;
pub use will_save::WillSaveHandler;
