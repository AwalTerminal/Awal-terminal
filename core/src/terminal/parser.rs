use crate::terminal::cell::{CellAttrs, Color};
use crate::terminal::screen::Screen;

/// Terminal VT parser — wraps the `vte` crate and applies actions to the Screen.
pub struct Parser {
    vt: vte::Parser,
}

impl Default for Parser {
    fn default() -> Self {
        Self::new()
    }
}

impl Parser {
    pub fn new() -> Self {
        Self {
            vt: vte::Parser::new(),
        }
    }

    /// Feed bytes from PTY output into the parser, applying escape sequences to the screen.
    /// Returns any response bytes that should be written back to the PTY (e.g. DSR replies).
    pub fn process(&mut self, bytes: &[u8], screen: &mut Screen) -> Vec<Vec<u8>> {
        let mut performer = ScreenPerformer {
            screen,
            responses: Vec::new(),
        };
        self.vt.advance(&mut performer, bytes);
        performer.responses
    }
}

struct ScreenPerformer<'a> {
    screen: &'a mut Screen,
    responses: Vec<Vec<u8>>,
}

impl<'a> vte::Perform for ScreenPerformer<'a> {
    fn print(&mut self, c: char) {
        self.screen.write_char(c);
    }

    fn execute(&mut self, byte: u8) {
        match byte {
            0x08 => self.screen.backspace(),       // BS
            0x09 => self.screen.tab(),             // HT
            0x0A..=0x0C => self.screen.newline(),  // LF, VT, FF
            0x0D => self.screen.carriage_return(), // CR
            0x07 => {}                             // BEL — ignore for now
            _ => {}
        }
    }

    fn hook(&mut self, _params: &vte::Params, _intermediates: &[u8], _ignore: bool, _action: char) {
    }
    fn put(&mut self, _byte: u8) {}
    fn unhook(&mut self) {}

    fn osc_dispatch(&mut self, params: &[&[u8]], _bell_terminated: bool) {
        if params.is_empty() {
            return;
        }
        let cmd = std::str::from_utf8(params[0]).unwrap_or("");
        match cmd {
            "0" | "2" => {
                // Set window title
                if params.len() > 1 {
                    if let Ok(title) = std::str::from_utf8(params[1]) {
                        self.screen.title = title.to_string();
                        self.screen.dirty = true;
                    }
                }
            }
            "1" => {
                // Set icon name (treat as title)
                if params.len() > 1 {
                    if let Ok(title) = std::str::from_utf8(params[1]) {
                        self.screen.title = title.to_string();
                        self.screen.dirty = true;
                    }
                }
            }
            "7" => {
                // Current working directory
                if params.len() > 1 {
                    if let Ok(uri) = std::str::from_utf8(params[1]) {
                        // OSC 7 sends file://hostname/path
                        let path = if let Some(stripped) = uri.strip_prefix("file://") {
                            // Remove hostname part
                            if let Some(slash_pos) = stripped.find('/') {
                                &stripped[slash_pos..]
                            } else {
                                stripped
                            }
                        } else {
                            uri
                        };
                        self.screen.working_directory = path.to_string();
                    }
                }
            }
            "8" => {
                // OSC 8: Hyperlinks — ESC ] 8 ; params ; URI ST
                // params[1] = params (id=xxx etc), params[2] = URI
                // Empty URI closes the hyperlink
                if params.len() >= 3 {
                    if let Ok(uri) = std::str::from_utf8(params[2]) {
                        if uri.is_empty() {
                            self.screen.current_hyperlink = None;
                        } else {
                            self.screen.current_hyperlink = Some(uri.to_string());
                        }
                    }
                } else if params.len() == 2 {
                    // Close hyperlink (no URI param means empty)
                    self.screen.current_hyperlink = None;
                }
            }
            "52" => {
                // Clipboard — we'll store but not act on it from Rust side
                // The Swift side should handle clipboard via pasteboard
            }
            _ => {}
        }
    }

    fn csi_dispatch(
        &mut self,
        params: &vte::Params,
        intermediates: &[u8],
        _ignore: bool,
        action: char,
    ) {
        // For SGR, pass raw params to preserve sub-parameters (colon-separated values).
        // For everything else, flatten to first sub-param per group (legacy behavior).
        if action == 'm' {
            self.handle_sgr_raw(params);
            return;
        }

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
                self.screen.cursor.row = (self.screen.cursor.row + n).min(self.screen.rows - 1);
            }
            'C' => {
                let n = params.first().copied().unwrap_or(1).max(1) as usize;
                self.screen.cursor.col = (self.screen.cursor.col + n).min(self.screen.cols - 1);
            }
            'D' => {
                let n = params.first().copied().unwrap_or(1).max(1) as usize;
                self.screen.cursor.col = self.screen.cursor.col.saturating_sub(n);
            }
            'E' => {
                let n = params.first().copied().unwrap_or(1).max(1) as usize;
                self.screen.cursor.row = (self.screen.cursor.row + n).min(self.screen.rows - 1);
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
                for _ in 0..n {
                    self.screen.do_scroll_up();
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
                if intermediates.contains(&b'>') {
                    // CSI > flags u — Push kitty keyboard flags (cap stack depth)
                    let flags = params.first().copied().unwrap_or(0) as u32;
                    if self.screen.modes.kitty_keyboard_stack.len() < 64 {
                        self.screen.modes.kitty_keyboard_stack.push(flags);
                    }
                } else if intermediates.contains(&b'<') {
                    // CSI < count u — Pop kitty keyboard flags
                    let count = params.first().copied().unwrap_or(1).max(1) as usize;
                    let stack = &mut self.screen.modes.kitty_keyboard_stack;
                    for _ in 0..count.min(stack.len()) {
                        stack.pop();
                    }
                } else if intermediates.contains(&b'?') {
                    // CSI ? u — Query kitty keyboard flags
                    let flags = self.screen.modes.kitty_keyboard_flags();
                    self.responses
                        .push(format!("\x1b[?{}u", flags).into_bytes());
                } else {
                    self.screen.restore_cursor();
                }
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
            'n' => {
                // DSR — Device Status Report
                let param = params.first().copied().unwrap_or(0);
                match param {
                    5 => {
                        // Device status — report OK
                        self.responses.push(b"\x1b[0n".to_vec());
                    }
                    6 => {
                        // Cursor position report (1-indexed)
                        let r = self.screen.cursor.row + 1;
                        let c = self.screen.cursor.col + 1;
                        self.responses
                            .push(format!("\x1b[{};{}R", r, c).into_bytes());
                    }
                    _ => {}
                }
            }
            'c' => {
                if !private {
                    // DA1 — Primary Device Attributes
                    // Report as VT220 with ANSI color
                    self.responses.push(b"\x1b[?62;22c".to_vec());
                }
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
    /// Handle SGR (Select Graphic Rendition) with full sub-parameter support.
    /// vte::Params yields one `&[u16]` slice per semicolon-separated group.
    /// Within each slice, colon-separated sub-parameters are individual elements.
    /// E.g. `\e[4:3m` → one group `[4, 3]`, `\e[38;2;255;0;0m` → groups `[38]`, `[2]`, `[255]`, `[0]`, `[0]`.
    fn handle_sgr_raw(&mut self, params: &vte::Params) {
        let groups: Vec<&[u16]> = params.iter().collect();
        if groups.is_empty() {
            self.screen.cursor.attrs = CellAttrs::empty();
            self.screen.cursor.fg = Color::Default;
            self.screen.cursor.bg = Color::Default;
            return;
        }

        let mut i = 0;
        while i < groups.len() {
            let sub = groups[i];
            match sub[0] {
                0 => {
                    self.screen.cursor.attrs = CellAttrs::empty();
                    self.screen.cursor.fg = Color::Default;
                    self.screen.cursor.bg = Color::Default;
                }
                1 => self.screen.cursor.attrs |= CellAttrs::BOLD,
                2 => self.screen.cursor.attrs |= CellAttrs::DIM,
                3 => self.screen.cursor.attrs |= CellAttrs::ITALIC,
                4 => {
                    // 4 = underline, 4:0 = clear, 4:1-5 = set underline style
                    if sub.len() > 1 {
                        if sub[1] == 0 {
                            self.screen.cursor.attrs &= !CellAttrs::UNDERLINE;
                        } else {
                            self.screen.cursor.attrs |= CellAttrs::UNDERLINE;
                        }
                    } else {
                        self.screen.cursor.attrs |= CellAttrs::UNDERLINE;
                    }
                }
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
                    self.screen.cursor.fg = Color::Indexed((sub[0] - 30) as u8);
                }
                38 => {
                    if sub.len() >= 5 && sub[1] == 2 {
                        // Colon form: 38:2:R:G:B or 38:2::R:G:B
                        // With optional color-space id: sub may be [38,2,cs,R,G,B] or [38,2,R,G,B]
                        let (r, g, b) = if sub.len() >= 6 {
                            (sub[3] as u8, sub[4] as u8, sub[5] as u8)
                        } else {
                            (sub[2] as u8, sub[3] as u8, sub[4] as u8)
                        };
                        self.screen.cursor.fg = Color::Rgb(r, g, b);
                    } else if sub.len() >= 3 && sub[1] == 5 {
                        // Colon form: 38:5:N
                        self.screen.cursor.fg = Color::Indexed(sub[2] as u8);
                    } else if i + 1 < groups.len() {
                        // Semicolon form: 38;2;R;G;B or 38;5;N
                        match groups[i + 1][0] {
                            5 => {
                                if i + 2 < groups.len() {
                                    self.screen.cursor.fg = Color::Indexed(groups[i + 2][0] as u8);
                                    i += 2;
                                }
                            }
                            2 => {
                                if i + 4 < groups.len() {
                                    self.screen.cursor.fg = Color::Rgb(
                                        groups[i + 2][0] as u8,
                                        groups[i + 3][0] as u8,
                                        groups[i + 4][0] as u8,
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
                    self.screen.cursor.bg = Color::Indexed((sub[0] - 40) as u8);
                }
                48 => {
                    if sub.len() >= 5 && sub[1] == 2 {
                        // Colon form: 48:2:R:G:B or 48:2::R:G:B
                        let (r, g, b) = if sub.len() >= 6 {
                            (sub[3] as u8, sub[4] as u8, sub[5] as u8)
                        } else {
                            (sub[2] as u8, sub[3] as u8, sub[4] as u8)
                        };
                        self.screen.cursor.bg = Color::Rgb(r, g, b);
                    } else if sub.len() >= 3 && sub[1] == 5 {
                        // Colon form: 48:5:N
                        self.screen.cursor.bg = Color::Indexed(sub[2] as u8);
                    } else if i + 1 < groups.len() {
                        // Semicolon form: 48;2;R;G;B or 48;5;N
                        match groups[i + 1][0] {
                            5 => {
                                if i + 2 < groups.len() {
                                    self.screen.cursor.bg = Color::Indexed(groups[i + 2][0] as u8);
                                    i += 2;
                                }
                            }
                            2 => {
                                if i + 4 < groups.len() {
                                    self.screen.cursor.bg = Color::Rgb(
                                        groups[i + 2][0] as u8,
                                        groups[i + 3][0] as u8,
                                        groups[i + 4][0] as u8,
                                    );
                                    i += 4;
                                }
                            }
                            _ => {}
                        }
                    }
                }
                49 => self.screen.cursor.bg = Color::Default,
                58 => {
                    // Underline color — skip sub-parameters, don't break
                }
                59 => {
                    // Reset underline color — ignore
                }
                90..=97 => {
                    self.screen.cursor.fg = Color::Indexed((sub[0] - 90 + 8) as u8);
                }
                100..=107 => {
                    self.screen.cursor.bg = Color::Indexed((sub[0] - 100 + 8) as u8);
                }
                _ => {}
            }
            i += 1;
        }
    }

    fn handle_dec_set(&mut self, params: &[u16]) {
        use crate::terminal::modes::MouseMode;
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
                9 => self.screen.modes.mouse_tracking = MouseMode::X10,
                1000 => self.screen.modes.mouse_tracking = MouseMode::Normal,
                1002 => self.screen.modes.mouse_tracking = MouseMode::Button,
                1003 => self.screen.modes.mouse_tracking = MouseMode::Any,
                1006 => self.screen.modes.sgr_mouse = true,
                2004 => self.screen.modes.bracketed_paste = true,
                2026 => self.screen.modes.synchronized_output = true,
                _ => {}
            }
        }
    }

    fn handle_dec_reset(&mut self, params: &[u16]) {
        use crate::terminal::modes::MouseMode;
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
                9 | 1000 | 1002 | 1003 => self.screen.modes.mouse_tracking = MouseMode::None,
                1006 => self.screen.modes.sgr_mouse = false,
                2004 => self.screen.modes.bracketed_paste = false,
                2026 => {
                    self.screen.modes.synchronized_output = false;
                    self.screen.dirty = true;
                }
                _ => {}
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::terminal::cell::CellAttrs;
    use crate::terminal::screen::Screen;

    /// Helper: feed an escape sequence into a fresh parser+screen and return the screen.
    fn feed(seq: &[u8]) -> Screen {
        let mut parser = Parser::new();
        let mut screen = Screen::new(80, 24);
        parser.process(seq, &mut screen);
        screen
    }

    #[test]
    fn test_plain_underline_on_off() {
        // ESC[4m sets underline, ESC[24m clears it
        let screen = feed(b"\x1b[4m");
        assert!(screen.cursor.attrs.contains(CellAttrs::UNDERLINE));

        let screen = feed(b"\x1b[4m\x1b[24m");
        assert!(!screen.cursor.attrs.contains(CellAttrs::UNDERLINE));
    }

    #[test]
    fn test_underline_subparam_clear() {
        // ESC[4:0m should clear underline (the bug this fix addresses)
        let screen = feed(b"\x1b[4m\x1b[4:0m");
        assert!(
            !screen.cursor.attrs.contains(CellAttrs::UNDERLINE),
            "4:0 must clear underline"
        );
    }

    #[test]
    fn test_underline_subparam_styles() {
        // 4:1 through 4:5 should all set underline
        for style in 1..=5 {
            let seq = format!("\x1b[4:{}m", style);
            let screen = feed(seq.as_bytes());
            assert!(
                screen.cursor.attrs.contains(CellAttrs::UNDERLINE),
                "4:{} must set underline",
                style
            );
        }
    }

    #[test]
    fn test_sgr_reset_clears_all() {
        let screen = feed(b"\x1b[1;3;4m\x1b[0m");
        assert_eq!(screen.cursor.attrs, CellAttrs::empty());
        assert!(matches!(screen.cursor.fg, Color::Default));
        assert!(matches!(screen.cursor.bg, Color::Default));
    }

    #[test]
    fn test_semicolon_fg_rgb() {
        // ESC[38;2;100;150;200m — semicolon-separated RGB foreground
        let screen = feed(b"\x1b[38;2;100;150;200m");
        assert_eq!(screen.cursor.fg, Color::Rgb(100, 150, 200));
    }

    #[test]
    fn test_colon_fg_rgb() {
        // ESC[38:2:100:150:200m — colon-separated RGB foreground
        let screen = feed(b"\x1b[38:2:100:150:200m");
        assert_eq!(screen.cursor.fg, Color::Rgb(100, 150, 200));
    }

    #[test]
    fn test_colon_bg_rgb() {
        // ESC[48:2:50:60:70m — colon-separated RGB background
        let screen = feed(b"\x1b[48:2:50:60:70m");
        assert_eq!(screen.cursor.bg, Color::Rgb(50, 60, 70));
    }

    #[test]
    fn test_underline_color_does_not_crash() {
        // ESC[58:2:255:0:0m — underline color, should be silently ignored
        let screen = feed(b"\x1b[58:2:255:0:0m");
        assert_eq!(screen.cursor.attrs, CellAttrs::empty());
    }
}
