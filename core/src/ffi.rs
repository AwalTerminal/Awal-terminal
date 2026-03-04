use crate::io::pty::Pty;
use crate::terminal::cell::{CCell, Color, default_palette};
use crate::terminal::parser::Parser;
use crate::terminal::screen::Screen;
use std::os::fd::RawFd;
use std::slice;

/// Opaque handle to a terminal surface.
pub struct CTSurface {
    screen: Screen,
    parser: Parser,
    pty: Option<Pty>,
    read_buf: Vec<u8>,
    palette: [Color; 256],
}

/// Create a new terminal surface with the given dimensions.
#[no_mangle]
pub extern "C" fn ct_surface_new(cols: u32, rows: u32) -> *mut CTSurface {
    let surface = Box::new(CTSurface {
        screen: Screen::new(cols as usize, rows as usize),
        parser: Parser::new(),
        pty: None,
        read_buf: vec![0u8; 65536],
        palette: default_palette(),
    });
    Box::into_raw(surface)
}

/// Destroy a terminal surface.
#[no_mangle]
pub extern "C" fn ct_surface_destroy(surface: *mut CTSurface) {
    if !surface.is_null() {
        unsafe {
            drop(Box::from_raw(surface));
        }
    }
}

/// Spawn a shell process. Returns 0 on success, -1 on failure.
#[no_mangle]
pub extern "C" fn ct_surface_spawn_shell(
    surface: *mut CTSurface,
    shell: *const libc::c_char,
) -> i32 {
    let surface = unsafe { &mut *surface };
    let shell_str = if shell.is_null() {
        "/bin/zsh"
    } else {
        unsafe { std::ffi::CStr::from_ptr(shell).to_str().unwrap_or("/bin/zsh") }
    };

    match Pty::spawn(shell_str, surface.screen.cols as u16, surface.screen.rows as u16, &[]) {
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

/// Get the PTY master file descriptor (for polling).
#[no_mangle]
pub extern "C" fn ct_surface_get_fd(surface: *const CTSurface) -> RawFd {
    let surface = unsafe { &*surface };
    surface.pty.as_ref().map_or(-1, |pty| pty.master_fd())
}

/// Read from the PTY and process VT sequences. Returns number of bytes read, 0 if nothing available, -1 on error.
#[no_mangle]
pub extern "C" fn ct_surface_process_pty(surface: *mut CTSurface) -> i32 {
    let surface = unsafe { &mut *surface };
    let pty = match &surface.pty {
        Some(p) => p,
        None => return -1,
    };

    match pty.read(&mut surface.read_buf) {
        Ok(n) if n > 0 => {
            let bytes = surface.read_buf[..n].to_vec();
            surface.parser.process(&bytes, &mut surface.screen);
            n as i32
        }
        Ok(_) => 0,
        Err(nix::Error::EAGAIN) => 0,
        Err(_) => -1,
    }
}

/// Send a key event (raw bytes) to the PTY.
#[no_mangle]
pub extern "C" fn ct_surface_key_event(
    surface: *mut CTSurface,
    data: *const u8,
    len: u32,
) -> i32 {
    let surface = unsafe { &mut *surface };
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

/// Get the screen dimensions.
#[no_mangle]
pub extern "C" fn ct_surface_get_size(
    surface: *const CTSurface,
    cols: *mut u32,
    rows: *mut u32,
) {
    let surface = unsafe { &*surface };
    unsafe {
        *cols = surface.screen.cols as u32;
        *rows = surface.screen.rows as u32;
    }
}

/// Resize the terminal surface.
#[no_mangle]
pub extern "C" fn ct_surface_resize(surface: *mut CTSurface, cols: u32, rows: u32) {
    let surface = unsafe { &mut *surface };
    surface.screen.resize(cols as usize, rows as usize);
    if let Some(pty) = &surface.pty {
        let _ = pty.resize(cols as u16, rows as u16);
    }
}

/// Read cells from the screen into the provided buffer.
/// Buffer must have space for (cols * rows) CCells.
/// Returns the number of cells written.
#[no_mangle]
pub extern "C" fn ct_surface_read_cells(
    surface: *const CTSurface,
    out: *mut CCell,
    max_cells: u32,
) -> u32 {
    let surface = unsafe { &*surface };
    let grid = surface.screen.active_grid();
    let total = grid.rows * grid.cols;
    let count = total.min(max_cells as usize);

    let out_slice = unsafe { slice::from_raw_parts_mut(out, count) };
    let palette = &surface.palette;

    let mut idx = 0;
    for row in 0..grid.rows {
        for col in 0..grid.cols {
            if idx >= count {
                return idx as u32;
            }
            let cell = grid.cell(row, col);
            let (fg_r, fg_g, fg_b) = cell.fg.to_rgb(palette);
            let (bg_r, bg_g, bg_b) = if cell.bg == Color::Default {
                Color::default_bg_rgb()
            } else {
                cell.bg.to_rgb(palette)
            };

            out_slice[idx] = CCell {
                codepoint: cell.ch as u32,
                fg_r,
                fg_g,
                fg_b,
                fg_a: 255,
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
pub extern "C" fn ct_surface_get_cursor(
    surface: *const CTSurface,
    row: *mut u32,
    col: *mut u32,
    visible: *mut bool,
) {
    let surface = unsafe { &*surface };
    unsafe {
        *row = surface.screen.cursor.row as u32;
        *col = surface.screen.cursor.col as u32;
        *visible = surface.screen.modes.cursor_visible;
    }
}

/// Check if screen content has changed since last check. Resets the dirty flag.
#[no_mangle]
pub extern "C" fn ct_surface_is_dirty(surface: *mut CTSurface) -> bool {
    let surface = unsafe { &mut *surface };
    let dirty = surface.screen.dirty;
    surface.screen.dirty = false;
    dirty
}

/// Initialize logging (call once at startup).
#[no_mangle]
pub extern "C" fn ct_init_logging() {
    let _ = env_logger::try_init();
}
