<p align="center">
  <img src="docs/assets/logomark-white.png" alt="Awal Terminal" width="128">
</p>

<h1 align="center">Awal Terminal</h1>

<p align="center">
  The LLM-native terminal emulator for macOS.<br>
  Built for developers who work with AI coding agents.
</p>

<p align="center">
  <a href="https://awalterminal.github.io/Awal-terminal/">Website</a> &middot;
  <a href="https://github.com/AwalTerminal/Awal-terminal/releases/latest/download/AwalTerminal.zip">Download</a>
</p>

---

## What is Awal Terminal?

A native macOS terminal built from scratch with Swift and Rust, designed specifically for working with AI coding agents like Claude Code, Gemini CLI, and Codex CLI.

<p align="center">
  <img src="docs/assets/screenshot-1.png" alt="Awal Terminal screenshot" width="720">
</p>

## Features

| Feature | Description |
|---|---|
| GPU-Accelerated Rendering | Metal-powered rendering at 120fps with a glyph atlas and triple buffering |
| Smart Output Folding | AI tool calls, code blocks, and diffs auto-collapse into foldable regions. Click to expand |
| AI Side Panel | Track token usage, costs, context window, file references, and git changes in real time |
| LLM Profiles | Switch between Claude, Gemini, Codex, or plain shell in one click. Save per-model configurations |
| Voice Input | Push-to-talk, continuous, or wake word mode. Powered by Whisper for on-device transcription |
| Tabs & Splits | Native tabs with drag-to-reorder and nested split panes (vertical and horizontal) |
| Quick Terminal | Quake-style dropdown terminal with a global hotkey (`Ctrl+``) |
| Find in Terminal | Search through scrollback with match highlighting and keyboard navigation |
| Syntax Highlighting | Language-aware coloring for code blocks and diffs inside AI output |
| Git Integration | Live branch, status, and changed files displayed in the status bar and side panel. Click any changed file to view its diff inline |
| Resume Sessions | Browse and resume past AI sessions from the startup menu. Claude sessions show turn count and time ago; Codex and Gemini launch their built-in session pickers |
| Smart Notifications | Desktop alerts when long-running AI tasks complete |
| AI Components | Auto-detect your project stack and inject skills, rules, prompts, agents, MCP servers, and hooks into AI sessions from shared registries. Supports git, [localskills](https://localskills.dev), and local directory sources. Per-component enable/disable, security scanning, and import/export |
| Sub-Stack Detection | Automatically detects frameworks like Next.js, Django, Flask, Vapor, NestJS, and more on top of base stack detection for more targeted component injection |
| Large Paste Protection | Confirmation dialog for large pastes with options to save to file, truncate, or paste all. Configurable threshold |
| Fully Configurable | Theme colors, fonts, keybindings, and voice settings in a single config file |

## Getting Started

### Download

Grab the latest build from [GitHub Releases](https://github.com/AwalTerminal/Awal-terminal/releases/latest).

Since the app is not yet notarized with Apple, macOS will block it on first launch. After unzipping, run:

```bash
xattr -cr AwalTerminal.app
```

Then open the app normally.

### Build from Source

Requires Rust and Swift toolchains on macOS.

```bash
# Install just (task runner)
brew install just

# Build and run
just run

# Build release .app bundle
just bundle

# Create a new release
scripts/release.sh v0.2.0
```

### Configuration

All settings live in `~/.config/awal/config.toml`:

```toml
[font]
family = "JetBrains Mono"
size = 13.0

[theme]
bg = "#1e1e1e"
fg = "#e5e5e5"
accent = "#636efa"

[voice]
enabled = true
mode = "push_to_talk"
whisper_model = "tiny.en"

[paste]
warning_threshold = 100000
truncate_length = 10000

[tabs]
random_colors = true
# random_color_palette = "#E55353, #3498DB, #27AE60"
confirm_close = true

[ai_components]
enabled = true
auto_detect = true
auto_sync = true
security_scan = true

[ai_components.registry.awal-components]
url = "https://github.com/AwalTerminal/awal-ai-components-registry.git"
branch = "main"

[ai_components.registry.my-skill]
type = "localskills"
slugs = "ZpDEwZj1Yq"

[ai_components.registry.my-local]
type = "local"
path = "/path/to/local/registry"
```

## Architecture

```
core/       Rust — terminal emulation, ANSI parsing, AI output analysis
app/        Swift — macOS UI, Metal rendering, voice input, AI side panel
scripts/    Build and release scripts
build/      Release artifacts
docs/       Promotional website (GitHub Pages)
```

## Keybindings

| Action | Shortcut |
|---|---|
| New tab | `Cmd+T` |
| Close tab | `Cmd+W` |
| Split right | `Cmd+D` |
| Split down | `Cmd+Shift+D` |
| Next/prev pane | `Cmd+]` / `Cmd+[` |
| Find | `Cmd+F` |
| AI side panel | `Cmd+Shift+I` |
| Quick terminal | `` Ctrl+` `` |
| Sync AI components | `Cmd+Y` |
| Voice input (PTT) | `Ctrl+Shift+Space` |

## License

MIT
