# Awal Terminal

## Build Commands

- **Debug build:** `cd app && swift build`
- **Universal release build (arm64 + x86_64):** `cd app && swift build -c release --arch arm64 --arch x86_64`
  - Output: `app/.build/apple/Products/Release/AwalTerminal`

## Commit Guidelines

- Never mention AI, Claude, or LLM in commit messages
- Do not include the `Co-Authored-By` trailer

## Releasing

Before every release, run all tests and ensure they pass with above 90% code coverage:

```
just test
```

The release script `scripts/release.sh <tag>` handles build, bundle, zip, tag, and GitHub release — but it has an interactive prompt, so run the steps manually when automating:

1. Run tests: `just test` (runs both Rust and Swift tests — must pass before proceeding)
2. Build: `cd app && swift build -c release --arch arm64 --arch x86_64`
3. Bundle: `scripts/bundle.sh universal`
4. Zip: `rm -f docs/AwalTerminal.zip && cd build && zip -r ../docs/AwalTerminal.zip AwalTerminal.app`
5. Commit the updated `docs/AwalTerminal.zip`
6. Tag: `git tag <tag>`
7. Push: `git push origin main && git push origin <tag>`
8. Generate changelog: review all commits since the previous tag (`git log <prev-tag>..HEAD --oneline`) and write a human-readable changelog grouped by category (Features, Fixes, Improvements). Include it in the release notes.
9. Release: `gh release create <tag> docs/AwalTerminal.zip --title "<tag>" --notes-file <changelog>`
10. Update Homebrew cask: in `homebrew-cask/awal-terminal.rb`, set `version` to the new tag (without `v` prefix) and update `sha256` (`shasum -a 256 docs/AwalTerminal.zip`). Commit and push.

- Website download link (`docs/index.html`) uses `/releases/latest/download/AwalTerminal.zip` — auto-resolves to newest release
- Check download counts: `gh api repos/AwalTerminal/Awal-terminal/releases -q '.[].assets[] | "\(.name): \(.download_count) downloads"'`

## Documentation Maintenance

When making changes that add, remove, or modify user-facing features (new UI elements, new shortcuts, new config options, behavior changes, etc.), you MUST also update the relevant documentation:

- **`README.md`** — Update the Features list, Keybindings table, Configuration example, or Architecture section as needed
- **`docs/documentation.html`** — Update the corresponding section(s) in the website documentation page (Getting Started, AI Features, Keyboard Shortcuts, Configuration, etc.)
- **`docs/index.html`** — Update the feature cards on the landing page if a major new feature is added

When adding or removing feature cards in `docs/index.html`, ensure the total count is a multiple of 3 (the grid column count). Order cards by importance — major differentiating features first. If needed, merge less important features into a single card to maintain full rows.

Do NOT update docs for internal refactors, bug fixes, or changes that don't affect the user-facing behavior.

## Project Structure

- `app/` — Swift macOS app (SwiftPM)
- `core/` — Rust core library
- `docs/` — GitHub Pages website
