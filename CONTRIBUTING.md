# Contributing to yac.vim

Thank you for your interest in contributing to yac.vim.

## Code Quality Requirements

Before submitting a pull request, make sure all Zig checks pass:

1. **Formatting**
   ```bash
   zig fmt src/*.zig
   ```

2. **Tests**
   ```bash
   zig build test
   ```

3. **Build**
   ```bash
   zig build -Doptimize=ReleaseFast
   ```

## Pre-commit Checks

The repository provides `scripts/pre-commit`, which runs:

- `zig fmt --check src/*.zig`
- `zig build test`

Install with:

```bash
./scripts/setup-hooks.sh
```

## Development Setup

1. Clone the repository.
2. Install Zig 0.12+.
3. Build the project:
   ```bash
   zig build -Doptimize=ReleaseFast
   ```
4. Run tests:
   ```bash
   zig build test
   ```

## Submitting Changes

1. Fork the repository.
2. Create a feature branch.
3. Make your changes.
4. Ensure all checks pass.
5. Submit a pull request with a clear description.
