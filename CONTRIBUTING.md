# Contributing to yac.vim

Thank you for your interest in contributing to yac.vim.

## Development Setup

1. Clone the repository.
2. Install Zig 0.15+.
3. Install [uv](https://docs.astral.sh/uv/) for E2E test runner.
4. Build and test:
   ```bash
   zig build                        # Debug build
   zig build test                   # Zig unit tests
   zig build -Doptimize=ReleaseFast # Release build (required for E2E)
   uv run pytest                    # E2E tests (requires ReleaseFast binary)
   ```

## Code Quality Requirements

Before submitting a pull request:

1. **Formatting** — `zig fmt --check src/`
2. **Unit tests** — `zig build test`
3. **Release build** — `zig build -Doptimize=ReleaseFast`
4. **E2E tests** — `uv run pytest` (requires step 3)

## Pre-commit Checks

The repository provides `scripts/pre-commit`, which runs formatting and unit tests.

```bash
./scripts/setup-hooks.sh
```

## Submitting Changes

1. Fork the repository.
2. Create a feature branch.
3. Make your changes.
4. Ensure all checks pass (formatting, unit tests, E2E tests).
5. Submit a pull request with a clear description.
