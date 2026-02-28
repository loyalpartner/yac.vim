# yac.vim — Claude Instructions

## Build & Test

```bash
zig build                        # debug build
zig build -Doptimize=ReleaseFast # release build
zig build test                   # run Zig tests
uv run pytest                    # run Python tests
```

## Architecture

VimScript ↔ JSON-RPC (Unix socket) ↔ Zig daemon ↔ LSP servers

- `vim/autoload/yac.vim` — all Vim-side logic
- `src/` — Zig daemon
- `src/handlers/` — per-feature request handlers
- `src/lsp_transform.zig` — LSP response → Vim format

## Reference

- LSP 3.17 spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/
- zls (Zig LSP): https://github.com/zigtools/zls
- Vim channel protocol: https://vimhelp.org/channel.txt.html
- Vim popup API: https://vimhelp.org/popup.txt.html

## Adding Language Plugins

See [docs/new-language-plugin.md](docs/new-language-plugin.md)

## Exploratory Tasks

When requirements are unclear, don't spend excessive time analyzing. Write the simplest compilable minimal implementation first, so I can see the result and decide the direction. Read at most 3 files before starting to code during exploration.

## Known LSP Limitations

- **zls 0.15**: `workspaceSymbolProvider: false` — `workspace/symbol` returns `null` (unimplemented)
