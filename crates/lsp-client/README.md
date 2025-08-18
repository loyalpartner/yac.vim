# LSP Client

A **proper** LSP client implementation that solves real problems, not just JSON serialization.

## What This Actually Does

Unlike naive "LSP clients" that are just JSON serializers, this implementation handles:

1. **Transport Layer**: Process spawning, stdin/stdout communication, proper message framing
2. **Protocol Layer**: JSON-RPC 2.0 message routing, request/response matching
3. **State Management**: LSP lifecycle (uninitialized → initialized → shutdown)
4. **Concurrency**: Async request/response handling without blocking
5. **Error Recovery**: Process failures, protocol errors, timeouts

## Core Design Principles

### 1. Message Framing
LSP uses Content-Length headers for message framing:
```
Content-Length: 123\r\n\r\n{"jsonrpc":"2.0",...}
```

The `MessageFramer` handles this correctly, including partial message buffering.

### 2. Process Management
Spawns LSP server as child process with proper stdio piping:
```rust
let mut client = LspClient::new("rust-analyzer", &[]).await?;
```

### 3. Request/Response Matching
Uses oneshot channels to match responses with pending requests:
```rust
let response: InitializeResult = client
    .send_request("initialize", init_params)
    .await?;
```

### 4. State Machine
Enforces proper LSP state transitions:
- `Uninitialized` → `Initializing` → `Initialized` → `ShuttingDown` → `Shutdown`

## Usage

```rust
use lsp_client::{LspClient, Result};
use lsp_types::{InitializeParams, ClientCapabilities};

#[tokio::main]
async fn main() -> Result<()> {
    // Connect to LSP server
    let mut client = LspClient::new("rust-analyzer", &[]).await?;
    
    // Initialize
    let init_params = InitializeParams {
        process_id: Some(std::process::id()),
        capabilities: ClientCapabilities::default(),
        // ... other fields
    };
    
    let _response: serde_json::Value = client
        .send_request("initialize", init_params)
        .await?;
    
    // Send notifications
    client.send_notification("initialized", serde_json::json!({})).await?;
    
    // Graceful shutdown
    client.shutdown().await?;
    
    Ok(())
}
```

## What's NOT Here (Yet)

- Higher-level LSP semantic API (textDocument/completion, etc.)
- Connection pooling/multiplexing
- Server capability negotiation
- Incremental text synchronization

These belong in separate layers built on top of this transport.

## Architecture

```
┌─────────────────┐
│   LSP Methods   │  (textDocument/completion, etc.)
│   (Future)      │
├─────────────────┤
│   LspClient     │  ← This crate
│   (Transport)   │
├─────────────────┤
│   JSON-RPC      │
│   Message       │
│   Framing       │
└─────────────────┘
```

This crate implements the bottom layers. LSP-specific methods are built on top.

## Why This Approach

**Problem**: Most "LSP clients" are just JSON serializers that punt on the hard problems.

**Solution**: Handle the actual hard parts - process management, message framing, concurrency, error recovery.

**Result**: A transport layer you can actually build real LSP features on top of.

## Recent Improvements (Inspired by Zed)

After studying [Zed's LSP implementation](https://github.com/zed-industries/zed/blob/main/crates/lsp/src/lsp.rs), we've made several key improvements:

### 1. Proper RequestId Type
- **Before**: Simple `u64` counter
- **After**: `RequestId` enum supporting both numbers and strings per JSON-RPC spec
- **Why**: LSP servers may use either format

### 2. Thread-Safe Request ID Generation  
- **Before**: Mutable counter requiring `&mut self`
- **After**: `AtomicU32` with `fetch_add()` - truly concurrent
- **Why**: Multiple tasks can generate IDs safely

### 3. Detailed Error Classification
- **Before**: Generic `Protocol(String)` error
- **After**: Specific error types:
  - `ServerError { code, message, data }`
  - `ConnectionReset`
  - `InvalidResponse { request_id, reason }`
- **Why**: Better debugging and error recovery

### 4. Mock Server for Testing
- **Before**: No testing infrastructure
- **After**: `MockLspServer` with programmable handlers
- **Why**: Unit tests without real LSP servers

### 5. Better Request/Response Matching
- **Before**: Silent failures for unknown response IDs
- **After**: Explicit warnings with request ID logging
- **Why**: Easier debugging of protocol issues

These changes move us from "working prototype" to "production-grade transport layer".