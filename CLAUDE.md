# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is yac.vim - a minimal LSP bridge for Vim written in Rust. Despite the name "YAC" (Yet Another Code completion), this is specifically a lightweight LSP bridge, not a completion system.

The project consists of two main components:
1. **lsp-bridge**: A Rust binary (~380 lines) that acts as a stdin/stdout bridge between Vim and LSP servers
2. **Vim Plugin**: VimScript files (~380 lines) that provide Vim integration via job control

**IMPORTANT**: The current implementation uses direct stdin/stdout communication, NOT a server-client TCP architecture as described in the README. The README contains outdated information about the project's architecture.

## README vs Reality

**⚠️ CRITICAL DISCREPANCY WARNING ⚠️**

The README.md file describes a completely different architecture than what's actually implemented:

| README Claims | Actual Implementation |
|---------------|----------------------|
| TCP server-client architecture | stdin/stdout process communication |
| `:YACStart`, `:YACStatus` commands | `:LspDefinition`, `:LspHover`, `:LspComplete` commands |
| Multi-editor server support | One process per Vim instance |
| Performance benchmarks (800ms→200ms) | No benchmarks performed |
| Config files in `~/.config/yac-vim/` | No config file support |
| `test_simple.sh`, `run_simple_tests.sh` | These scripts don't exist |

**For accurate information about the current implementation, trust this CLAUDE.md file and the actual source code, not the README.**

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

# Manual testing with development vimrc
vim -u vimrc test_data/src/lib.rs

# Test goto definition manually:
# 1. Open test_data/src/lib.rs in Vim
# 2. Navigate to a symbol (e.g., User::new usage on line ~31) 
# 3. Press 'gd' to jump to definition
# 4. Should jump to the struct definition

# Test other features:
# - Press 'K' for hover information
# - Use :LspComplete for completion
```

### Development and Debugging
```bash
# Build and run with debug logging
cargo build --release
RUST_LOG=debug ./target/release/lsp-bridge

# Check logs
tail -f /tmp/lsp-bridge.log

# NOTE: The binary runs as a stdin/stdout filter, not a standalone server
# It's designed to be launched by Vim via job_start()
```

## Architecture

### Core Components

**Workspace Structure:**
- `crates/lsp-bridge/` - Main bridge binary (~380 lines Rust)
- `crates/lsp-client/` - LSP client library with JSON-RPC handling
- `vim/` - Vim plugin files (~380 lines VimScript total)
- `test_data/` - Test Rust project for development
- `tests/vim/` - Vim integration tests
- `docs/` - Requirements and design documentation

**Communication Flow:**
```
Vim Plugin (job_start) → JSON stdin/stdout → lsp-bridge → LSP Server (rust-analyzer)
```

**Process Model:**
- Vim launches `lsp-bridge` as a child process using `job_start()` with `'mode': 'raw'`
- Each Vim instance has its own `lsp-bridge` process (no shared server)
- Communication is purely stdin/stdout with line-delimited JSON
- Process terminates when Vim closes or `:LspStop` is called

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

### Auto-Completion Settings
```vim
let g:lsp_bridge_auto_complete = 1          " Enable auto-completion (default: 1)
let g:lsp_bridge_auto_complete_delay = 200  " Delay in milliseconds (default: 200)
let g:lsp_bridge_auto_complete_min_chars = 1 " Minimum characters to trigger (default: 1)
```

**Smart Delay Strategy**:
- First trigger: Uses configured delay (default 200ms)
- Subsequent filtering: Uses 50ms delay for responsive filtering
- Existing completion data is filtered locally without LSP requests

### Default Key Mappings
```vim
nnoremap <silent> gd :LspDefinition<CR>
nnoremap <silent> gy :LspTypeDefinition<CR>
nnoremap <silent> gi :LspImplementation<CR>
nnoremap <silent> gr :LspReferences<CR>
nnoremap <silent> K  :LspHover<CR>
" Manual completion trigger
inoremap <silent> <C-Space> <C-o>:LspComplete<CR>
```

### Available Commands
```vim
:LspStart              " Start LSP bridge process
:LspStop               " Stop LSP bridge process
:LspDefinition         " Jump to symbol definition
:LspTypeDefinition     " Jump to type definition
:LspImplementation     " Jump to implementation
:LspHover              " Show hover information
:LspComplete           " Trigger completion manually
:LspReferences         " Find all references
:LspInlayHints         " Show inlay hints for current file
:LspClearInlayHints    " Clear displayed inlay hints
:LspOpenLog            " Open LSP bridge log file
```

### Log Viewing Commands
```vim
:LspOpenLog    " Open log viewer in a new buffer
:LspClearLog   " Clear current log file
```

**Log Features**:
- Each lsp-bridge process has isolated log file: `/tmp/lsp-bridge-<pid>.log`
- Press 'r' in log buffer to refresh content

## Current Functionality

### Implemented Features ✅
- `file_open` command - Initialize file in LSP server
- `goto_definition` command - Jump to symbol definitions with popup window display
- `hover` command - Show documentation/type information in floating popup  
- `completion` command - Advanced code completion with:
  - **Auto-trigger**: Automatically shows completions while typing (300ms delay)
  - **Smart context**: Only triggers in appropriate contexts (not in strings/comments)
  - **Keyboard navigation**: Ctrl+P/Ctrl+N, arrow keys
  - **Visual selection**: ▶ marker for current selection  
  - **Confirmation**: Enter/Tab to accept, Esc to cancel
  - **Type-based colors**: Function=blue, Variable=green, etc.
  - **Match highlighting**: [brackets] around matching characters
- `inlay_hints` command - Display inline type annotations and parameter names:
  - **Type hints**: Show variable types (`: i32`) after declarations
  - **Parameter hints**: Show parameter names (`count: 5`) in function calls  
  - **Text properties**: Uses Vim 8.1+ text properties for optimal display
  - **Fallback support**: Falls back to match highlighting for older Vim versions
  - **Customizable styling**: Separate highlight groups for types and parameters
- Auto-initialization on file open (`BufReadPost`/`BufNewFile` for `*.rs` files)
- Silent "no definition found" handling
- Workspace root detection for `rust-analyzer` (searches for `Cargo.toml`)
- Popup window support for Vim 8.1+

### Language Support
- **Rust**: Full support via `rust-analyzer`
- **Other languages**: Framework exists but not implemented

### Planned Features
- Multi-language support (Python, TypeScript, Go, etc.)
- Configuration file support
- More LSP features (references, symbols, diagnostics)

## Development Principles

The codebase follows strict simplicity constraints:
- **Code limit**: Target ~800 lines total (currently ~760: 380 Rust + 380 VimScript)
- **No over-engineering**: "Make it work, make it right, make it fast"  
- **Unix philosophy**: Do one thing (LSP bridging) and do it well
- **Linus-style**: Eliminate special cases, prefer direct solutions

Legacy protocol handling was removed in v0.2 to maintain simplicity. The current implementation prioritizes clarity over performance optimizations.

## Testing and Debugging

### Manual Testing
```bash
# Start development environment
vim -u vimrc

# Test goto definition manually:
# 1. Open test_data/src/lib.rs  
# 2. Navigate to User::new usage
# 3. Press 'gd' to jump to definition

# Run automated Vim integration tests:
vim -u vimrc -c 'source tests/vim/goto_definition.vim'
vim -u vimrc -c 'source tests/vim/completion_test.vim'

# Auto-completion testing (manual only):
vim -u vimrc -c 'source tests/vim/auto_complete_demo.vim'
# Then manually type in INSERT mode to test auto-completion
```

### Auto-Completion Testing
Auto-completion must be tested manually due to the nature of interactive events:

1. **Setup**: `vim -u vimrc -c 'source tests/vim/auto_complete_demo.vim'`
2. **Test typing**: Enter insert mode and type `HashMap::`, `Vec::`, etc.
3. **Verify features**: 
   - 300ms delay before popup appears
   - ▶ selection indicator and [match] highlighting  
   - Ctrl+P/N navigation, Enter/Tab confirmation
   - Smart context detection (no completion in strings/comments)

### Debug Information
- LSP bridge logs: `/tmp/lsp-bridge.log`
- Enable debug with `RUST_LOG=debug`
- No `:LspStatus` command implemented yet

The test data includes a simple Rust project structure for validating LSP functionality.

### Common Issues
1. **"lsp-bridge not running"**: The process failed to start, check if binary exists at path
2. **No response from LSP**: Check `/tmp/lsp-bridge.log` for LSP server errors
3. **No definition found**: This is silently handled (expected for some symbols)
4. **Popup not showing**: Requires Vim 8.1+ for popup support, falls back to echo on older versions

### Troubleshooting Commands
```bash
# Check if binary exists and is executable
ls -la ./target/release/lsp-bridge

# Test binary manually (it waits for JSON input)
echo '{"command":"goto_definition","file":"/path/to/file.rs","line":0,"column":0}' | ./target/release/lsp-bridge

# Check rust-analyzer is installed
which rust-analyzer
```