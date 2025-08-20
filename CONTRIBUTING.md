# Contributing to yac.vim

Thank you for your interest in contributing to yac.vim! This document provides guidelines for contributing to the project.

## Code Quality Requirements

Before submitting a pull request, please ensure your code meets our quality standards:

### Rust Code Standards

1. **Formatting**: All Rust code must be formatted with `cargo fmt`
   ```bash
   cargo fmt --all
   ```

2. **Linting**: All code must pass `cargo clippy` without warnings
   ```bash
   cargo clippy --all-targets --all-features -- -D warnings
   ```

3. **Testing**: All tests must pass
   ```bash
   cargo test --verbose
   ```

4. **Building**: The project must build successfully
   ```bash
   cargo build --verbose
   ```

### Pre-commit Checks

Before committing, run these commands to ensure your code meets our standards:

```bash
# Format code
cargo fmt --all

# Check for linting issues
cargo clippy --all-targets --all-features -- -D warnings

# Run tests
cargo test --verbose

# Build project
cargo build --verbose
```

### Continuous Integration

Our CI pipeline automatically runs these checks on all pull requests:
- Code formatting verification (`cargo fmt --check`)
- Linting with clippy (`cargo clippy`)
- Build verification
- Test execution

**Important**: Pull requests that fail any of these checks cannot be merged to the main branch.

## Development Setup

1. Clone the repository
2. Install Rust toolchain with required components:
   ```bash
   rustup component add rustfmt clippy
   ```
3. Build the project:
   ```bash
   cargo build
   ```
4. Run tests:
   ```bash
   cargo test
   ```

## Submitting Changes

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Ensure all quality checks pass (see above)
5. Submit a pull request

Pull requests must:
- Pass all CI checks
- Include tests for new functionality
- Follow existing code style and conventions
- Include clear commit messages

## Questions?

If you have questions about contributing, please open an issue for discussion.