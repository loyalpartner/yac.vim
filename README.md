# yac.vim - Yet Another Code completion for Vim

A minimal LSP bridge for Vim, centered on a Zig runtime path. Despite the name "YAC" (Yet Another Code completion), this is specifically a lightweight LSP bridge, not a completion system.

## 🚀 Features

- **Minimal & Fast**: ~800 lines total core codebase
- **Simple Architecture**: Direct stdin/stdout communication between Vim and LSP servers
- **SSH Remote Editing**: Full SSH tunnel infrastructure for remote LSP operations
- **Memory Safe**: Strongly-typed implementation with predictable runtime behavior  
- **Auto-initialization**: LSP servers start automatically when files are opened
- **Silent Error Handling**: Gracefully handles "No definition found" scenarios
- **Popup Support**: Modern floating popups for Vim 8.1+

## 📦 Installation

### Prerequisites

- Zig 0.12+
- Vim 8.1+ (Neovim not supported)  
- Installed LSP servers for the languages you use

### Building from Source

```bash
git clone https://github.com/loyalpartner/yac.vim.git
cd yac.vim
zig build -Doptimize=ReleaseFast
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
let g:yac_bridge_command = ['./zig-out/bin/lsp-bridge']

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

- Vim launches `lsp-bridge` as a child process using `job_start()` with `'mode': 'json'`
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

- **Code limit**: Keep the core bridge minimal; Zig implementation is the primary runtime path
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
- `zig fmt --check src/**/*.zig` - Check Zig formatting
- `zig fmt src/**/*.zig` - Keep Zig sources formatted

To temporarily skip hooks, use: `git commit --no-verify`

### Building

```bash
# Build release version
zig build -Doptimize=ReleaseFast

# Build debug version  
zig build -Doptimize=Debug
```

### Testing

```bash
# Run Zig unit tests
zig build test

# Run E2E tests (requires uv)
uv run pytest            # all tests
uv run pytest -k goto    # single suite
uv run pytest -v         # verbose

# Manual testing with development vimrc
vim -u vimrc test_data/src/lib.rs
```

### CI Checks

![CI](https://github.com/loyalpartner/yac.vim/workflows/CI/badge.svg)

All commits and PRs are automatically checked by GitHub Actions for:
- Code formatting (`zig fmt`)
- Build and tests

### Running in Development

```bash
# Build and run with debug logging
zig build -Doptimize=ReleaseFast
YAC_LOG=debug ./zig-out/bin/lsp-bridge

# Check logs
tail -f /tmp/lsp-bridge.log

# NOTE: The binary runs as a stdin/stdout filter, not a standalone server
# It's designed to be launched by Vim via job_start()
```

## 📋 Supported LSP Servers

- Multi-language support is configured in bridge registry
- Actual availability depends on installed language servers

## 🐛 Troubleshooting

### Common Issues

1. **"lsp-bridge not running"**
   ```bash
   # Check if binary exists and is executable
   ls -la ./zig-out/bin/lsp-bridge
   
   # Test binary manually (it waits for JSON input)
   echo '[0,{"method":"goto_definition","params":{"file":"/path/to/file.rs","line":0,"column":0}}]' | ./zig-out/bin/lsp-bridge
   ```

2. **No response from LSP**
   ```bash
   # Check LSP bridge logs for errors
   tail -f /tmp/lsp-bridge.log
   
   # Verify your target language server is installed
   which <your-language-server>
   ```

3. **No definition found**
   - This is silently handled (expected for some symbols)
   - Check if you're navigating to valid symbols
   - Ensure the project compiles correctly

### Debug Information

- LSP bridge logs: `/tmp/lsp-bridge.log`
- Enable debug with `YAC_LOG=debug`
- Use `:LspOpenLog` to view logs in Vim

## 🤝 Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

### Development Guidelines

- Follow Zig idioms and best practices
- Maintain the ~800 line code limit
- Add tests for new functionality
- Install pre-commit hooks to automatically check code quality
- All code must pass `zig build test` and `zig fmt` checks

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🙏 Acknowledgments

- Inspired by the original [lsp-bridge](https://github.com/manateelazycat/lsp-bridge) project
- Thanks to the Zig and Vim communities for their excellent tools and libraries

## 🔗 Links

- [Issue Tracker](https://github.com/loyalpartner/yac.vim/issues)
- [LSP Specification](https://microsoft.github.io/language-server-protocol/)

---

**yac.vim** - Minimal, fast, and reliable LSP bridge for Vim! 🚀