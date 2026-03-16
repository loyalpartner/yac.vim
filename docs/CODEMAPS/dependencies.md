<!-- Generated: 2026-03-15 | Files scanned: 25 | Token estimate: ~600 -->

# Dependencies Codemap

## Build Dependencies

| Dependency | Version | Purpose |
|-----------|---------|---------|
| Zig | >= 0.15.0 | Compiler for yacd daemon |
| tree-sitter (zig binding) | 0.25.0 | Tree-sitter C library + Zig wrapper (via build.zig.zon) |
| md4c | vendored | Markdown → HTML parsing for hover highlight (vendor/md4c/) |
| libunwind | system | Required by Wasmtime (tree-sitter WASM runtime) |

## Runtime Dependencies

| Dependency | Required | Purpose |
|-----------|----------|---------|
| Vim | >= 8.1 | Host editor (NOT Neovim) |
| Node.js | optional | For npm-based LSP installs (pyright, typescript-language-server) |
| Go | optional | For gopls install |
| copilot-language-server | optional | GitHub Copilot (must be in PATH) |

## Language Plugins (18 languages)

| Language | Extensions | LSP Server | Install Method |
|----------|-----------|------------|----------------|
| Bash | .sh, .bash | (none) | - |
| C | .c, .h | clangd | system |
| C++ | .cpp, .cc, .cxx, .hpp | clangd | system |
| CSS | .css | (none) | - |
| Go | .go | gopls | go_install |
| HTML | .html, .htm | (none) | - |
| JavaScript | .js, .jsx | typescript-language-server | npm |
| JSON | .json | (none) | - |
| Lua | .lua | (none) | - |
| Markdown | .md | (none) | - |
| Markdown Inline | (injection) | (none) | - |
| Python | .py, .pyi | pyright-langserver | npm |
| Rust | .rs | rust-analyzer | github_release |
| TOML | .toml | (none) | - |
| TypeScript | .ts, .tsx | typescript-language-server | npm |
| Vim | .vim | (none) | - |
| YAML | .yaml, .yml | (none) | - |
| Zig | .zig | zls | github_release |

## DAP Adapters

| Adapter | Languages | Install Method |
|---------|-----------|----------------|
| CodeLLDB | C, C++, Rust, Zig | github_release |
| debugpy | Python | pip |

## LSP Auto-Install Methods

| Method | How | Storage |
|--------|-----|---------|
| npm | `npm install` in venv dir | ~/.local/share/yac/packages/{pkg}/ |
| pip | `pip install` in Python venv | ~/.local/share/yac/packages/{pkg}/ |
| go_install | `GOBIN=... go install` | ~/.local/share/yac/bin/ |
| github_release | curl platform binary from GitHub Release | ~/.local/share/yac/bin/ |
| system | prompt user to install via package manager | system PATH |

## Themes (4 built-in)

- one-dark.json (One Dark Pro)
- catppuccin-mocha.json (Catppuccin Mocha)
- gruvbox-dark.json (Gruvbox Dark)
- tokyo-night.json (Tokyo Night)

User themes: `~/.config/yac/themes/*.json`
Active theme: `~/.config/yac/theme.txt`

## Data Locations

| Path | Content |
|------|---------|
| ~/.local/share/yac/bin/ | Installed LSP/DAP binaries |
| ~/.local/share/yac/packages/ | npm/pip LSP installs |
| ~/.local/share/yac.vim/history | MRU file history (100 entries) |
| ~/.config/yac/themes/ | User themes |
| ~/.config/yac/theme.txt | Active theme name |
| $XDG_RUNTIME_DIR/yacd.sock | Daemon Unix socket |
| $XDG_RUNTIME_DIR/yacd-*.log | Daemon log files |

## CI Pipeline (.github/workflows/)

| Workflow | Trigger | Jobs |
|----------|---------|------|
| ci.yml | push/PR to main | zig (build+test+artifact) → e2e (download+pytest) → ci-status |
| claude.yml | (Claude Code integration) | - |

## Test Stack

| Tool | Purpose |
|------|---------|
| `zig build test` | Zig unit tests |
| `uv run pytest` | E2E tests via pytest + term_start Vim |
| tests/vim/test_*.vim | Vim-side test scripts |
