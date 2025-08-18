# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is yac.vim - a minimal LSP bridge for Vim written in Rust. The project consists of two main components:
1. **lsp-bridge**: A Rust binary that acts as a bridge between Vim and LSP servers
2. **Vim Plugin**: VimScript files that provide Vim integration

The architecture follows the "inverted control" pattern where the Rust process manages LSP state and Vim acts as a lightweight client.

## Build and Development Commands

### Building
```bash
# Build the project
cargo build --release

# Build debug version
cargo build
```

### Testing
```bash
# Run Rust unit/integration tests
cargo test

# Test LSP bridge functionality with Vim
vim -u vimrc -c 'source goto_definition.vim'

# Manual testing with custom vimrc
vim -u vimrc test_data/src/lib.rs
```

### Development Server
```bash
# Run with debug logging
RUST_LOG=debug ./target/release/lsp-bridge

# Check logs
tail -f /tmp/lsp-bridge.log
```

## Architecture

### Core Components

**Workspace Structure:**
- `crates/lsp-bridge/` - Main bridge binary (~300 lines Rust)
- `crates/lsp-client/` - LSP client library with JSON-RPC handling
- `vim/` - Vim plugin files (~110 lines VimScript total)
- `test_data/` - Test Rust project for development
- `docs/` - Requirements and design documentation

**Communication Flow:**
```
Vim Plugin → JSON stdin/stdout → lsp-bridge → LSP Server (rust-analyzer)
```

### Protocol Design

The system uses a simplified Command-Action protocol (v0.2):

**Vim → lsp-bridge (Commands):**
```json
{
  "command": "goto_definition",
  "file": "/absolute/path/to/file.rs",
  "line": 31,    // 0-based
  "column": 26   // 0-based
}
```

**lsp-bridge → Vim (Actions):**
```json
{
  "action": "jump",
  "file": "/path/to/definition.rs", 
  "line": 13,    // 0-based
  "column": 11   // 0-based
}
```

### Key Implementation Details

1. **Auto-initialization**: LSP servers start when files are opened (`BufReadPost`/`BufNewFile`)
2. **Silent error handling**: "No definition found" errors are handled silently
3. **Workspace detection**: Automatically finds `Cargo.toml` for workspace root
4. **Raw channel mode**: Vim uses `'mode': 'raw'` for JSON communication
5. **Legacy code removed**: v0.2 simplified from complex unified request handling

## Plugin Configuration

### Development Setup
The `vimrc` file provides test configuration:
```vim
let g:lsp_bridge_command = ['./target/release/lsp-bridge']
let g:lsp_bridge_auto_start = 1
```

### Default Key Mappings
```vim
nnoremap <silent> gd :LspDefinition<CR>
nnoremap <silent> K  :LspHover<CR>
```

## Current Functionality

### Implemented Features ✅
- `file_open` command - Initialize file in LSP server
- `goto_definition` command - Jump to symbol definitions  
- Auto-initialization on file open
- Silent "no definition found" handling
- Workspace root detection for `rust-analyzer`

### Planned Features
- `hover` command - Show documentation/type information
- `completion` command - Code completion support
- Multi-language support beyond Rust

## Development Principles

The codebase follows strict simplicity constraints:
- **Code limit**: Target <400 lines total (currently ~300)
- **No over-engineering**: "Make it work, make it right, make it fast"  
- **Unix philosophy**: Do one thing (LSP bridging) and do it well
- **Linus-style**: Eliminate special cases, prefer direct solutions

Legacy protocol handling was removed in v0.2 to maintain simplicity.

## Testing and Debugging

### Manual Testing
```bash
# Start development environment
vim -u vimrc

# Test goto definition
# 1. Open test_data/src/lib.rs  
# 2. Navigate to User::new usage
# 3. Press 'gd' to jump to definition
```

### Debug Information
- LSP bridge logs: `/tmp/lsp-bridge.log`
- Enable debug with `RUST_LOG=debug`
- Vim plugin provides `:LspStatus` command

The test data includes a simple Rust project structure for validating LSP functionality.