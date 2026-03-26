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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_modes() {
        let m = TerminalModes::default();
        assert!(!m.cursor_keys_application);
        assert!(m.auto_wrap);
        assert!(m.cursor_visible);
        assert!(!m.alternate_screen);
        assert!(!m.bracketed_paste);
        assert_eq!(m.mouse_tracking, MouseMode::None);
        assert!(!m.sgr_mouse);
        assert!(!m.origin_mode);
        assert!(!m.insert_mode);
        assert!(!m.linefeed_mode);
        assert!(!m.synchronized_output);
        assert!(m.kitty_keyboard_stack.is_empty());
    }

    #[test]
    fn set_and_query_boolean_modes() {
        let mut m = TerminalModes::default();
        m.cursor_keys_application = true;
        assert!(m.cursor_keys_application);
        m.alternate_screen = true;
        assert!(m.alternate_screen);
        m.bracketed_paste = true;
        assert!(m.bracketed_paste);
        m.origin_mode = true;
        assert!(m.origin_mode);
        m.insert_mode = true;
        assert!(m.insert_mode);
        m.linefeed_mode = true;
        assert!(m.linefeed_mode);
        m.synchronized_output = true;
        assert!(m.synchronized_output);
    }

    #[test]
    fn clear_boolean_modes() {
        let mut m = TerminalModes::default();
        // auto_wrap and cursor_visible default to true; clear them
        m.auto_wrap = false;
        assert!(!m.auto_wrap);
        m.cursor_visible = false;
        assert!(!m.cursor_visible);
    }

    #[test]
    fn mouse_tracking_modes() {
        let mut m = TerminalModes::default();
        for mode in [
            MouseMode::X10,
            MouseMode::Normal,
            MouseMode::Button,
            MouseMode::Any,
            MouseMode::None,
        ] {
            m.mouse_tracking = mode;
            assert_eq!(m.mouse_tracking, mode);
        }
    }

    #[test]
    fn sgr_mouse_toggle() {
        let mut m = TerminalModes::default();
        assert!(!m.sgr_mouse);
        m.sgr_mouse = true;
        assert!(m.sgr_mouse);
        m.sgr_mouse = false;
        assert!(!m.sgr_mouse);
    }

    #[test]
    fn kitty_keyboard_flags_empty_returns_zero() {
        let m = TerminalModes::default();
        assert_eq!(m.kitty_keyboard_flags(), 0);
    }

    #[test]
    fn kitty_keyboard_push_and_query() {
        let mut m = TerminalModes::default();
        m.kitty_keyboard_stack.push(1);
        assert_eq!(m.kitty_keyboard_flags(), 1);
        m.kitty_keyboard_stack.push(7);
        assert_eq!(m.kitty_keyboard_flags(), 7);
    }

    #[test]
    fn kitty_keyboard_pop_restores_previous() {
        let mut m = TerminalModes::default();
        m.kitty_keyboard_stack.push(3);
        m.kitty_keyboard_stack.push(15);
        assert_eq!(m.kitty_keyboard_flags(), 15);
        m.kitty_keyboard_stack.pop();
        assert_eq!(m.kitty_keyboard_flags(), 3);
        m.kitty_keyboard_stack.pop();
        assert_eq!(m.kitty_keyboard_flags(), 0);
    }

    #[test]
    fn clone_is_independent() {
        let mut original = TerminalModes::default();
        original.bracketed_paste = true;
        original.kitty_keyboard_stack.push(42);
        let mut cloned = original.clone();
        cloned.bracketed_paste = false;
        cloned.kitty_keyboard_stack.push(99);
        assert!(original.bracketed_paste);
        assert_eq!(original.kitty_keyboard_flags(), 42);
    }
}
