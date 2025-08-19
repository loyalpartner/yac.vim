use lsp_client::{LspClient, Result};
use lsp_types::{
    ClientCapabilities, GotoDefinitionParams, InitializeParams, Position, TextDocumentIdentifier,
    TextDocumentPositionParams, Url,
};
use serde_json::json;

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt::init();

    // Connect to rust-analyzer
    match LspClient::new("rust-analyzer", &[]).await {
        Ok(client) => {
            println!("LSP client connected to rust-analyzer");

            // Smart path detection - handle both root and test_data directory execution
            let current_dir = std::env::current_dir().unwrap();
            let (test_project_root, test_file_path) = if current_dir.ends_with("test_data") {
                // Running from test_data directory
                (current_dir.clone(), current_dir.join("src").join("lib.rs"))
            } else {
                // Running from project root
                let test_root = current_dir.join("test_data");
                (test_root.clone(), test_root.join("src").join("lib.rs"))
            };

            println!("🔍 Looking for test file: {}", test_file_path.display());
            println!("📁 Current directory: {}", current_dir.display());
            println!("📦 Test project root: {}", test_project_root.display());

            // Initialize the LSP server with correct workspace
            #[allow(deprecated)]
            let init_params = InitializeParams {
                process_id: Some(std::process::id()),
                root_path: None,
                root_uri: Some(Url::from_file_path(&test_project_root).unwrap()),
                initialization_options: None,
                capabilities: ClientCapabilities::default(),
                trace: None,
                workspace_folders: None,
                client_info: None,
                locale: None,
            };

            println!("Initializing rust-analyzer...");

            // Initialize
            use lsp_types::request::Initialize;
            let result = tokio::time::timeout(
                std::time::Duration::from_secs(10),
                client.request::<Initialize>(init_params),
            )
            .await;

            match result {
                Ok(Ok(_response)) => {
                    println!("✅ rust-analyzer initialized");

                    // Send initialized notification
                    client.notify("initialized", json!({})).await?;

                    // Test goto definition on the test project
                    if test_file_path.exists() {
                        println!("✅ Test file found!");
                        let file_uri = Url::from_file_path(&test_file_path).unwrap();

                        // Open the document
                        let open_params = json!({
                            "textDocument": {
                                "uri": file_uri,
                                "languageId": "rust",
                                "version": 1,
                                "text": std::fs::read_to_string(&test_file_path).unwrap_or_default()
                            }
                        });

                        client.notify("textDocument/didOpen", open_params).await?;
                        println!("📄 Opened {}", test_file_path.display());

                        // Wait for rust-analyzer to index the project
                        println!("⏳ Waiting for rust-analyzer to analyze the project...");
                        tokio::time::sleep(std::time::Duration::from_secs(3)).await;

                        // Test specific positions from test_data/src/lib.rs (zero-based)
                        let test_cases = [
                            (
                                Position {
                                    line: 47,
                                    character: 16,
                                },
                                "User struct in test_user_creation",
                            ),
                            (
                                Position {
                                    line: 47,
                                    character: 22,
                                },
                                "::new method call in test",
                            ),
                            (
                                Position {
                                    line: 48,
                                    character: 22,
                                },
                                "user.get_name() call in test",
                            ),
                            (
                                Position {
                                    line: 31,
                                    character: 21,
                                },
                                "User::new in create_user_map",
                            ),
                            (
                                Position {
                                    line: 38,
                                    character: 41,
                                },
                                "user.get_name() in process_user",
                            ),
                        ];

                        for (position, description) in test_cases.iter() {
                            println!(
                                "\n🔍 Testing {} at line {}, char {}",
                                description, position.line, position.character
                            );

                            let definition_params = GotoDefinitionParams {
                                text_document_position_params: TextDocumentPositionParams {
                                    text_document: TextDocumentIdentifier {
                                        uri: file_uri.clone(),
                                    },
                                    position: *position,
                                },
                                work_done_progress_params: Default::default(),
                                partial_result_params: Default::default(),
                            };

                            use lsp_types::request::GotoDefinition;
                            let def_result = tokio::time::timeout(
                                std::time::Duration::from_secs(3),
                                client.request::<GotoDefinition>(definition_params),
                            )
                            .await;

                            match def_result {
                                Ok(Ok(response)) => {
                                    if response.is_none() {
                                        println!("  📍 No definition found at this position");
                                    } else {
                                        println!("  ✅ Definition found:");
                                        println!(
                                            "     {}",
                                            serde_json::to_string_pretty(&response)?
                                        );
                                    }
                                }
                                Ok(Err(e)) => {
                                    println!("  ❌ Error: {}", e);
                                }
                                Err(_) => {
                                    println!("  ⏰ Request timed out");
                                }
                            }
                        }

                        // Close the document
                        let close_params = json!({
                            "textDocument": {
                                "uri": file_uri
                            }
                        });
                        client.notify("textDocument/didClose", close_params).await?;
                    } else {
                        println!("❌ No src/lib.rs found. Testing with current file instead...");

                        // Use the current source file for testing
                        let current_file = std::env::current_exe()
                            .unwrap()
                            .parent()
                            .unwrap()
                            .parent()
                            .unwrap()
                            .parent()
                            .unwrap()
                            .join("src")
                            .join("lib.rs");

                        if current_file.exists() {
                            println!("📄 Testing with: {}", current_file.display());
                            // Same logic as above...
                        } else {
                            println!("⚠️  No suitable Rust file found for testing");
                        }
                    }
                }
                Ok(Err(e)) => {
                    println!("❌ LSP initialize failed: {}", e);
                }
                Err(_) => {
                    println!("⏰ LSP initialize timed out (10 seconds)");
                }
            }

            // Graceful shutdown
            println!("\n🔄 Shutting down...");
            client.notify("shutdown", json!({})).await?;
            client.notify("exit", json!({})).await?;

            println!("✅ Client shutdown complete");
            Ok(())
        }
        Err(e) => {
            println!("❌ Failed to connect to rust-analyzer: {}", e);
            println!("💡 Make sure rust-analyzer is installed and in PATH");
            println!("   Install with: rustup component add rust-analyzer");
            Ok(())
        }
    }
}
