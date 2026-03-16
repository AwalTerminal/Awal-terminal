use crate::io::pty::Pty;
use crate::io::write_queue::WriteQueue;
use crate::terminal::ai_analyzer::AiAnalyzer;
use crate::terminal::cell::{default_palette, CCell, CellAttrs, Color};
use crate::terminal::parser::Parser;
use crate::terminal::screen::Screen;
use std::ffi::CString;
use std::os::fd::RawFd;
use std::os::raw::c_char;
use std::slice;

/// Opaque handle to a terminal surface.
pub struct ATSurface {
    screen: Screen,
    parser: Parser,
    pty: Option<Pty>,
    read_buf: Vec<u8>,
    palette: [Color; 256],
    analyzer: AiAnalyzer,
    default_fg: (u8, u8, u8),
    default_bg: (u8, u8, u8),
    write_queue: WriteQueue,
}

/// Helper: safely convert a nullable const pointer to a reference, returning $default on null.
macro_rules! ref_or {
    ($ptr:expr) => {
        if $ptr.is_null() {
            return;
        } else {
            unsafe { &*$ptr }
        }
    };
    ($ptr:expr, $default:expr) => {
        if $ptr.is_null() {
            return $default;
        } else {
            unsafe { &*$ptr }
        }
    };
}

/// Helper: safely convert a nullable mut pointer to a mutable reference, returning $default on null.
macro_rules! mut_ref_or {
    ($ptr:expr) => {
        if $ptr.is_null() {
            return;
        } else {
            unsafe { &mut *$ptr }
        }
    };
    ($ptr:expr, $default:expr) => {
        if $ptr.is_null() {
            return $default;
        } else {
            unsafe { &mut *$ptr }
        }
    };
}

/// Create a new terminal surface with the given dimensions.
#[no_mangle]
pub extern "C" fn at_surface_new(cols: u32, rows: u32) -> *mut ATSurface {
    let surface = Box::new(ATSurface {
        screen: Screen::new(cols as usize, rows as usize),
        parser: Parser::new(),
        pty: None,
        read_buf: vec![0u8; 65536],
        palette: default_palette(),
        analyzer: AiAnalyzer::new(),
        default_fg: (229, 229, 229),
        default_bg: (30, 30, 30),
        write_queue: WriteQueue::new(),
    });
    Box::into_raw(surface)
}

/// Terminate the child process (PTY) without destroying the surface.
/// Safe to call multiple times — subsequent calls are no-ops.
#[no_mangle]
pub extern "C" fn at_surface_terminate(surface: *mut ATSurface) {
    let surface = mut_ref_or!(surface);
    if let Some(pty) = surface.pty.take() {
        drop(pty); // triggers Pty::drop which sends SIGHUP/SIGKILL and reaps
    }
}

/// Destroy a terminal surface.
#[no_mangle]
pub extern "C" fn at_surface_destroy(surface: *mut ATSurface) {
    if !surface.is_null() {
        unsafe {
            drop(Box::from_raw(surface));
        }
    }
}

/// Spawn a shell process. Returns 0 on success, -1 on failure.
#[no_mangle]
pub extern "C" fn at_surface_spawn_shell(
    surface: *mut ATSurface,
    shell: *const libc::c_char,
) -> i32 {
    let surface = mut_ref_or!(surface, -1);
    let shell_str = if shell.is_null() {
        "/bin/zsh"
    } else {
        unsafe {
            std::ffi::CStr::from_ptr(shell)
                .to_str()
                .unwrap_or("/bin/zsh")
        }
    };

    match Pty::spawn(
        shell_str,
        surface.screen.cols as u16,
        surface.screen.rows as u16,
        &[],
    ) {
        Ok(pty) => {
            surface.pty = Some(pty);
            0
        }
        Err(e) => {
            eprintln!("Failed to spawn shell: {}", e);
            -1
        }
    }
}

/// Spawn a shell running a specific command. Returns 0 on success, -1 on failure.
/// The shell is invoked as a login shell with `-c command`.
#[no_mangle]
pub extern "C" fn at_surface_spawn_command(
    surface: *mut ATSurface,
    shell: *const libc::c_char,
    command: *const libc::c_char,
) -> i32 {
    let surface = mut_ref_or!(surface, -1);
    let shell_str = if shell.is_null() {
        "/bin/zsh"
    } else {
        unsafe {
            std::ffi::CStr::from_ptr(shell)
                .to_str()
                .unwrap_or("/bin/zsh")
        }
    };
    let cmd_str = if command.is_null() {
        ""
    } else {
        unsafe { std::ffi::CStr::from_ptr(command).to_str().unwrap_or("") }
    };

    match Pty::spawn_with_command(
        shell_str,
        surface.screen.cols as u16,
        surface.screen.rows as u16,
        &[],
        cmd_str,
    ) {
        Ok(pty) => {
            surface.pty = Some(pty);
            0
        }
        Err(e) => {
            eprintln!("Failed to spawn command: {}", e);
            -1
        }
    }
}

/// Get the PTY master file descriptor (for polling).
#[no_mangle]
pub extern "C" fn at_surface_get_fd(surface: *const ATSurface) -> RawFd {
    let surface = ref_or!(surface, -1);
    surface.pty.as_ref().map_or(-1, |pty| pty.master_fd())
}

/// Get the child shell PID.
#[no_mangle]
pub extern "C" fn at_surface_get_child_pid(surface: *const ATSurface) -> i32 {
    let surface = ref_or!(surface, -1);
    surface
        .pty
        .as_ref()
        .map_or(-1, |pty| pty.child_pid.as_raw())
}

/// Read from the PTY and process VT sequences. Returns number of bytes read, 0 if nothing available, -1 on error.
#[no_mangle]
pub extern "C" fn at_surface_process_pty(surface: *mut ATSurface) -> i32 {
    let surface = mut_ref_or!(surface, -1);
    let pty = match &surface.pty {
        Some(p) => p,
        None => return -1,
    };

    match pty.read(&mut surface.read_buf) {
        Ok(n) if n > 0 => {
            let responses = surface
                .parser
                .process(&surface.read_buf[..n], &mut surface.screen);
            // Write any terminal responses (DSR, DA1, etc.) back to the PTY
            if let Some(pty) = &surface.pty {
                for response in responses {
                    let _ = pty.write(&response);
                }
            }
            n as i32
        }
        Ok(_) => 0,
        Err(nix::Error::EAGAIN) => 0,
        Err(_) => -1,
    }
}

/// Send a key event (raw bytes) to the PTY.
#[no_mangle]
pub extern "C" fn at_surface_key_event(surface: *mut ATSurface, data: *const u8, len: u32) -> i32 {
    let surface = mut_ref_or!(surface, -1);
    if data.is_null() || len == 0 {
        return -1;
    }
    let bytes = unsafe { slice::from_raw_parts(data, len as usize) };
    let pty = match &surface.pty {
        Some(p) => p,
        None => return -1,
    };

    match pty.write(bytes) {
        Ok(n) => n as i32,
        Err(_) => -1,
    }
}

/// Queue data for asynchronous writing to the PTY.
/// Returns 0 on success, -1 if surface/data is invalid.
#[no_mangle]
pub extern "C" fn at_surface_queue_write(
    surface: *mut ATSurface,
    data: *const u8,
    len: u32,
) -> i32 {
    let surface = mut_ref_or!(surface, -1);
    if data.is_null() || len == 0 {
        return -1;
    }
    let bytes = unsafe { slice::from_raw_parts(data, len as usize) };
    surface.write_queue.push(bytes);
    0
}

/// Drain pending writes to the PTY. Returns bytes written, 0 if nothing pending, -1 on error.
#[no_mangle]
pub extern "C" fn at_surface_drain_writes(surface: *mut ATSurface) -> i32 {
    let surface = mut_ref_or!(surface, -1);
    let fd = match &surface.pty {
        Some(p) => p.master_fd(),
        None => return -1,
    };
    surface.write_queue.drain(fd)
}

/// Check if there are pending writes in the queue.
#[no_mangle]
pub extern "C" fn at_surface_has_pending_writes(surface: *const ATSurface) -> bool {
    let surface = ref_or!(surface, false);
    surface.write_queue.has_pending()
}

/// Get the screen dimensions.
#[no_mangle]
pub extern "C" fn at_surface_get_size(surface: *const ATSurface, cols: *mut u32, rows: *mut u32) {
    let surface = ref_or!(surface);
    unsafe {
        *cols = surface.screen.cols as u32;
        *rows = surface.screen.rows as u32;
    }
}

/// Resize the terminal surface (screen grid + PTY).
#[no_mangle]
pub extern "C" fn at_surface_resize(surface: *mut ATSurface, cols: u32, rows: u32) {
    let surface = mut_ref_or!(surface);
    surface.screen.resize(cols as usize, rows as usize);
    if let Some(pty) = &surface.pty {
        let _ = pty.resize(cols as u16, rows as u16);
    }
}

/// Read cells from the screen into the provided buffer (viewport-aware).
/// Buffer must have space for (cols * rows) CCells.
/// Returns the number of cells written.
#[no_mangle]
pub extern "C" fn at_surface_read_cells(
    surface: *const ATSurface,
    out: *mut CCell,
    max_cells: u32,
) -> u32 {
    let surface = ref_or!(surface, 0);
    if out.is_null() {
        return 0;
    }
    let screen = &surface.screen;
    let rows = screen.rows;
    let cols = screen.cols;
    let total = rows * cols;
    let count = total.min(max_cells as usize);

    let out_slice = unsafe { slice::from_raw_parts_mut(out, count) };
    let palette = &surface.palette;

    let mut idx = 0;
    for row in 0..rows {
        for col in 0..cols {
            if idx >= count {
                return idx as u32;
            }
            let cell = screen.viewport_cell(row, col);

            // Handle inverse attribute
            let has_inverse = cell.attrs.contains(CellAttrs::INVERSE);
            let has_hidden = cell.attrs.contains(CellAttrs::HIDDEN);

            let (mut fg_r, mut fg_g, mut fg_b) =
                cell.fg.to_rgb_with_default(palette, surface.default_fg);
            let (mut bg_r, mut bg_g, mut bg_b) =
                cell.bg.to_rgb_with_default(palette, surface.default_bg);

            if has_inverse {
                std::mem::swap(&mut fg_r, &mut bg_r);
                std::mem::swap(&mut fg_g, &mut bg_g);
                std::mem::swap(&mut fg_b, &mut bg_b);
            }

            if has_hidden {
                fg_r = bg_r;
                fg_g = bg_g;
                fg_b = bg_b;
            }

            // Ensure foreground is visible against background.
            // If fg is too close to bg (e.g. ANSI black on dark terminal bg),
            // bump fg to a readable gray. Only affects fg, not bg.
            {
                let fg_luma = fg_r as i16 * 3 + fg_g as i16 * 6 + fg_b as i16; // weighted ~10x
                let bg_luma = bg_r as i16 * 3 + bg_g as i16 * 6 + bg_b as i16;
                if (fg_luma - bg_luma).unsigned_abs() < 100 && !has_hidden {
                    if bg_luma < 1280 {
                        // Dark bg: lighten fg
                        fg_r = fg_r.saturating_add(90);
                        fg_g = fg_g.saturating_add(90);
                        fg_b = fg_b.saturating_add(90);
                    } else {
                        // Light bg: darken fg
                        fg_r = fg_r.saturating_sub(90);
                        fg_g = fg_g.saturating_sub(90);
                        fg_b = fg_b.saturating_sub(90);
                    }
                }
            }

            let fg_a: u8 = if cell.attrs.contains(CellAttrs::DIM) {
                128
            } else {
                255
            };

            // Selection highlight: compute absolute row for selection check
            let abs_row = if screen.viewport_offset == 0 || screen.modes.alternate_screen {
                row as i64
            } else {
                let scrollback_len = screen.scrollback.len();
                let viewport_start = scrollback_len.saturating_sub(screen.viewport_offset);
                (viewport_start + row) as i64 - scrollback_len as i64
            };

            let selected = screen.selection.contains(col, abs_row);
            if selected {
                // Selection: white background, grey text
                fg_r = 128;
                fg_g = 128;
                fg_b = 128;
                bg_r = 255;
                bg_g = 255;
                bg_b = 255;
            }

            out_slice[idx] = CCell {
                codepoint: cell.ch as u32,
                fg_r,
                fg_g,
                fg_b,
                fg_a,
                bg_r,
                bg_g,
                bg_b,
                bg_a: 255,
                attrs: cell.attrs.bits(),
            };
            idx += 1;
        }
    }
    idx as u32
}

/// Get cursor position.
#[no_mangle]
pub extern "C" fn at_surface_get_cursor(
    surface: *const ATSurface,
    row: *mut u32,
    col: *mut u32,
    visible: *mut bool,
) {
    let surface = ref_or!(surface);
    unsafe {
        *row = surface.screen.cursor.row as u32;
        *col = surface.screen.cursor.col as u32;
        *visible = surface.screen.modes.cursor_visible;
    }
}

/// Check if screen content has changed since last check. Resets the dirty flag.
#[no_mangle]
pub extern "C" fn at_surface_is_dirty(surface: *mut ATSurface) -> bool {
    let surface = mut_ref_or!(surface, false);
    let dirty = surface.screen.dirty;
    surface.screen.dirty = false;
    dirty
}

/// Get the current kitty keyboard protocol flags (0 = legacy mode).
#[no_mangle]
pub extern "C" fn at_surface_get_kitty_keyboard_flags(surface: *const ATSurface) -> u32 {
    let surface = ref_or!(surface, 0);
    surface.screen.modes.kitty_keyboard_flags()
}

/// Check if synchronized output mode (mode 2026) is active.
/// When active, the caller should defer rendering until the mode is reset.
#[no_mangle]
pub extern "C" fn at_surface_is_synchronized(surface: *const ATSurface) -> bool {
    let surface = ref_or!(surface, false);
    surface.screen.modes.synchronized_output
}

/// Feed raw bytes directly into the VT parser (no PTY needed).
/// Used for rendering TUI menus before a shell is spawned.
#[no_mangle]
pub extern "C" fn at_surface_feed_bytes(surface: *mut ATSurface, data: *const u8, len: u32) {
    let surface = mut_ref_or!(surface);
    if data.is_null() || len == 0 {
        return;
    }
    let bytes = unsafe { slice::from_raw_parts(data, len as usize) };
    let _ = surface.parser.process(bytes, &mut surface.screen);
}

/// Initialize logging (call once at startup).
#[no_mangle]
pub extern "C" fn at_init_logging() {
    let _ = env_logger::try_init();
}

// --- Palette ---

/// Set a palette color (index 0-255) to an RGB value.
#[no_mangle]
pub extern "C" fn at_surface_set_palette_color(
    surface: *mut ATSurface,
    index: u8,
    r: u8,
    g: u8,
    b: u8,
) {
    let surface = mut_ref_or!(surface);
    surface.palette[index as usize] = Color::Rgb(r, g, b);
}

// --- Default Colors ---

/// Set the default foreground color used when a cell has Color::Default.
#[no_mangle]
pub extern "C" fn at_surface_set_default_fg(surface: *mut ATSurface, r: u8, g: u8, b: u8) {
    let surface = mut_ref_or!(surface);
    surface.default_fg = (r, g, b);
}

/// Set the default background color used when a cell has Color::Default.
#[no_mangle]
pub extern "C" fn at_surface_set_default_bg(surface: *mut ATSurface, r: u8, g: u8, b: u8) {
    let surface = mut_ref_or!(surface);
    surface.default_bg = (r, g, b);
}

// --- Scrollback ---

/// Scroll the viewport by delta lines. Positive = scroll up (into history).
#[no_mangle]
pub extern "C" fn at_surface_scroll_viewport(surface: *mut ATSurface, delta: i32) {
    let surface = mut_ref_or!(surface);
    surface.screen.scroll_viewport(delta);
}

/// Get current viewport offset (0 = live, >0 = scrolled into history).
#[no_mangle]
pub extern "C" fn at_surface_get_viewport_offset(surface: *const ATSurface) -> i32 {
    let surface = ref_or!(surface, 0);
    surface.screen.viewport_offset as i32
}

/// Get scrollback buffer length.
#[no_mangle]
pub extern "C" fn at_surface_get_scrollback_len(surface: *const ATSurface) -> i32 {
    let surface = ref_or!(surface, 0);
    surface.screen.scrollback.len() as i32
}

// --- Selection ---

/// Start a selection at grid position.
#[no_mangle]
pub extern "C" fn at_surface_start_selection(surface: *mut ATSurface, col: u32, row: i32) {
    let surface = mut_ref_or!(surface);
    let sel = &mut surface.screen.selection;
    sel.start_col = col as usize;
    sel.start_row = row as i64;
    sel.end_col = col as usize;
    sel.end_row = row as i64;
    sel.active = true;
    surface.screen.dirty = true;
}

/// Update selection endpoint.
#[no_mangle]
pub extern "C" fn at_surface_update_selection(surface: *mut ATSurface, col: u32, row: i32) {
    let surface = mut_ref_or!(surface);
    let sel = &mut surface.screen.selection;
    sel.end_col = col as usize;
    sel.end_row = row as i64;
    surface.screen.dirty = true;
}

/// Set rectangular (block) selection mode.
#[no_mangle]
pub extern "C" fn at_surface_set_rectangular_selection(surface: *mut ATSurface, rectangular: bool) {
    let surface = mut_ref_or!(surface);
    surface.screen.selection.rectangular = rectangular;
    surface.screen.dirty = true;
}

/// Clear the selection.
#[no_mangle]
pub extern "C" fn at_surface_clear_selection(surface: *mut ATSurface) {
    let surface = mut_ref_or!(surface);
    surface.screen.selection.active = false;
    surface.screen.dirty = true;
}

/// Get selected text. Returns a C string that must be freed with `at_free_string`.
#[no_mangle]
pub extern "C" fn at_surface_get_selected_text(surface: *const ATSurface) -> *mut c_char {
    let surface = ref_or!(surface, std::ptr::null_mut());
    let text = surface.screen.get_selected_text();
    match CString::new(text) {
        Ok(cs) => cs.into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Free a string returned by FFI functions.
#[no_mangle]
pub extern "C" fn at_free_string(s: *mut c_char) {
    if !s.is_null() {
        unsafe {
            drop(CString::from_raw(s));
        }
    }
}

// --- Mouse Mode ---

/// Get the current mouse tracking mode (0=none, 1=click, 2=button/drag, 3=any).
#[no_mangle]
pub extern "C" fn at_surface_get_mouse_mode(surface: *const ATSurface) -> i32 {
    let surface = ref_or!(surface, 0);
    use crate::terminal::modes::MouseMode;
    match surface.screen.modes.mouse_tracking {
        MouseMode::None => 0,
        MouseMode::X10 => 1,
        MouseMode::Normal => 1,
        MouseMode::Button => 2,
        MouseMode::Any => 3,
    }
}

/// Check if SGR mouse mode (1006) is enabled.
#[no_mangle]
pub extern "C" fn at_surface_get_sgr_mouse(surface: *const ATSurface) -> bool {
    let surface = ref_or!(surface, false);
    surface.screen.modes.sgr_mouse
}

// --- Bracketed Paste ---

/// Check if bracketed paste mode is enabled.
#[no_mangle]
pub extern "C" fn at_surface_get_bracketed_paste(surface: *const ATSurface) -> bool {
    let surface = ref_or!(surface, false);
    surface.screen.modes.bracketed_paste
}

// --- Title ---

/// Get the terminal title. Returns a C string that must be freed with `at_free_string`.
#[no_mangle]
pub extern "C" fn at_surface_get_title(surface: *const ATSurface) -> *mut c_char {
    let surface = ref_or!(surface, std::ptr::null_mut());
    match CString::new(surface.screen.title.clone()) {
        Ok(cs) => cs.into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Get the working directory (from OSC 7). Returns a C string that must be freed with `at_free_string`.
#[no_mangle]
pub extern "C" fn at_surface_get_working_directory(surface: *const ATSurface) -> *mut c_char {
    let surface = ref_or!(surface, std::ptr::null_mut());
    match CString::new(surface.screen.working_directory.clone()) {
        Ok(cs) => cs.into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

// --- Hyperlinks ---

/// Get the hyperlink URL for a cell at the given viewport position.
/// Returns null if no hyperlink. Caller must free with `at_free_string`.
#[no_mangle]
pub extern "C" fn at_surface_get_hyperlink(
    surface: *const ATSurface,
    col: u32,
    row: u32,
) -> *mut c_char {
    let surface = ref_or!(surface, std::ptr::null_mut());
    let screen = &surface.screen;
    let row = row as usize;
    let col = col as usize;

    // Determine which hyperlink storage to query based on viewport position
    let url = if screen.viewport_offset == 0 || screen.modes.alternate_screen {
        // Reading from active grid (physical row keys handled by accessor)
        screen.active_grid().get_hyperlink(row, col)
    } else {
        let scrollback_len = screen.scrollback.len();
        let viewport_start = scrollback_len.saturating_sub(screen.viewport_offset);
        let abs_row = viewport_start + row;
        if abs_row < scrollback_len {
            // Reading from scrollback (absolute key = base + deque index)
            screen
                .scrollback_hyperlinks
                .get(&(screen.scrollback_hyperlink_base + abs_row, col))
        } else {
            // Reading from active grid
            let grid_row = abs_row - scrollback_len;
            screen.active_grid().get_hyperlink(grid_row, col)
        }
    };

    match url {
        Some(u) => match CString::new(u.as_str()) {
            Ok(cs) => cs.into_raw(),
            Err(_) => std::ptr::null_mut(),
        },
        None => std::ptr::null_mut(),
    }
}

// --- Search ---

/// Search result entry.
#[repr(C)]
pub struct ATSearchResult {
    pub col: u32,
    pub row: i32, // negative = scrollback
}

/// Search scrollback + screen for a query string.
/// Writes results into `out`, returns the number of results written (up to max_results).
#[no_mangle]
pub extern "C" fn at_surface_search(
    surface: *const ATSurface,
    query: *const c_char,
    out: *mut ATSearchResult,
    max_results: u32,
) -> u32 {
    let surface = ref_or!(surface, 0);
    if query.is_null() || out.is_null() {
        return 0;
    }
    let query_str = unsafe { std::ffi::CStr::from_ptr(query).to_str().unwrap_or("") };
    let results = surface.screen.search(query_str);
    let count = results.len().min(max_results as usize);
    let out_slice = unsafe { slice::from_raw_parts_mut(out, count) };
    for (i, (col, row)) in results.iter().take(count).enumerate() {
        out_slice[i] = ATSearchResult {
            col: *col as u32,
            row: *row as i32,
        };
    }
    count as u32
}

// --- AI Analyzer ---

/// C-compatible output region for FFI transfer.
#[repr(C)]
pub struct COutputRegion {
    pub start_row: i32,
    pub end_row: i32,
    pub region_type: u8,
    pub collapsed: u8, // 0 = expanded, 1 = collapsed
    pub line_count: u32,
    pub label: *mut c_char,
}

/// C-compatible region summary for the side panel.
#[repr(C)]
pub struct CRegionSummary {
    pub tool_use_count: u32,
    pub code_block_count: u32,
    pub thinking_count: u32,
    pub diff_count: u32,
    pub file_ref_count: u32,
}

/// Enable or disable AI output analysis for this surface.
#[no_mangle]
pub extern "C" fn at_surface_set_ai_analysis(surface: *mut ATSurface, enabled: bool) {
    let surface = mut_ref_or!(surface);
    surface.analyzer.set_enabled(enabled);
}

/// Check if AI analysis is enabled.
#[no_mangle]
pub extern "C" fn at_surface_get_ai_analysis(surface: *const ATSurface) -> bool {
    let surface = ref_or!(surface, false);
    surface.analyzer.is_enabled()
}

/// Get the number of detected regions.
#[no_mangle]
pub extern "C" fn at_surface_get_region_count(surface: *const ATSurface) -> u32 {
    let surface = ref_or!(surface, 0);
    surface.analyzer.region_count() as u32
}

/// Read detected regions into the provided buffer.
/// Buffer must have space for at least `max_regions` COutputRegion entries.
/// Returns the number of regions written.
/// Caller must free each label with `at_free_string`.
#[no_mangle]
pub extern "C" fn at_surface_get_regions(
    surface: *const ATSurface,
    out: *mut COutputRegion,
    max_regions: u32,
) -> u32 {
    let surface = ref_or!(surface, 0);
    if out.is_null() {
        return 0;
    }
    let regions = surface.analyzer.regions();
    let count = regions.len().min(max_regions as usize);
    let out_slice = unsafe { slice::from_raw_parts_mut(out, count) };

    for (i, region) in regions.iter().take(count).enumerate() {
        let label_ptr = match CString::new(region.label.clone()) {
            Ok(cs) => cs.into_raw(),
            Err(_) => std::ptr::null_mut(),
        };
        out_slice[i] = COutputRegion {
            start_row: region.start_row as i32,
            end_row: region.end_row as i32,
            region_type: region.region_type as u8,
            collapsed: if region.collapsed { 1 } else { 0 },
            line_count: region.line_count as u32,
            label: label_ptr,
        };
    }
    count as u32
}

/// Toggle fold/collapse state for the region containing the given row.
/// Returns true if a region was found and toggled.
#[no_mangle]
pub extern "C" fn at_surface_toggle_fold(surface: *mut ATSurface, row: i32) -> bool {
    let surface = mut_ref_or!(surface, false);
    let toggled = surface.analyzer.toggle_fold(row as i64);
    if toggled {
        surface.screen.dirty = true;
    }
    toggled
}

/// Get a summary of detected regions (counts by type).
#[no_mangle]
pub extern "C" fn at_surface_get_region_summary(
    surface: *const ATSurface,
    out: *mut CRegionSummary,
) {
    let surface = ref_or!(surface);
    if out.is_null() {
        return;
    }
    let summary = surface.analyzer.region_summary();
    unsafe {
        (*out).tool_use_count = summary.tool_use_count as u32;
        (*out).code_block_count = summary.code_block_count as u32;
        (*out).thinking_count = summary.thinking_count as u32;
        (*out).diff_count = summary.diff_count as u32;
        (*out).file_ref_count = summary.file_refs.len() as u32;
    }
}

/// Get a file reference by index from the region summary.
/// Returns a C string that must be freed with `at_free_string`.
#[no_mangle]
pub extern "C" fn at_surface_get_file_ref(surface: *const ATSurface, index: u32) -> *mut c_char {
    let surface = ref_or!(surface, std::ptr::null_mut());
    let summary = surface.analyzer.region_summary();
    let idx = index as usize;
    if idx >= summary.file_refs.len() {
        return std::ptr::null_mut();
    }
    match CString::new(summary.file_refs[idx].clone()) {
        Ok(cs) => cs.into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Manually trigger AI analysis (e.g. after scrollback changes without PTY activity).
#[no_mangle]
pub extern "C" fn at_surface_analyze(surface: *mut ATSurface) {
    let surface = mut_ref_or!(surface);
    if surface.analyzer.is_enabled() {
        let grid = surface.screen.active_grid();
        surface
            .analyzer
            .analyze(&surface.screen.scrollback, &grid.cells, grid.rows);
    }
}
