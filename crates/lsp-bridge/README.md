# lsp-bridge

A blazingly simple LSP bridge for Vim that forwards requests between editors and LSP servers.

## Architecture

```
Vim Plugin ↔ lsp-bridge (JSON/stdio) ↔ lsp-client ↔ LSP Servers
```

**Design Philosophy**: Unix-style simplicity - do one thing and do it well.

## Complete System

This repository provides a complete LSP solution for Vim:

### 1. **lsp-bridge** (This Crate)
- Simple Rust bridge program (~200 lines)
- Forwards LSP requests via stdin/stdout
- Zero configuration, single binary

### 2. **Vim Plugin** (Planned)
- VimScript plugin for seamless integration
- Job/channel based communication
- Commands: `:LspDefinition`, `:LspHover`, etc.

### 3. **lsp-client** (Library)
- Robust LSP communication library
- Handles JSON-RPC and message framing
- Comprehensive test coverage

## Quick Start

### Standalone Usage

```bash
# Start lsp-bridge
cargo run --bin lsp-bridge

# Test with example
cargo run --example bridge_goto_definition | cargo run --bin lsp-bridge
```

### With Vim Plugin (Future)

```vim
:LspStart
:LspDefinition  " Jump to definition
:LspHover       " Show hover information
```

## Communication Protocol

### Current (v0.1) - Basic Format
```json
{
  "method": "textDocument/definition",
  "params": { /* LSP standard params */ },
  "language": "rust", 
  "file_path": "/path/to/file.rs"
}
```

### Planned (v0.2) - Extended Format
```json
{
  "id": 1,                        // Request ID for matching
  "method": "textDocument/definition",
  "params": { /* LSP params */ },
  "context": {
    "file_path": "/path/to/file.rs",
    "language": "rust",
    "buffer_id": 1,               // Vim buffer identifier
    "workspace_root": "/project"
  }
}
```

## Supported LSP Methods

### Core (v0.1) ✅
- `textDocument/didOpen` - Document lifecycle
- `textDocument/definition` - Go to definition
- Custom `$/sleep` - Testing utility

### Planned (v0.2)
- `textDocument/hover` - Hover information
- `textDocument/completion` - Code completion
- `textDocument/didClose` - Document cleanup

## Language Support

### Current
- **Rust**: `rust-analyzer` ✅

### Planned  
- **Python**: `pyright` or `pylsp`
- **JavaScript/TypeScript**: `typescript-language-server`
- **Go**: `gopls`
- **C/C++**: `clangd`

## Examples

### Basic Definition Lookup
```bash
# Example output
{"result":{"status":"ok"},"error":null}                    # didOpen
{"result":{"status":"slept"},"error":null}                 # sleep (3s)
{"result":[{"range":{"start":{"line":13,"character":11},"end":{"character":14,"line":13}},"uri":"file:///path/to/lib.rs"}],"error":null}
```

### Error Handling
```bash
# When LSP server fails
{"result":null,"error":"Server error -32603: rust-analyzer crashed"}
```

## Comparison with manateelazycat/lsp-bridge

| Feature | manateelazycat | yac.vim lsp-bridge |
|---------|----------------|-------------------|
| **Target Editor** | Emacs | Vim |
| **Language** | Python (5000+ lines) | Rust (~400 lines total) |
| **Architecture** | Complex multi-threading | Simple async forwarding |
| **Protocol** | EPC (custom RPC) | JSON over stdio |
| **Features** | Full LSP client | Core bridging only |
| **Dependencies** | Python runtime | Single binary |
| **Complexity** | High | Minimal |

## Development Status

### v0.1.0 - MVP ✅
- [x] Basic bridging framework
- [x] Document lifecycle (`didOpen`)
- [x] Go to definition
- [x] Example and tests

### v0.2.0 - Complete System ✅
- [x] Command-Action protocol
- [x] Vim plugin implementation (~110 lines)
- [x] Auto file initialization on open
- [x] Silent error handling
- [x] Legacy code removal
- [x] End-to-end goto definition

### v0.3.0 - Enhanced Features (In Progress)
- [ ] Hover information
- [ ] Code completion
- [ ] Multi-language support

## Contributing

We follow the "make it work, make it right, make it fast" principle:

1. **Simplicity first**: Always prefer simpler solutions
2. **Code limits**: Keep total codebase under 500 lines
3. **Unix philosophy**: Do one thing well
4. **No over-engineering**: Ask "is this really necessary?"

## Installation

```bash
# Build from source
cargo build --release

# Binary will be in target/release/lsp-bridge
```

## Design Principles

> "Good taste is about eliminating edge cases" - Linus Torvalds

- **Stateless**: No complex state management
- **Fail-fast**: Clear error messages
- **Unix-style**: Composable with standard tools
- **Minimal dependencies**: Only essential crates

## Why Another LSP Bridge?

- **Vim Focus**: Designed specifically for Vim workflows
- **Simplicity**: 90% less code than alternatives
- **Reliability**: Simple architecture = fewer bugs
- **Performance**: Rust + async = blazingly fast
- **Maintainability**: Easy to understand and modify

---

*"Perfection is achieved not when there is nothing more to add, but when there is nothing left to take away."*