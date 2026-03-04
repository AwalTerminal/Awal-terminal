use crate::terminal::cell::{CellAttrs, Color};
use crate::terminal::screen::Screen;

/// Terminal VT parser — wraps the `vte` crate and applies actions to the Screen.
pub struct Parser {
    vt: vte::Parser,
}

impl Parser {
    pub fn new() -> Self {
        Self {
            vt: vte::Parser::new(),
        }
    }

    /// Feed bytes from PTY output into the parser, applying escape sequences to the screen.
    pub fn process(&mut self, bytes: &[u8], screen: &mut Screen) {
        let mut performer = ScreenPerformer { screen };
        self.vt.advance(&mut performer, bytes);
    }
}

struct ScreenPerformer<'a> {
    screen: &'a mut Screen,
}

impl<'a> vte::Perform for ScreenPerformer<'a> {
    fn print(&mut self, c: char) {
        self.screen.write_char(c);
    }

    fn execute(&mut self, byte: u8) {
        match byte {
            0x08 => self.screen.backspace(),            // BS
            0x09 => self.screen.tab(),                   // HT
            0x0A | 0x0B | 0x0C => self.screen.newline(), // LF, VT, FF
            0x0D => self.screen.carriage_return(),       // CR
            0x07 => {}                                    // BEL — ignore for now
            _ => {}
        }
    }

    fn hook(&mut self, _params: &vte::Params, _intermediates: &[u8], _ignore: bool, _action: char) {
    }
    fn put(&mut self, _byte: u8) {}
    fn unhook(&mut self) {}

    fn osc_dispatch(&mut self, _params: &[&[u8]], _bell_terminated: bool) {
        // TODO: handle OSC sequences (window title, etc.)
    }

    fn csi_dispatch(
        &mut self,
        params: &vte::Params,
        intermediates: &[u8],
        _ignore: bool,
        action: char,
    ) {
        let params: Vec<u16> = params.iter().map(|p| p[0]).collect();
        let private = intermediates.contains(&b'?');

        match action {
            // Cursor movement
            'A' => {
                let n = params.first().copied().unwrap_or(1).max(1) as usize;
                self.screen.cursor.row = self.screen.cursor.row.saturating_sub(n);
            }
            'B' => {
                let n = params.first().copied().unwrap_or(1).max(1) as usize;
                self.screen.cursor.row =
                    (self.screen.cursor.row + n).min(self.screen.rows - 1);
            }
            'C' => {
                let n = params.first().copied().unwrap_or(1).max(1) as usize;
                self.screen.cursor.col =
                    (self.screen.cursor.col + n).min(self.screen.cols - 1);
            }
            'D' => {
                let n = params.first().copied().unwrap_or(1).max(1) as usize;
                self.screen.cursor.col = self.screen.cursor.col.saturating_sub(n);
            }
            'E' => {
                let n = params.first().copied().unwrap_or(1).max(1) as usize;
                self.screen.cursor.row =
                    (self.screen.cursor.row + n).min(self.screen.rows - 1);
                self.screen.cursor.col = 0;
            }
            'F' => {
                let n = params.first().copied().unwrap_or(1).max(1) as usize;
                self.screen.cursor.row = self.screen.cursor.row.saturating_sub(n);
                self.screen.cursor.col = 0;
            }
            'G' => {
                let col = params.first().copied().unwrap_or(1).max(1) as usize;
                self.screen.cursor.col = (col - 1).min(self.screen.cols - 1);
            }
            'H' | 'f' => {
                let row = params.first().copied().unwrap_or(1).max(1) as usize;
                let col = params.get(1).copied().unwrap_or(1).max(1) as usize;
                self.screen.set_cursor_pos(row - 1, col - 1);
            }
            'J' => {
                let mode = params.first().copied().unwrap_or(0);
                self.screen.erase_in_display(mode);
            }
            'K' => {
                let mode = params.first().copied().unwrap_or(0);
                self.screen.erase_in_line(mode);
            }
            'L' => {
                let n = params.first().copied().unwrap_or(1).max(1) as usize;
                self.screen.insert_lines(n);
            }
            'M' => {
                let n = params.first().copied().unwrap_or(1).max(1) as usize;
                self.screen.delete_lines(n);
            }
            'P' => {
                let n = params.first().copied().unwrap_or(1).max(1) as usize;
                self.screen.delete_chars(n);
            }
            'X' => {
                let n = params.first().copied().unwrap_or(1).max(1) as usize;
                self.screen.erase_chars(n);
            }
            'S' => {
                let n = params.first().copied().unwrap_or(1).max(1) as usize;
                let top = self.screen.scroll_top;
                let bottom = self.screen.scroll_bottom;
                for _ in 0..n {
                    self.screen.active_grid_mut().scroll_up(top, bottom);
                }
                self.screen.dirty = true;
            }
            'T' => {
                let n = params.first().copied().unwrap_or(1).max(1) as usize;
                let top = self.screen.scroll_top;
                let bottom = self.screen.scroll_bottom;
                for _ in 0..n {
                    self.screen.active_grid_mut().scroll_down(top, bottom);
                }
                self.screen.dirty = true;
            }
            'd' => {
                let row = params.first().copied().unwrap_or(1).max(1) as usize;
                self.screen.cursor.row = (row - 1).min(self.screen.rows - 1);
            }
            'r' => {
                if !private {
                    let top = params.first().copied().unwrap_or(1).max(1) as usize;
                    let bottom = params
                        .get(1)
                        .copied()
                        .unwrap_or(self.screen.rows as u16)
                        .max(1) as usize;
                    self.screen.set_scroll_region(top - 1, bottom);
                    self.screen.set_cursor_pos(0, 0);
                }
            }
            's' => {
                self.screen.save_cursor();
            }
            'u' => {
                self.screen.restore_cursor();
            }
            'm' => {
                self.handle_sgr(&params);
            }
            'h' => {
                if private {
                    self.handle_dec_set(&params);
                }
            }
            'l' => {
                if private {
                    self.handle_dec_reset(&params);
                }
            }
            '@' => {
                let n = params.first().copied().unwrap_or(1).max(1) as usize;
                self.screen.insert_blanks(n);
            }
            _ => {}
        }
    }

    fn esc_dispatch(&mut self, _intermediates: &[u8], _ignore: bool, byte: u8) {
        match byte {
            b'7' => self.screen.save_cursor(),
            b'8' => self.screen.restore_cursor(),
            b'D' => self.screen.newline(),
            b'E' => {
                self.screen.carriage_return();
                self.screen.newline();
            }
            b'M' => {
                self.screen.reverse_index();
            }
            b'c' => {
                let cols = self.screen.cols;
                let rows = self.screen.rows;
                *self.screen = Screen::new(cols, rows);
            }
            _ => {}
        }
    }
}

impl<'a> ScreenPerformer<'a> {
    fn handle_sgr(&mut self, params: &[u16]) {
        if params.is_empty() {
            self.screen.cursor.attrs = CellAttrs::empty();
            self.screen.cursor.fg = Color::Default;
            self.screen.cursor.bg = Color::Default;
            return;
        }

        let mut i = 0;
        while i < params.len() {
            match params[i] {
                0 => {
                    self.screen.cursor.attrs = CellAttrs::empty();
                    self.screen.cursor.fg = Color::Default;
                    self.screen.cursor.bg = Color::Default;
                }
                1 => self.screen.cursor.attrs |= CellAttrs::BOLD,
                2 => self.screen.cursor.attrs |= CellAttrs::DIM,
                3 => self.screen.cursor.attrs |= CellAttrs::ITALIC,
                4 => self.screen.cursor.attrs |= CellAttrs::UNDERLINE,
                5 => self.screen.cursor.attrs |= CellAttrs::BLINK,
                7 => self.screen.cursor.attrs |= CellAttrs::INVERSE,
                8 => self.screen.cursor.attrs |= CellAttrs::HIDDEN,
                9 => self.screen.cursor.attrs |= CellAttrs::STRIKETHROUGH,
                22 => self.screen.cursor.attrs &= !(CellAttrs::BOLD | CellAttrs::DIM),
                23 => self.screen.cursor.attrs &= !CellAttrs::ITALIC,
                24 => self.screen.cursor.attrs &= !CellAttrs::UNDERLINE,
                25 => self.screen.cursor.attrs &= !CellAttrs::BLINK,
                27 => self.screen.cursor.attrs &= !CellAttrs::INVERSE,
                28 => self.screen.cursor.attrs &= !CellAttrs::HIDDEN,
                29 => self.screen.cursor.attrs &= !CellAttrs::STRIKETHROUGH,
                30..=37 => {
                    self.screen.cursor.fg = Color::Indexed((params[i] - 30) as u8);
                }
                38 => {
                    if i + 1 < params.len() {
                        match params[i + 1] {
                            5 => {
                                if i + 2 < params.len() {
                                    self.screen.cursor.fg =
                                        Color::Indexed(params[i + 2] as u8);
                                    i += 2;
                                }
                            }
                            2 => {
                                if i + 4 < params.len() {
                                    self.screen.cursor.fg = Color::Rgb(
                                        params[i + 2] as u8,
                                        params[i + 3] as u8,
                                        params[i + 4] as u8,
                                    );
                                    i += 4;
                                }
                            }
                            _ => {}
                        }
                    }
                }
                39 => self.screen.cursor.fg = Color::Default,
                40..=47 => {
                    self.screen.cursor.bg = Color::Indexed((params[i] - 40) as u8);
                }
                48 => {
                    if i + 1 < params.len() {
                        match params[i + 1] {
                            5 => {
                                if i + 2 < params.len() {
                                    self.screen.cursor.bg =
                                        Color::Indexed(params[i + 2] as u8);
                                    i += 2;
                                }
                            }
                            2 => {
                                if i + 4 < params.len() {
                                    self.screen.cursor.bg = Color::Rgb(
                                        params[i + 2] as u8,
                                        params[i + 3] as u8,
                                        params[i + 4] as u8,
                                    );
                                    i += 4;
                                }
                            }
                            _ => {}
                        }
                    }
                }
                49 => self.screen.cursor.bg = Color::Default,
                90..=97 => {
                    self.screen.cursor.fg = Color::Indexed((params[i] - 90 + 8) as u8);
                }
                100..=107 => {
                    self.screen.cursor.bg = Color::Indexed((params[i] - 100 + 8) as u8);
                }
                _ => {}
            }
            i += 1;
        }
    }

    fn handle_dec_set(&mut self, params: &[u16]) {
        for &p in params {
            match p {
                1 => self.screen.modes.cursor_keys_application = true,
                6 => self.screen.modes.origin_mode = true,
                7 => self.screen.modes.auto_wrap = true,
                25 => self.screen.modes.cursor_visible = true,
                47 | 1047 => self.screen.enter_alternate_screen(),
                1049 => {
                    self.screen.save_cursor();
                    self.screen.enter_alternate_screen();
                }
                2004 => self.screen.modes.bracketed_paste = true,
                _ => {}
            }
        }
    }

    fn handle_dec_reset(&mut self, params: &[u16]) {
        for &p in params {
            match p {
                1 => self.screen.modes.cursor_keys_application = false,
                6 => self.screen.modes.origin_mode = false,
                7 => self.screen.modes.auto_wrap = false,
                25 => self.screen.modes.cursor_visible = false,
                47 | 1047 => self.screen.exit_alternate_screen(),
                1049 => {
                    self.screen.exit_alternate_screen();
                    self.screen.restore_cursor();
                }
                2004 => self.screen.modes.bracketed_paste = false,
                _ => {}
            }
        }
    }
}
