# Awal Terminal

## Build Commands

- **Debug build:** `cd app && swift build`
- **Universal release build (arm64 + x86_64):** `cd app && swift build -c release --arch arm64 --arch x86_64`
  - Output: `app/.build/apple/Products/Release/AwalTerminal`

## Commit Guidelines

- Never mention AI, Claude, or LLM in commit messages
- Do not include the `Co-Authored-By` trailer

## Releasing

The release script `scripts/release.sh <tag>` handles build, bundle, zip, tag, and GitHub release — but it has an interactive prompt, so run the steps manually when automating:

1. Build: `cd app && swift build -c release --arch arm64 --arch x86_64`
2. Bundle: `scripts/bundle.sh universal`
3. Zip: `rm -f docs/AwalTerminal.zip && cd build && zip -r ../docs/AwalTerminal.zip AwalTerminal.app`
4. Commit the updated `docs/AwalTerminal.zip`
5. Tag: `git tag <tag>`
6. Push: `git push origin main && git push origin <tag>`
7. Generate changelog: review all commits since the previous tag (`git log <prev-tag>..HEAD --oneline`) and write a human-readable changelog grouped by category (Features, Fixes, Improvements). Include it in the release notes.
8. Release: `gh release create <tag> docs/AwalTerminal.zip --title "<tag>" --notes-file <changelog>`

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
