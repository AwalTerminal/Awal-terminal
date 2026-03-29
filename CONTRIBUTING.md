# Contributing to Awal Terminal

Thanks for your interest in contributing! This guide will help you get set up and submit your first pull request.

## Prerequisites

- macOS 14 Sonoma or later
- [Rust](https://rustup.rs/) (stable)
- Xcode 15+ (for Swift toolchain and Metal)
- [just](https://github.com/casey/just) task runner: `brew install just`

## Project Structure

```
app/    — Swift macOS app (SwiftPM)
core/   — Rust core library (terminal emulation, parsing, rendering pipeline)
docs/   — GitHub Pages website
scripts/ — Build, bundle, and release scripts
```

## Getting Started

```bash
# Clone the repo
git clone https://github.com/AwalTerminal/awal-terminal.git
cd awal-terminal

# Build and run (debug)
just run

# Run all tests
just test

# Format Rust code
just fmt

# Lint
just lint
```

## Development Workflow

1. **Fork** the repo and create a branch from `main`
2. Make your changes
3. Run `just fmt` to format Rust code
4. Run `just test` to make sure all tests pass
5. Commit with a clear, concise message (see below)
6. Open a pull request against `main`

## Build Commands

| Command | Description |
|---|---|
| `just run` | Build and launch debug build |
| `just build` | Build everything (release) |
| `just build-debug` | Build everything (debug) |
| `just test` | Run all tests (Rust + Swift) |
| `just fmt` | Format Rust code |
| `just lint` | Run Clippy lints |
| `just coverage` | Run tests with code coverage |
| `just bundle` | Package as .app bundle |

## Commit Guidelines

- Write clear, concise commit messages
- Use imperative mood ("Add feature" not "Added feature")
- Focus on **why**, not just what

## Code Style

- **Rust:** Run `cargo fmt` before committing. Follow Clippy suggestions.
- **Swift:** Follow standard Swift conventions. Use SwiftPM for package management.

## What to Contribute

- Bug fixes
- Performance improvements
- New terminal features
- Test coverage improvements
- Documentation updates

If you're considering a large change or new feature, please [open an issue](https://github.com/AwalTerminal/awal-terminal/issues) first to discuss the approach.

## Testing

All pull requests must pass the existing test suite:

```bash
just test
```

If you're adding new functionality, please include tests.

## Documentation

If your change adds, removes, or modifies user-facing behavior, update the relevant docs:

- `README.md` — Features table, configuration, keybindings
- `docs/documentation.html` — Website documentation page
- `docs/index.html` — Landing page feature cards (if a major new feature)

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
