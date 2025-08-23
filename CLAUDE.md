# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is yac.vim - a minimal LSP bridge for Vim written in Rust. Despite the name "YAC" (Yet Another Code completion), this is specifically a lightweight LSP bridge, not a completion system.

The project consists of three main components:
1. **vim crate**: A comprehensive vim client library (~900 lines) with v4 specification support
2. **lsp-bridge**: A Rust binary with modular LSP handlers (~3000 lines total) that bridges Vim and LSP servers
3. **Vim Plugin**: VimScript files (~1660 lines) that provide comprehensive Vim integration

**IMPORTANT**: The current implementation uses vim crate v4 with unified message processing, featuring dual request/notification semantics, clean `Option<Location>` response handling, and elimination of redundant protocol metadata.

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

## Development Environment Setup

### Pre-commit Hooks (Required for Quality Assurance)

This project uses pre-commit hooks to ensure code quality. Claude Code should install them before making any changes:

```bash
# Install pre-commit hooks using the setup script
./scripts/setup-hooks.sh

# Or configure Git to use the scripts directory directly (preferred)
git config core.hooksPath scripts
```

**What the hooks check:**
- `cargo fmt --check` - Ensures code is properly formatted
- `cargo clippy -- -D warnings` - Catches common mistakes and enforces best practices

**For Claude Code users**: Run the setup command immediately after checkout to ensure all commits meet quality standards.

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
# - Press 'gD' for goto declaration
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
  - `src/handlers/` - Organized LSP request handlers (definition, file_open, etc.)
  - `src/main.rs` - Entry point and vim crate integration
  - `src/lib.rs` - Core LSP bridge logic and data structures
- `crates/lsp-client/` - LSP client library with JSON-RPC handling  
- `crates/vim/` - vim crate v4 implementation with unified VimMessage protocol and VimContext trait
- `vim/` - Vim plugin files (~380 lines VimScript total)
- `test_data/` - Test Rust project for development
- `tests/vim/` - Vim integration tests
- `docs/` - Requirements and design documentation

**Communication Flow:**
```
# Requests (need response):
Vim Plugin (ch_sendexpr) → vim crate v4 (JSON-RPC) → lsp-bridge → LSP Server

# Notifications (fire-and-forget):
Vim Plugin (ch_sendraw) → vim crate v4 (JSON array) → lsp-bridge → LSP Server
```

**Process Model:**
- Vim launches `lsp-bridge` as a child process using `job_start()` with `'mode': 'json'`
- Each Vim instance has its own `lsp-bridge` process (no shared server)
- Communication uses vim crate v4's unified message processing with dual JSON-RPC/notification protocols
- Process terminates when Vim closes or `:LspStop` is called

### Unified Request/Notification Architecture

The system uses vim crate v4 with unified message processing supporting both request/response and notification patterns:

**Dual Request/Notification API:**
```vim
" 1. Request pattern - expects response
function! s:request(method, params, callback_func)
  call ch_sendexpr(s:job, jsonrpc_msg, {'callback': a:callback_func})
endfunction

" 2. Notification pattern - fire-and-forget 
function! s:notify(method, params)
  call ch_sendraw(s:job, json_encode([jsonrpc_msg]) . "\n")
endfunction

" 3. LSP goto methods now use notifications for immediate action
function! lsp_bridge#goto_definition()
  call s:notify('goto_definition', {'file': expand('%:p'), 'line': line('.')-1, 'column': col('.')-1})
endfunction
```

**Vim Crate v4 Message Types:**
```rust
/// Unified Vim message types - handles both JSON-RPC and Vim channel protocols
pub enum VimMessage {
    // JSON-RPC messages (vim-to-client)
    Request { id: u64, method: String, params: Value },
    Response { id: i64, result: Value },
    Notification { method: String, params: Value },
    
    // Vim channel commands (client-to-vim)
    Call { func: String, args: Vec<Value>, id: u64 },
    CallAsync { func: String, args: Vec<Value> },
    Expr { expr: String, id: u64 },
    // ... more command types
}

// Clean Option<Location> response - no redundant metadata  
pub struct Location {
    pub file: String,     // Complete location data
    pub line: u32,        // or nothing at all
    pub column: u32,
}
pub type GotoResponse = Option<Location>;
```

**Protocol Semantics:**
```json
// Request message (JSON-RPC)
{"id": 1, "method": "goto_definition", "params": {"file": "/path/file.rs", "line": 31, "column": 26}}

// Notification message (JSON array)
[{"method": "goto_definition", "params": {"file": "/path/file.rs", "line": 31, "column": 26}}]

// Response data (Option<Location> semantics)
{"file": "/path/file.rs", "line": 31, "column": 26}  // Success
{}  // No definition found
```

### Key Implementation Details

1. **Unified message processing**: vim crate v4 handles both JSON-RPC requests and notification arrays intelligently
2. **Dual semantics**: Clear separation between requests (need response) and notifications (fire-and-forget)
3. **Option<Location> responses**: Data either exists completely or not at all, no partial states
4. **Handler trait integration**: All handlers now take `&mut Vim` parameter for direct vim interaction
5. **Protocol intelligence**: Automatic encoding/parsing based on message type eliminates protocol confusion
6. **Silent error handling**: Empty responses are handled silently, no explicit error checking needed
7. **Auto-initialization**: LSP servers start when files are opened (`BufReadPost`/`BufNewFile`)
8. **Workspace detection**: Automatically finds `Cargo.toml` for workspace root
9. **JSON channel mode**: Vim uses `'mode': 'json'` for vim crate v4 communication
10. **Type-safe responses**: Rust type system guarantees response data integrity

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
nnoremap <silent> gD :LspDeclaration<CR>
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
:LspDeclaration        " Jump to symbol declaration
:LspTypeDefinition     " Jump to type definition
:LspImplementation     " Jump to implementation
:LspHover              " Show hover information
:LspComplete           " Trigger completion manually
:LspReferences         " Find all references
:LspInlayHints         " Show inlay hints for current file
:LspClearInlayHints    " Clear displayed inlay hints
:LspOpenLog            " Open LSP bridge log file
:LspDebugToggle        " Toggle debug mode for message logging
:LspDebugStatus        " Show debug status, pending requests, and log locations
:LspClearPendingRequests " Clear stale pending requests (30s+ timeout)
```

### Log Viewing Commands
```vim
:LspOpenLog    " Open log viewer in a new buffer
:LspClearLog   " Clear current log file
```

**Log Features**:
- Each lsp-bridge process has isolated log file: `/tmp/lsp-bridge-<pid>.log`
- Press 'r' in log buffer to refresh content

### Debug Mode Commands
```vim
:LspDebugToggle        " Enable/disable debug logging
:LspDebugStatus        " Show current debug state and log paths
```

**Debug Features**:
- **Command Send/Receive Logging**: Shows outgoing commands and incoming responses
- **Channel Communication Logging**: Logs to `/tmp/vim_channel.log` when debug enabled
- **Request Correlation**: Tracks request/response pairs with unique IDs
- **Process Restart**: Automatically restarts process when debug is enabled to capture logs

## Current Functionality

### Notification System

**Dual Request/Response Architecture:**
- **Requests** (`s:request`): For operations needing responses (completion, hover, etc.)
- **Notifications** (`s:notify`): For fire-and-forget operations (goto definition, diagnostics)

**Key Characteristics:**
- **Request Transport**: Uses `ch_sendexpr()` with callback handlers
- **Notification Transport**: Uses `ch_sendraw()` with JSON array format
- **Protocol Intelligence**: vim crate v4 automatically detects and parses message types
- **Immediate Action**: Notifications trigger immediate LSP server-side actions without waiting

**Example Usage:**
```vim
" Fire-and-forget notification for goto definition
call s:notify('goto_definition', {'file': expand('%:p'), 'line': line('.')-1, 'column': col('.')-1})

" Request with response callback for hover information  
call s:request('hover', {'file': expand('%:p'), 'line': line('.')-1, 'column': col('.')-1}, 's:handle_hover_response')
```

**Debug Features:**
- `[SEND]` prefix for requests in debug output
- `[NOTIFY]` prefix for notifications in debug output
- Separate logging paths track request vs notification flows

### Implemented Features ✅
- `file_open` command - Initialize file in LSP server
- `goto_definition` command - Jump to symbol definitions using notification-based immediate action
- `goto_declaration` command - Jump to symbol declarations using notification-based immediate action
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
- Silent "no definition found" and "no declaration found" handling
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

The codebase follows strict simplicity constraints and Linus Torvalds' engineering philosophy:

### Core Design Philosophy
- **Good Taste**: "Bad programmers worry about the code. Good programmers worry about data structures"
- **Eliminate Special Cases**: Use proper data structures to eliminate conditional complexity
- **Option<Location> Pattern**: Data either exists completely (Location) or not at all (None)
- **No Partial States**: Avoid invalid combinations like `file` existing but `line` missing

### Implementation Constraints  
- **Code organization**: Structured into focused modules (vim crate: ~900 lines, handlers: ~2800 lines, vim plugin: ~1660 lines)
- **No over-engineering**: "Make it work, make it right, make it fast"  
- **Unix philosophy**: Do one thing (LSP bridging) and do it well
- **Data-driven design**: Let type system enforce correctness rather than runtime checks

### Recent Architecture Evolution
- **v0.1**: Unified request tracking with complex dispatch logic (~150 lines of complexity)
- **v0.2**: Individual callback handlers with `Option<Location>` semantics (simplified to ~50 lines)
- **v0.3**: vim crate v4 implementation with unified message processing and dual request/notification patterns
- **Protocol cleanup**: Removed redundant `action` fields, embraced data presence as signal
- **Handler modernization**: All handlers now use `&mut Vim` parameter for direct vim interaction

The current v4 implementation prioritizes architectural clarity and protocol intelligence following "good taste" principles over micro-optimizations.

### Handler Organization

**Structured Handler Directory:**
```
crates/lsp-bridge/src/handlers/
├── mod.rs           - Module exports and documentation
├── definition.rs    - goto_definition, goto_declaration, etc.
└── file_open.rs     - File initialization and LSP setup
```

**Benefits of Handler Organization:**
- **Clear separation of concerns**: Each handler file focuses on specific LSP functionality
- **Easy extensibility**: Adding new LSP features requires creating new handler files  
- **Better maintainability**: Related code is grouped together logically
- **Import clarity**: `use handlers::{DefinitionHandler, FileOpenHandler}` vs scattered individual imports

### VimContext Integration

**Interface Segregation Pattern:**
The vim crate v4 provides a clean `VimContext` trait that handlers use for vim interaction:

```rust
#[async_trait]
pub trait VimContext: Send + Sync {
    async fn call(&mut self, func: &str, args: Vec<Value>) -> Result<Value>;
    async fn call_async(&mut self, func: &str, args: Vec<Value>) -> Result<()>;
    async fn expr(&mut self, expr: &str) -> Result<Value>;
    async fn ex(&mut self, command: &str) -> Result<()>;
    async fn normal(&mut self, keys: &str) -> Result<()>;
    // ... more vim operations
}
```

**Handler Integration:**
```rust
#[async_trait]
impl Handler for GotoHandler {
    async fn handle(&self, ctx: &mut dyn VimContext, input: Self::Input) -> Result<Option<Self::Output>> {
        // Direct vim interaction - no complex callback setup needed
        ctx.ex(format!("edit {}", location.file).as_str()).await.ok();
        ctx.call_async("cursor", vec![json!(location.line + 1), json!(location.column + 1)]).await.ok();
        Ok(None)
    }
}
```

**Benefits:**
- **Direct Action**: Handlers can immediately perform vim actions (edit files, move cursor)
- **No Callbacks**: Eliminates complex vim-side response handling for simple operations
- **Interface Segregation**: Handlers only get vim operations they need, not transport internals
- **Type Safety**: Rust async/await with proper error handling

## Testing and Debugging

### Manual Testing
```bash
# Start development environment
vim -u vimrc

# Test goto definition manually:
# 1. Open test_data/src/lib.rs  
# 2. Navigate to User::new usage
# 3. Press 'gd' to jump to definition
# 4. Press 'gD' to jump to declaration

# Run automated Vim integration tests:
vim -u vimrc -c 'source tests/vim/goto_definition.vim'
vim -u vimrc -c 'source tests/vim/declaration_test.vim'
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
- LSP bridge logs: `/tmp/lsp-bridge-<pid>.log`
- Vim debug logs: Use `:LspDebugToggle` to enable
- Channel logs: `/tmp/vim_channel.log` when debug mode enabled
- Enable Rust debug with `RUST_LOG=debug`

**Debug Usage Example:**
```vim
:LspDebugToggle        " Enable debug mode
:LspDefinition         " Will show:
" LspDebug[SEND]: goto_definition -> lib.rs:31:26
" LspDebug[JSON]: {"method": "goto_definition", "params": {...}}
" LspDebug[RECV]: goto_definition response: {"file": "/path/file.rs", "line": 31, "column": 26}
```

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

# Test binary manually (it expects JSON-RPC format)
echo '[1, {"method":"goto_definition","params":{"command":"goto_definition","file":"/path/to/file.rs","line":0,"column":0}}]' | ./target/release/lsp-bridge

# Check rust-analyzer is installed
which rust-analyzer
```

## Code Development and Review Philosophy

This project follows Linus Torvalds' engineering philosophy for both code development and code review. For detailed methodology and guidelines, see [docs/linus-persona.md](docs/linus-persona.md).

### Core Development Principles

**Apply Linus-style thinking to ALL code development:**

1. **"Good Taste" First**: Before writing any code, ask:
   - Can I eliminate special cases through better data structures?
   - Are there repetitive patterns that indicate poor abstraction?
   - Can 10 lines become 3 lines through better design?

2. **Never Break Userspace**: All changes must maintain backward compatibility
   - JSON protocol interface must remain stable
   - Vim plugin commands must continue working
   - No breaking changes to existing functionality

3. **Pragmatic Implementation**: 
   - Solve real problems, not theoretical ones
   - Use the simplest approach that works
   - Avoid over-engineering and premature abstraction

4. **Simplicity Obsession**:
   - Functions should do one thing well
   - Maximum 3 levels of indentation
   - Eliminate code duplication through better data structures
   - "Bad programmers worry about the code. Good programmers worry about data structures."

### Linus-Style Development Process

**Before implementing any feature:**

1. **Data Structure Analysis**: What are the core data relationships? Can better structures eliminate complexity?
2. **Special Case Elimination**: Identify all conditional branches - can they be eliminated through redesign?
3. **Complexity Minimization**: Can this be implemented with fewer concepts?
4. **Breaking Change Check**: Will this affect any existing functionality?
5. **Practical Validation**: Is this solving a real problem users actually have?

### Code Review Guidelines
- **Good Taste**: Eliminate special cases through better data structures
- **Backward Compatibility**: Never break existing functionality
- **Pragmatism**: Solve real problems, not theoretical ones  
- **Simplicity**: Keep complexity to a minimum, avoid deep nesting