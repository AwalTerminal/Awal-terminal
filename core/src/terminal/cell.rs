/// A single cell in the terminal grid.
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
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Color {
    Default,
    Indexed(u8),
    Rgb(u8, u8, u8),
}

/// C-compatible cell for FFI transfer.
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
}
