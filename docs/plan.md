# awal-terminal — LLM-Native Terminal Emulator

## Context

Current terminal emulators (iTerm2, Ghostty, Alacritty) are general-purpose tools with no awareness of LLM workflows. Developers using Claude Code spend hours staring at long AI outputs with no folding, no rich rendering, no semantic understanding of what's happening. Voice input for terminal interaction is virtually nonexistent. This project builds a terminal emulator from scratch that treats LLM interaction as a first-class use case while matching Ghostty's performance and native macOS feel.

## Architecture: Rust Core + Swift/AppKit Shell

**Same hybrid approach as Ghostty** (which uses Zig core + Swift shell):

| Layer | Technology | Why |
|---|---|---|
| Terminal engine | **Rust** (`vte` crate for VT parsing) | Performance, safety, battle-tested terminal crates |
| GPU rendering | **Metal** (direct) | Only GPU API on macOS, matches Ghostty |
| macOS UI | **Swift 6 / AppKit** | Native feel, fine-grained NSView + Metal control |
| Voice | **WhisperKit** + **whisper.cpp** | On-device, Apple Silicon optimized, privacy-first |
| Rust-Swift bridge | **C FFI** via `cbindgen` | Simplest, most proven (same as Ghostty) |
| Plugins | **WASM** via `wasmtime` | Language-agnostic, sandboxed |
| Config | **TOML** | Human-readable, matches Ghostty convention |
| Build | **just** + Cargo + SPM | Each tool handles its domain |

## Actual Project Structure

```
awal-terminal/
  justfile                          # Build orchestration
  docs/
    plan.md                         # This file

  core/                             # Rust library (libawalterminal)
    Cargo.toml
    build.rs                        # Generate C header via cbindgen
    cbindgen.toml                   # cbindgen config
    src/
      lib.rs                        # Crate root (mod ffi, io, terminal)
      ffi.rs                        # C API — ATSurface, 40+ exported functions
      io/
        mod.rs
        pty.rs                      # PTY creation, fork, spawn, read/write, resize
      terminal/
        mod.rs
        parser.rs                   # VT parser (wraps vte crate), CSI/OSC handlers
        screen.rs                   # Screen buffer (primary + alternate), scrollback, selection
        cell.rs                     # Cell, CCell, Color, CellAttrs (bitflags)
        modes.rs                    # TerminalModes, MouseMode
    include/
      awalterminal.h                # Generated C header for Swift

  app/                              # Swift macOS application
    Package.swift
    Sources/
      CAwalTerminal/                # C FFI module map
        module.modulemap
        shim.h
      App/
        ClaudeTerminalApp.swift     # @main, AppDelegate, main menu
        ModelCatalog.swift           # LLM model definitions (Claude, Gemini, Codex, Shell)
        WorkspaceStore.swift         # Recent workspace persistence
        ProfileStore.swift           # Per-model profile management
        TokenTracker.swift           # Token usage tracking for Claude sessions
        NotificationManager.swift    # Idle notifications + dock bounce
      Terminal/
        TerminalView.swift           # NSView + CAMetalLayer, input handling, TUI menu
        MetalRenderer.swift          # Metal pipeline, shaders, instanced rendering
        GlyphAtlas.swift             # Glyph atlas (4096x4096), Nerd Font fallback
      Window/
        TerminalWindowController.swift  # Window + custom tab management
        CustomTabBarView.swift       # Custom left-aligned fixed-width tab bar
        TabState.swift               # Per-tab state (splitContainer, statusBar, title)
        StatusBarView.swift          # Model, path, git, tokens, timer
        ConfigEditorWindow.swift     # Settings editor (structured + raw modes)
        LLMTabBar.swift              # Model selection segmented control
        ProfileBar.swift             # Profile selector + CRUD actions
      Splits/
        SplitContainerView.swift     # NSSplitView-based split pane manager
        SplitNode.swift              # Indirect enum tree (leaf | split)
    Resources/
      AppIcon.icns
```

## Threading Model (per terminal surface)

1. **Main Thread** (Swift): AppKit event loop, keyboard/mouse, window management
2. **I/O Thread** (Rust): PTY read/write, VT parsing, terminal state mutation
3. **Render Thread** (Rust/Metal): Frame composition, Metal command encoding
4. **Voice Thread** (Swift/Rust): Audio capture, VAD, Whisper inference

Communication via lock-free MPSC channels; shared mutex on terminal state (locked briefly during I/O writes and render reads).

## Phased Development

### Phase 0: Foundation (MVP — working terminal) ✅

- [x] Set up project structure (Cargo.toml, Package.swift, justfile, cbindgen)
- [x] PTY creation + process spawning in Rust (`io/pty.rs`)
- [x] Integrate `vte` crate for escape sequence parsing
- [x] Basic screen buffer (primary + alternate)
- [x] C FFI surface: `at_surface_new()`, `at_surface_key_event()`, `at_surface_read_cells()` + 40 more functions
- [x] AppKit window with NSView rendering text via CoreGraphics (pre-Metal proof of concept)
- [x] Wire keyboard input: Swift → FFI → Rust → PTY write
- [x] LLM launcher menu: TUI-rendered model selector (Claude, Gemini, Codex, Shell) with ↑↓/jk navigation, workspace history, ASCII art logo
- [x] Clean inherited environment (CLAUDECODE, CLAUDE_CODE_ENTRYPOINT) so LLM CLIs can launch without nesting errors
- **Result**: Window with LLM launcher menu → select model → terminal running chosen CLI

### Phase 1: GPU Rendering ✅

- [x] Replace CoreGraphics with Metal pipeline (`CAMetalLayer` in TerminalView)
- [x] Glyph atlas system — 4096x4096 R8Unorm texture, row-based packing, lazy rasterization
- [x] Metal shaders: 3 passes (background fill, glyph rendering from atlas, line decorations)
- [x] Font discovery via CoreText (monospace system font, bold/italic variants)
- [x] Nerd Font detection via CoreText enumeration + PUA glyph fallback
- [x] CVDisplayLink vsync-driven render loop dispatching to main thread
- [x] Triple buffering with DispatchSemaphore (3-frame inflight, non-blocking 16ms wait)
- **Result**: Smooth 120fps terminal rendering with colors

### Phase 2: Terminal Completeness ✅

- [x] Full SGR attributes (bold, dim, italic, underline, strikethrough, inverse, hidden, blink, 8/256/truecolor)
- [x] Cursor movement, save/restore, scroll regions, alternate screen
- [x] Scrollback buffer — 10K line ring buffer, viewport offset tracking
- [x] Selection engine (click, double-click word, triple-click line, drag)
- [x] Clipboard integration (copy selected text)
- [x] Mouse event reporting (X10, Normal, Button, Any modes + SGR encoding)
- [x] OSC sequences: window title (0/1/2), working directory (7), clipboard stub (52)
- [x] Bracketed paste mode
- [ ] Search in scrollback
- [ ] OSC 8 hyperlinks (clickable URLs in terminal output)
- [ ] Rectangular (block) selection mode
- [ ] Pass `vttest` conformance suite
- **Result**: Full terminal emulator, works with vim/tmux/htop

### Phase 3: Native macOS Polish — IN PROGRESS

- [x] Custom tab bar (fixed-width, left-aligned, close-on-hover, accent underline, context menu)
- [x] Split panes (horizontal/vertical, tree-based, focus navigation)
- [x] Tab navigation shortcuts (Cmd+Shift+]/[) and split shortcuts (Cmd+D, Cmd+Shift+D)
- [x] Drag-and-drop files → paste shell-escaped path
- [x] Idle notifications with cooldown + dock bounce
- [x] Token usage tracking for Claude sessions
- [x] Per-model profile system (create, rename, delete, activate)
- [x] Config editor window (structured tree + raw text, syntax coloring)
- [x] Display scale change handling (recreate renderer)
- [ ] Tab drag-to-reorder
- [ ] Quick terminal (dropdown from menu bar via global hotkey)
- [ ] Font ligature support (HarfBuzz or CoreText shaping)
- [ ] Configurable font family + size
- [ ] TOML theme system with light/dark mode switching
- [ ] User-configurable keybindings (TOML file)
- [ ] Preferences window (GUI for theme, font, keybindings)
- **Result**: Polished macOS terminal competitive with iTerm2/Ghostty

### Phase 4: AI Intelligence Layer (the differentiator)
- [ ] **Output Analyzer**: Detect Claude Code patterns (prompt markers, tool use blocks, code blocks, diffs) via terminal byte stream pattern matching
- [ ] **Smart Folding**: Collapsible regions for long outputs (file contents, search results, tool output)
- [ ] **AI Side Panel**: Current context display, token counter, cost estimation
- [ ] **Rich Rendering**: Markdown with syntax-highlighted code blocks (TreeSitter), inline diff viewer
- [ ] **Smart Copy**: Copy code blocks without prompt decorations
- [ ] **Session Management**: Save/restore sessions, integrate with `~/.claude/projects/` JSONL files
- [ ] **Progress Indicators**: Detect long-running AI operations, show progress overlay
- **Result**: LLM-aware terminal with context awareness and rich rendering

### Phase 5: Voice Input
- [ ] CoreAudio microphone capture with ring buffer
- [ ] Voice Activity Detection (Silero VAD or energy-based)
- [ ] WhisperKit integration (Apple Silicon / Core ML optimized, streaming)
- [ ] whisper.cpp as Rust-side fallback
- [ ] Push-to-talk mode (configurable hotkey) + continuous listening mode
- [ ] Voice commands: "scroll up", "clear", "new tab", "switch tab 2"
- [ ] Dictation mode: transcribed text typed as terminal input
- [ ] Voice UI: waveform visualization, live transcription preview, mode indicator
- [ ] Configurable wake word
- **Result**: Hands-free terminal with <500ms voice-to-text latency

### Phase 6: Advanced Features
- [ ] Kitty graphics protocol (image display in terminal)
- [ ] Kitty keyboard protocol
- [ ] Synchronized rendering (DCS sequences)
- [ ] Built-in multiplexer (session persistence, detach/reattach)
- [ ] Plugin system (WASM via wasmtime, capability-based sandboxing)
- [ ] Remote control (WebSocket server, mDNS discovery, mobile web app)
- [ ] File preview integration (Quick Look)

## What to Build Next

Phase 3 is nearly complete. The remaining items to finish before moving to Phase 4:

### High priority (finish Phase 3)
1. **Tab drag-to-reorder** — add drag gesture to CustomTabBarView, reorder `tabs` array
2. **Configurable font family + size** — TOML config key `font.family` / `font.size`, apply in GlyphAtlas
3. **TOML theme system** — `~/.config/awal/theme.toml` with color keys for bg, fg, cursor, selection, ANSI palette; parse in Rust or Swift
4. **User keybindings** — `~/.config/awal/keybindings.toml` mapping key combos to actions

### Medium priority (Phase 2 gaps)
5. **Search in scrollback** — Cmd+F overlay, highlight matches, navigate with Enter/Shift+Enter
6. **OSC 8 hyperlinks** — store URL per cell range, Cmd+click to open

### Lower priority (defer)
- Quick terminal dropdown (nice to have, not blocking Phase 4)
- Font ligatures / HarfBuzz (complex, marginal benefit for LLM workflows)
- Rectangular selection (rare use case)
- vttest conformance (useful but not user-facing)
- Preferences window (config files sufficient for now)

### Then: Phase 4 (AI Intelligence Layer)
This is the differentiator. Start with Output Analyzer + Smart Folding — these have the highest impact for Claude Code users.

## Key Technical Challenges

### 1. Rust ↔ Swift FFI
Stable C API via `cbindgen`. Opaque pointer handles (`at_surface_t*`). Shared memory buffers for screen state (Rust writes, Swift reads — zero-copy per frame). Metal resources created in Swift, raw pointers passed to Rust.

### 2. AI Output Detection (without modifying Claude Code)
Pattern-based detection on the parsed terminal stream: Claude Code uses consistent ANSI-colored markers. Also monitor `~/.claude/projects/*/` JSONL files for structured data. Heuristic confidence scoring — only high-confidence detections trigger UI changes.

### 3. Voice Latency (<500ms target)
Streaming WhisperKit inference (chunks every 500ms). Tiny model for commands, large model for dictation. VAD gates audio before forwarding to Whisper. Apple Neural Engine acceleration on M-series chips.

### 4. Performance (matching Ghostty)
Pre-compiled Metal shaders (`.metallib` at build time). Dirty-region rendering (only re-render changed cells). Shared glyph atlas across surfaces. Lazy-load voice models and AI features. Target: <100ms startup, <4ms render frame, <50MB base memory.

## Verification Plan
1. **Phase 0**: Launch app → zsh prompt appears → type commands → see output ✅
2. **Phase 1**: Run `cat large-file.txt` → smooth scrolling at 120fps, check with Metal System Trace ✅
3. **Phase 2**: Run `vttest` → pass all applicable tests; run vim, tmux, htop → correct rendering ✅ (vim/tmux/htop work, vttest formal pass pending)
4. **Phase 3**: Create tabs/splits, drag-drop files, switch themes — all feel native (tabs/splits done, themes pending)
5. **Phase 4**: Run Claude Code → AI panel shows context, long outputs fold, diffs render inline
6. **Phase 5**: Press push-to-talk → speak "list files" → `ls` appears in terminal
7. **Performance**: Profile with Instruments throughout — startup <100ms, frame time <4ms
