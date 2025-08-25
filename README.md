# yac.vim - Yet Another Code completion for Vim

A minimal LSP bridge for Vim written in Rust. Despite the name "YAC" (Yet Another Code completion), this is specifically a lightweight LSP bridge, not a completion system.

## 🚀 Features

- **Minimal & Fast**: ~800 lines total core codebase
- **Simple Architecture**: Direct stdin/stdout communication between Vim and LSP servers
- **SSH Remote Editing**: Full SSH tunnel infrastructure for remote LSP operations
- **Memory Safe**: Rust compile-time guarantees prevent crashes and memory leaks  
- **Auto-initialization**: LSP servers start automatically when files are opened
- **Silent Error Handling**: Gracefully handles "No definition found" scenarios
- **Popup Support**: Modern floating popups for Vim 8.1+

## 📦 Installation

### Prerequisites

- Rust 1.70+
- Vim 8.1+ (Neovim not supported)  
- LSP servers (currently supports rust-analyzer)

### Building from Source

```bash
git clone https://github.com/loyalpartner/yac.vim.git
cd yac.vim
cargo build --release
```

### Vim Plugin Installation

#### Manual Installation

```bash
mkdir -p ~/.vim/plugin ~/.vim/autoload
cp vim/plugin/* ~/.vim/plugin/
cp vim/autoload/* ~/.vim/autoload/
```

## 🔧 Configuration

### Basic Configuration

Add to your `.vimrc`:

```vim
" Specify path to lsp-bridge binary
let g:lsp_bridge_command = ['./target/release/lsp-bridge']

" Auto-start LSP bridge (default: 1)
let g:lsp_bridge_auto_start = 1

" Auto-completion settings
let g:lsp_bridge_auto_complete = 1          " Enable auto-completion (default: 1)
let g:lsp_bridge_auto_complete_delay = 200  " Delay in milliseconds (default: 200)  
let g:lsp_bridge_auto_complete_min_chars = 1 " Minimum characters to trigger (default: 1)
```

### Default Key Mappings

The plugin automatically sets up these key mappings:

```vim
nnoremap <silent> gd :LspDefinition<CR>     " Jump to definition
nnoremap <silent> gD :LspDeclaration<CR>    " Jump to declaration  
nnoremap <silent> gy :LspTypeDefinition<CR> " Jump to type definition
nnoremap <silent> gi :LspImplementation<CR> " Jump to implementation
nnoremap <silent> gr :LspReferences<CR>     " Find references
nnoremap <silent> K  :LspHover<CR>          " Show hover information
inoremap <silent> <C-Space> <C-o>:LspComplete<CR> " Manual completion
```

## 🚀 Usage

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
```

### Features

- **Auto-initialization**: LSP starts automatically when opening `.rs` files
- **SSH Remote Editing**: Seamless remote LSP via SSH tunnels (`scp://user@host//path/file`)
- **Code Completion**: Advanced auto-completion with smart context detection
- **Hover Information**: Press `K` to show documentation/type information
- **Navigation**: Jump to definitions, declarations, implementations, and references
- **Inlay Hints**: Display inline type annotations and parameter names
- **Popup Windows**: Modern floating popups for Vim 8.1+

## 🏗️ Architecture

yac.vim supports both local and remote LSP operations:

**Local Mode:**
```
Vim Plugin (job_start) → JSON stdin/stdout → lsp-bridge → LSP Server (rust-analyzer)
```

**SSH Remote Mode:**
```
Vim → local lsp-bridge (forwarder) → SSH tunnel → remote lsp-bridge → rust-analyzer
```

### Process Model

- Vim launches `lsp-bridge` as a child process using `job_start()` with `'mode': 'raw'`
- Each Vim instance has its own `lsp-bridge` process (no shared server)
- Communication is purely stdin/stdout with line-delimited JSON
- Process terminates when Vim closes or `:LspStop` is called

### Protocol Design

The system uses a simplified Command-Action protocol:

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

## 🎯 Design Principles

The codebase follows strict simplicity constraints:

- **Code limit**: Target ~800 lines total (currently ~760: 380 Rust + 380 VimScript)
- **No over-engineering**: "Make it work, make it right, make it fast"
- **Unix philosophy**: Do one thing (LSP bridging) and do it well
- **Linus-style**: Eliminate special cases, prefer direct solutions

## 🧪 Development

### Setup

#### Pre-commit Hooks (Recommended)

This project uses pre-commit hooks to ensure code quality. Install them with:

```bash
# Option 1: Use the setup script (copies hooks to .git/hooks/)
./scripts/setup-hooks.sh

# Option 2: Use Git's hooks path (no copying needed)
git config core.hooksPath scripts
```

The hooks will automatically run before each commit:
- `cargo fmt --check` - Check code formatting
- `cargo clippy` - Check for common mistakes and style issues

To temporarily skip hooks, use: `git commit --no-verify`

### Building

```bash
# Build release version
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
# 4. Press 'gD' to jump to declaration
# 5. Should jump to the struct definition
```

### CI Checks

![Rust CI](https://github.com/loyalpartner/yac.vim/workflows/Rust%20CI/badge.svg)

All commits and PRs are automatically checked by GitHub Actions for:
- Code formatting (`cargo fmt`)
- Linting (`cargo clippy`) 
- Build and tests

### Running in Development

```bash
# Build and run with debug logging
cargo build --release
RUST_LOG=debug ./target/release/lsp-bridge

# Check logs
tail -f /tmp/lsp-bridge.log

# NOTE: The binary runs as a stdin/stdout filter, not a standalone server
# It's designed to be launched by Vim via job_start()
```

## 📋 Supported LSP Servers

- **rust-analyzer** (Rust) - Fully supported
- **Other languages**: Framework exists but not implemented

## 🐛 Troubleshooting

### Common Issues

1. **"lsp-bridge not running"**
   ```bash
   # Check if binary exists and is executable
   ls -la ./target/release/lsp-bridge
   
   # Test binary manually (it waits for JSON input)
   echo '{"command":"goto_definition","file":"/path/to/file.rs","line":0,"column":0}' | ./target/release/lsp-bridge
   ```

2. **No response from LSP**
   ```bash
   # Check LSP bridge logs for errors
   tail -f /tmp/lsp-bridge.log
   
   # Verify rust-analyzer is installed
   which rust-analyzer
   ```

3. **No definition found**
   - This is silently handled (expected for some symbols)
   - Check if you're navigating to valid symbols
   - Ensure the project compiles correctly

### Debug Information

- LSP bridge logs: `/tmp/lsp-bridge.log`
- Enable debug with `RUST_LOG=debug`
- Use `:LspOpenLog` to view logs in Vim

## 🤝 Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

### Development Guidelines

- Follow Rust idioms and best practices
- Maintain the ~800 line code limit
- Add tests for new functionality
- Update CLAUDE.md documentation
- Install pre-commit hooks to automatically check code quality
- All code must pass `cargo clippy` and `cargo fmt` checks

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🙏 Acknowledgments

- Inspired by the original [lsp-bridge](https://github.com/manateelazycat/lsp-bridge) project
- Thanks to the Rust and Vim communities for their excellent tools and libraries

## 🔗 Links

- [Development Documentation](CLAUDE.md)
- [Issue Tracker](https://github.com/loyalpartner/yac.vim/issues)
- [LSP Specification](https://microsoft.github.io/language-server-protocol/)

---

**yac.vim** - Minimal, fast, and reliable LSP bridge for Vim! 🚀