/// A single cell in the terminal grid.
/// Hyperlinks are stored separately in a sparse HashMap on Grid/Screen
/// to avoid the 24-byte Option<String> overhead on every cell.
#[derive(Clone, Debug)]
pub struct Cell {
    pub ch: char,
    pub fg: Color,
    pub bg: Color,
    pub attrs: CellAttrs,
}

impl Default for Cell {
    fn default() -> Self {
        Self {
            ch: ' ',
            fg: Color::Default,
            bg: Color::Default,
            attrs: CellAttrs::empty(),
        }
    }
}

impl Cell {
    pub fn reset(&mut self) {
        self.ch = ' ';
        self.fg = Color::Default;
        self.bg = Color::Default;
        self.attrs = CellAttrs::empty();
    }
}

bitflags::bitflags! {
    #[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
    pub struct CellAttrs: u16 {
        const BOLD       = 0b0000_0001;
        const DIM        = 0b0000_0010;
        const ITALIC     = 0b0000_0100;
        const UNDERLINE  = 0b0000_1000;
        const BLINK      = 0b0001_0000;
        const INVERSE    = 0b0010_0000;
        const HIDDEN     = 0b0100_0000;
        const STRIKETHROUGH = 0b1000_0000;
        const WIDE          = 0b1_0000_0000;
        const WIDE_SPACER   = 0b10_0000_0000;
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Color {
    Default,
    Indexed(u8),
    Rgb(u8, u8, u8),
}

/// C-compatible cell for FFI transfer.
#[derive(Clone, Copy, Debug)]
#[repr(C)]
pub struct CCell {
    pub codepoint: u32,
    pub fg_r: u8,
    pub fg_g: u8,
    pub fg_b: u8,
    pub fg_a: u8,
    pub bg_r: u8,
    pub bg_g: u8,
    pub bg_b: u8,
    pub bg_a: u8,
    pub attrs: u16,
}

/// Default 256-color palette.
pub fn default_palette() -> [Color; 256] {
    let mut palette = [Color::Default; 256];

    // Standard 16 colors (approximate xterm defaults)
    let base16: [(u8, u8, u8); 16] = [
        (0, 0, 0),       // 0  Black
        (205, 0, 0),     // 1  Red
        (0, 205, 0),     // 2  Green
        (205, 205, 0),   // 3  Yellow
        (0, 0, 238),     // 4  Blue
        (205, 0, 205),   // 5  Magenta
        (0, 205, 205),   // 6  Cyan
        (229, 229, 229), // 7  White
        (127, 127, 127), // 8  Bright Black
        (255, 0, 0),     // 9  Bright Red
        (0, 255, 0),     // 10 Bright Green
        (255, 255, 0),   // 11 Bright Yellow
        (92, 92, 255),   // 12 Bright Blue
        (255, 0, 255),   // 13 Bright Magenta
        (0, 255, 255),   // 14 Bright Cyan
        (255, 255, 255), // 15 Bright White
    ];
    for (i, (r, g, b)) in base16.iter().enumerate() {
        palette[i] = Color::Rgb(*r, *g, *b);
    }

    // 216 color cube (indices 16..231)
    for i in 0..216u8 {
        let r = (i / 36) % 6;
        let g = (i / 6) % 6;
        let b = i % 6;
        let to_val = |v: u8| if v == 0 { 0u8 } else { 55 + 40 * v };
        palette[16 + i as usize] = Color::Rgb(to_val(r), to_val(g), to_val(b));
    }

    // Grayscale ramp (indices 232..255)
    for i in 0..24u8 {
        let v = 8 + 10 * i;
        palette[232 + i as usize] = Color::Rgb(v, v, v);
    }

    palette
}

impl Color {
    /// Resolve to RGB, using the palette for indexed colors.
    pub fn to_rgb(&self, palette: &[Color; 256]) -> (u8, u8, u8) {
        match self {
            Color::Default => (229, 229, 229), // default fg
            Color::Indexed(i) => {
                if let Color::Rgb(r, g, b) = palette[*i as usize] {
                    (r, g, b)
                } else {
                    (229, 229, 229)
                }
            }
            Color::Rgb(r, g, b) => (*r, *g, *b),
        }
    }

    pub fn default_bg_rgb() -> (u8, u8, u8) {
        (30, 30, 30)
    }

    /// Resolve to RGB, using the provided default for Color::Default instead of the hardcoded value.
    pub fn to_rgb_with_default(
        &self,
        palette: &[Color; 256],
        default: (u8, u8, u8),
    ) -> (u8, u8, u8) {
        match self {
            Color::Default => default,
            other => other.to_rgb(palette),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // --- Cell tests ---

    #[test]
    fn cell_default_is_space_with_default_colors() {
        let cell = Cell::default();
        assert_eq!(cell.ch, ' ');
        assert_eq!(cell.fg, Color::Default);
        assert_eq!(cell.bg, Color::Default);
        assert_eq!(cell.attrs, CellAttrs::empty());
    }

    #[test]
    fn cell_reset_restores_defaults() {
        let mut cell = Cell {
            ch: 'X',
            fg: Color::Rgb(255, 0, 0),
            bg: Color::Indexed(42),
            attrs: CellAttrs::BOLD | CellAttrs::ITALIC,
        };
        cell.reset();
        assert_eq!(cell.ch, ' ');
        assert_eq!(cell.fg, Color::Default);
        assert_eq!(cell.bg, Color::Default);
        assert_eq!(cell.attrs, CellAttrs::empty());
    }

    #[test]
    fn cell_clone_is_independent() {
        let original = Cell {
            ch: 'A',
            fg: Color::Rgb(1, 2, 3),
            bg: Color::Indexed(7),
            attrs: CellAttrs::UNDERLINE,
        };
        let cloned = {
            let mut c = original.clone();
            c.ch = 'B';
            c.fg = Color::Default;
            c
        };
        assert_eq!(cloned.ch, 'B');
        assert_eq!(cloned.fg, Color::Default);
        assert_eq!(original.ch, 'A');
        assert_eq!(original.fg, Color::Rgb(1, 2, 3));
    }

    // --- CellAttrs tests ---

    #[test]
    fn cell_attrs_empty_has_no_flags() {
        let attrs = CellAttrs::empty();
        assert!(!attrs.contains(CellAttrs::BOLD));
        assert!(!attrs.contains(CellAttrs::WIDE));
        assert!(attrs.is_empty());
    }

    #[test]
    fn cell_attrs_combine_flags() {
        let attrs = CellAttrs::BOLD | CellAttrs::ITALIC | CellAttrs::STRIKETHROUGH;
        assert!(attrs.contains(CellAttrs::BOLD));
        assert!(attrs.contains(CellAttrs::ITALIC));
        assert!(attrs.contains(CellAttrs::STRIKETHROUGH));
        assert!(!attrs.contains(CellAttrs::DIM));
        assert!(!attrs.contains(CellAttrs::UNDERLINE));
    }

    #[test]
    fn cell_attrs_remove_flag() {
        let mut attrs = CellAttrs::BOLD | CellAttrs::DIM;
        attrs.remove(CellAttrs::BOLD);
        assert!(!attrs.contains(CellAttrs::BOLD));
        assert!(attrs.contains(CellAttrs::DIM));
    }

    #[test]
    fn cell_attrs_wide_flags_are_distinct() {
        let wide = CellAttrs::WIDE;
        let spacer = CellAttrs::WIDE_SPACER;
        assert!(!wide.contains(CellAttrs::WIDE_SPACER));
        assert!(!spacer.contains(CellAttrs::WIDE));
    }

    // --- Color tests ---

    #[test]
    fn color_default_to_rgb() {
        let palette = default_palette();
        assert_eq!(Color::Default.to_rgb(&palette), (229, 229, 229));
    }

    #[test]
    fn color_rgb_to_rgb_passthrough() {
        let palette = default_palette();
        assert_eq!(Color::Rgb(10, 20, 30).to_rgb(&palette), (10, 20, 30));
    }

    #[test]
    fn color_indexed_resolves_via_palette() {
        let palette = default_palette();
        // Index 0 is black (0,0,0)
        assert_eq!(Color::Indexed(0).to_rgb(&palette), (0, 0, 0));
        // Index 9 is bright red (255,0,0)
        assert_eq!(Color::Indexed(9).to_rgb(&palette), (255, 0, 0));
    }

    #[test]
    fn color_to_rgb_with_default_uses_custom_default() {
        let palette = default_palette();
        let custom = (100, 100, 100);
        assert_eq!(Color::Default.to_rgb_with_default(&palette, custom), custom);
        // Non-default colors should ignore the custom default
        assert_eq!(
            Color::Rgb(1, 2, 3).to_rgb_with_default(&palette, custom),
            (1, 2, 3)
        );
    }

    #[test]
    fn color_default_bg_rgb() {
        assert_eq!(Color::default_bg_rgb(), (30, 30, 30));
    }

    // --- Palette tests ---

    #[test]
    fn default_palette_has_256_entries() {
        let palette = default_palette();
        assert_eq!(palette.len(), 256);
    }

    #[test]
    fn default_palette_base16_are_rgb() {
        let palette = default_palette();
        for i in 0..16 {
            assert!(
                matches!(palette[i], Color::Rgb(_, _, _)),
                "palette[{}] should be Rgb",
                i
            );
        }
    }

    #[test]
    fn default_palette_grayscale_ramp() {
        let palette = default_palette();
        // First grayscale entry (232) should be Rgb(8,8,8)
        assert_eq!(palette[232], Color::Rgb(8, 8, 8));
        // Last grayscale entry (255) should be Rgb(238,238,238)
        assert_eq!(palette[255], Color::Rgb(238, 238, 238));
    }
}
