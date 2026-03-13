/// Terminal mode flags (DEC private modes + ANSI modes).
#[derive(Clone, Debug)]
pub struct TerminalModes {
    /// DECCKM — Cursor key mode (application vs normal)
    pub cursor_keys_application: bool,
    /// DECAWM — Auto-wrap mode
    pub auto_wrap: bool,
    /// DECTCEM — Text cursor enable
    pub cursor_visible: bool,
    /// Alternate screen buffer active
    pub alternate_screen: bool,
    /// Bracketed paste mode
    pub bracketed_paste: bool,
    /// Mouse tracking modes
    pub mouse_tracking: MouseMode,
    /// SGR mouse encoding (mode 1006)
    pub sgr_mouse: bool,
    /// Origin mode (DECOM)
    pub origin_mode: bool,
    /// Insert mode (IRM)
    pub insert_mode: bool,
    /// Line feed/new line mode (LNM)
    pub linefeed_mode: bool,
    /// Synchronized output mode (mode 2026)
    pub synchronized_output: bool,
    /// Kitty keyboard protocol flags stack.
    /// Apps push/pop flags via CSI > u / CSI < u.
    pub kitty_keyboard_stack: Vec<u32>,
}

impl TerminalModes {
    /// Current kitty keyboard flags (top of stack, or 0 if empty).
    pub fn kitty_keyboard_flags(&self) -> u32 {
        self.kitty_keyboard_stack.last().copied().unwrap_or(0)
    }
}

impl Default for TerminalModes {
    fn default() -> Self {
        Self {
            cursor_keys_application: false,
            auto_wrap: true,
            cursor_visible: true,
            alternate_screen: false,
            bracketed_paste: false,
            mouse_tracking: MouseMode::None,
            sgr_mouse: false,
            origin_mode: false,
            insert_mode: false,
            linefeed_mode: false,
            synchronized_output: false,
            kitty_keyboard_stack: Vec::new(),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MouseMode {
    None,
    X10,
    Normal,
    Button,
    Any,
}
