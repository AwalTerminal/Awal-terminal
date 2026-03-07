# Awal Terminal

## Build Commands

- **Debug build:** `cd app && swift build`
- **Universal release build (arm64 + x86_64):** `cd app && swift build -c release --arch arm64 --arch x86_64`
  - Output: `app/.build/apple/Products/Release/AwalTerminal`

## Commit Guidelines

- Never mention AI, Claude, or LLM in commit messages
- Do not include the `Co-Authored-By` trailer

## Project Structure

- `app/` — Swift macOS app (SwiftPM)
- `core/` — Rust core library
