# claude-terminal — LLM-Native Terminal Emulator

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

## Project Structure

```
claude-terminal/
  justfile                          # Build orchestration

  core/                             # Rust library (libclaudeterminal)
    Cargo.toml
    build.rs                        # Compile Metal shaders, generate C header
    src/
      lib.rs                        # Crate root
      ffi.rs                        # C API (extern "C" functions)
      terminal/
        parser.rs                   # VT parser (wraps vte crate)
        screen.rs                   # Screen buffer (primary + alternate)
        cell.rs                     # Cell struct (char, attrs, colors)
        scrollback.rs               # Ring buffer scrollback
        modes.rs                    # Terminal modes (DEC, ANSI)
        selection.rs                # Text selection engine
      io/
        pty.rs                      # PTY creation, read/write, resize
        process.rs                  # Child process management
      renderer/
        metal/
          pipeline.rs               # Metal render pipeline states
          atlas.rs                  # Glyph atlas (texture packing)
          cell_renderer.rs          # Cell bg + text rendering
          cursor_renderer.rs        # Cursor overlay
      font/
        discovery.rs                # CoreText font discovery
        shaping.rs                  # Text shaping (harfbuzz/CoreText)
        atlas.rs                    # Glyph → texture atlas management
      ai/
        output_analyzer.rs          # Detect Claude Code output patterns
        semantic_parser.rs          # Parse command boundaries, code blocks
        folding.rs                  # Collapsible region detection
        diff_detector.rs            # Inline diff detection
        session.rs                  # Conversation session tracking
        token_counter.rs            # Token usage estimation
      voice/
        audio_capture.rs            # CoreAudio mic input
        vad.rs                      # Voice Activity Detection
        whisper.rs                  # whisper.cpp C FFI integration
        commands.rs                 # Voice command grammar + dispatch
      config/
        parser.rs                   # TOML config parser
        theme.rs                    # Theme/color scheme management
        keybindings.rs              # Keybinding config
      multiplexer/
        layout.rs                   # Split/tab layout tree
        pane.rs                     # Pane abstraction
      plugin/
        wasm_runtime.rs             # wasmtime integration
        api.rs                      # Plugin API surface
      remote/
        websocket.rs                # WebSocket server (phone control)
    shaders/
      cell_bg.metal                 # Cell background pass
      cell_text.metal               # Glyph rendering from atlas
      cursor.metal                  # Cursor overlay
      image.metal                   # Image rendering (Kitty protocol)
    include/
      claudeterminal.h              # Generated C header for Swift

  app/                              # Swift macOS application
    Package.swift
    Sources/
      App/
        ClaudeTerminalApp.swift     # @main, NSApplicationDelegate
      Window/
        TerminalWindowController.swift
        QuickTerminal.swift         # Dropdown terminal (global hotkey)
      Terminal/
        TerminalView.swift          # NSView + CAMetalLayer
        TerminalSurface.swift       # Bridge to Rust surface
        InputHandler.swift          # Keyboard/IME handling
      Tabs/
        TabBar.swift                # Native tab bar
      Splits/
        SplitView.swift             # NSSplitView-based splits
      AI/
        AIPanel.swift               # Side panel (context, tokens, session)
        DiffViewer.swift            # Rich diff rendering
        MarkdownView.swift          # Markdown rendering for AI output
        CodeBlockView.swift         # Syntax-highlighted code blocks
      Voice/
        VoiceInputView.swift        # Waveform + transcription UI
        VoiceManager.swift          # WhisperKit coordinator
      Preferences/
        PreferencesWindow.swift     # Settings GUI
```

## Threading Model (per terminal surface)

1. **Main Thread** (Swift): AppKit event loop, keyboard/mouse, window management
2. **I/O Thread** (Rust): PTY read/write, VT parsing, terminal state mutation
3. **Render Thread** (Rust/Metal): Frame composition, Metal command encoding
4. **Voice Thread** (Swift/Rust): Audio capture, VAD, Whisper inference

Communication via lock-free MPSC channels; shared mutex on terminal state (locked briefly during I/O writes and render reads).

## Phased Development

### Phase 0: Foundation (MVP — working terminal)
- [ ] Set up project structure (Cargo.toml, Package.swift, justfile, cbindgen)
- [ ] PTY creation + process spawning in Rust (`io/pty.rs`)
- [ ] Integrate `vte` crate for escape sequence parsing
- [ ] Basic screen buffer (primary + alternate)
- [ ] C FFI surface: `ct_surface_new()`, `ct_surface_key_event()`, `ct_surface_read_cells()`
- [ ] AppKit window with NSView rendering text via CoreGraphics (pre-Metal proof of concept)
- [ ] Wire keyboard input: Swift → FFI → Rust → PTY write
- **Result**: Window running `/bin/zsh` with basic text I/O

### Phase 1: GPU Rendering
- [ ] Replace CoreGraphics with Metal pipeline (`CAMetalLayer` in TerminalView)
- [ ] Glyph atlas system (pack glyphs into Metal textures)
- [ ] Metal shaders: background fill → cell backgrounds → text from atlas → cursor
- [ ] Font discovery via CoreText, text shaping via harfbuzz
- [ ] Render thread with vsync-driven draw loop
- [ ] Double/triple buffering
- **Result**: Smooth 120fps terminal rendering with colors

### Phase 2: Terminal Completeness
- [ ] Full SGR attributes (bold, italic, underline, 256-color, truecolor)
- [ ] Cursor movement, save/restore, scroll regions, alternate screen
- [ ] Scrollback buffer (ring buffer, page-based allocation)
- [ ] Selection engine (mouse select, rectangular select)
- [ ] Clipboard integration, search in scrollback
- [ ] Mouse event reporting (all modes)
- [ ] OSC sequences (window title, hyperlinks, clipboard)
- [ ] Pass `vttest` conformance suite
- **Result**: Full terminal emulator, works with vim/tmux/htop

### Phase 3: Native macOS Polish
- [ ] Tab bar, split panes, multiple windows
- [ ] Quick terminal (dropdown from menu bar via global hotkey)
- [ ] Font ligature + Nerd Font support
- [ ] TOML theme system with light/dark mode switching
- [ ] Keybinding configuration, preferences window
- [ ] Drag-and-drop files → paste path
- [ ] Notifications for long-running commands
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

## Key Technical Challenges

### 1. Rust ↔ Swift FFI
Stable C API via `cbindgen`. Opaque pointer handles (`ct_surface_t*`). Shared memory buffers for screen state (Rust writes, Swift reads — zero-copy per frame). Metal resources created in Swift, raw pointers passed to Rust.

### 2. AI Output Detection (without modifying Claude Code)
Pattern-based detection on the parsed terminal stream: Claude Code uses consistent ANSI-colored markers. Also monitor `~/.claude/projects/*/` JSONL files for structured data. Heuristic confidence scoring — only high-confidence detections trigger UI changes.

### 3. Voice Latency (<500ms target)
Streaming WhisperKit inference (chunks every 500ms). Tiny model for commands, large model for dictation. VAD gates audio before forwarding to Whisper. Apple Neural Engine acceleration on M-series chips.

### 4. Performance (matching Ghostty)
Pre-compiled Metal shaders (`.metallib` at build time). Dirty-region rendering (only re-render changed cells). Shared glyph atlas across surfaces. Lazy-load voice models and AI features. Target: <100ms startup, <4ms render frame, <50MB base memory.

## Verification Plan
1. **Phase 0**: Launch app → zsh prompt appears → type commands → see output
2. **Phase 1**: Run `cat large-file.txt` → smooth scrolling at 120fps, check with Metal System Trace
3. **Phase 2**: Run `vttest` → pass all applicable tests; run vim, tmux, htop → correct rendering
4. **Phase 3**: Create tabs/splits, use quick terminal, switch themes — all feel native
5. **Phase 4**: Run Claude Code → AI panel shows context, long outputs fold, diffs render inline
6. **Phase 5**: Press push-to-talk → speak "list files" → `ls` appears in terminal
7. **Performance**: Profile with Instruments throughout — startup <100ms, frame time <4ms
