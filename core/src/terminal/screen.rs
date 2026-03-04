use crate::terminal::cell::{Cell, CellAttrs, Color};
use crate::terminal::modes::TerminalModes;
use unicode_width::UnicodeWidthChar;

#[derive(Clone, Debug)]
pub struct Cursor {
    pub row: usize,
    pub col: usize,
    pub attrs: CellAttrs,
    pub fg: Color,
    pub bg: Color,
}

impl Default for Cursor {
    fn default() -> Self {
        Self {
            row: 0,
            col: 0,
            attrs: CellAttrs::empty(),
            fg: Color::Default,
            bg: Color::Default,
        }
    }
}

#[derive(Clone)]
pub struct Grid {
    pub cols: usize,
    pub rows: usize,
    pub cells: Vec<Vec<Cell>>,
}

impl Grid {
    pub fn new(cols: usize, rows: usize) -> Self {
        let cells = (0..rows)
            .map(|_| (0..cols).map(|_| Cell::default()).collect())
            .collect();
        Self { cols, rows, cells }
    }

    pub fn cell(&self, row: usize, col: usize) -> &Cell {
        &self.cells[row][col]
    }

    pub fn cell_mut(&mut self, row: usize, col: usize) -> &mut Cell {
        &mut self.cells[row][col]
    }

    pub fn clear(&mut self) {
        for row in &mut self.cells {
            for cell in row {
                cell.reset();
            }
        }
    }

    pub fn scroll_up(&mut self, top: usize, bottom: usize) {
        if top + 1 >= bottom || bottom > self.rows {
            return;
        }
        self.cells.remove(top);
        let blank = (0..self.cols).map(|_| Cell::default()).collect();
        self.cells.insert(bottom - 1, blank);
    }

    pub fn scroll_down(&mut self, top: usize, bottom: usize) {
        if top + 1 >= bottom || bottom > self.rows {
            return;
        }
        self.cells.remove(bottom - 1);
        let blank = (0..self.cols).map(|_| Cell::default()).collect();
        self.cells.insert(top, blank);
    }

    pub fn resize(&mut self, new_cols: usize, new_rows: usize) {
        while self.cells.len() < new_rows {
            self.cells
                .push((0..new_cols).map(|_| Cell::default()).collect());
        }
        self.cells.truncate(new_rows);
        for row in &mut self.cells {
            row.resize(new_cols, Cell::default());
        }
        self.cols = new_cols;
        self.rows = new_rows;
    }
}

pub struct Screen {
    pub primary: Grid,
    pub alternate: Grid,
    pub cursor: Cursor,
    pub saved_cursor: Option<Cursor>,
    pub modes: TerminalModes,
    pub scroll_top: usize,
    pub scroll_bottom: usize,
    pub cols: usize,
    pub rows: usize,
    pub dirty: bool,
    pub tab_stops: Vec<bool>,
}

impl Screen {
    pub fn new(cols: usize, rows: usize) -> Self {
        let mut tab_stops = vec![false; cols];
        for i in (0..cols).step_by(8) {
            tab_stops[i] = true;
        }
        Self {
            primary: Grid::new(cols, rows),
            alternate: Grid::new(cols, rows),
            cursor: Cursor::default(),
            saved_cursor: None,
            modes: TerminalModes::default(),
            scroll_top: 0,
            scroll_bottom: rows,
            cols,
            rows,
            dirty: true,
            tab_stops,
        }
    }

    pub fn active_grid(&self) -> &Grid {
        if self.modes.alternate_screen {
            &self.alternate
        } else {
            &self.primary
        }
    }

    pub fn active_grid_mut(&mut self) -> &mut Grid {
        if self.modes.alternate_screen {
            &mut self.alternate
        } else {
            &mut self.primary
        }
    }

    pub fn write_char(&mut self, ch: char) {
        let width = ch.width().unwrap_or(1);
        if width == 0 {
            return; // skip zero-width characters for now
        }

        // If wide char won't fit on the line, wrap first
        if width == 2 && self.cursor.col == self.cols - 1 && self.modes.auto_wrap {
            // Fill current cell with space and wrap
            let row = self.cursor.row;
            let col = self.cursor.col;
            self.active_grid_mut().cell_mut(row, col).reset();
            self.cursor.col = self.cols; // trigger wrap below
        }

        if self.cursor.col >= self.cols {
            if self.modes.auto_wrap {
                self.cursor.col = 0;
                self.cursor.row += 1;
                if self.cursor.row >= self.scroll_bottom {
                    self.cursor.row = self.scroll_bottom - 1;
                    let top = self.scroll_top;
                    let bottom = self.scroll_bottom;
                    self.active_grid_mut().scroll_up(top, bottom);
                }
            } else {
                self.cursor.col = self.cols - 1;
            }
        }

        let row = self.cursor.row;
        let col = self.cursor.col;
        let fg = self.cursor.fg;
        let bg = self.cursor.bg;
        let mut attrs = self.cursor.attrs;

        if width == 2 {
            attrs.insert(CellAttrs::WIDE);
        }

        let cell = self.active_grid_mut().cell_mut(row, col);
        cell.ch = ch;
        cell.fg = fg;
        cell.bg = bg;
        cell.attrs = attrs;
        self.cursor.col += 1;

        // For wide characters, place a spacer in the next cell
        if width == 2 && self.cursor.col < self.cols {
            let spacer_col = self.cursor.col;
            let spacer = self.active_grid_mut().cell_mut(row, spacer_col);
            spacer.ch = ' ';
            spacer.fg = fg;
            spacer.bg = bg;
            spacer.attrs = CellAttrs::WIDE_SPACER;
            self.cursor.col += 1;
        }

        self.dirty = true;
    }

    pub fn newline(&mut self) {
        self.cursor.row += 1;
        if self.cursor.row >= self.scroll_bottom {
            self.cursor.row = self.scroll_bottom - 1;
            let top = self.scroll_top;
            let bottom = self.scroll_bottom;
            self.active_grid_mut().scroll_up(top, bottom);
        }
        if self.modes.linefeed_mode {
            self.cursor.col = 0;
        }
        self.dirty = true;
    }

    pub fn reverse_index(&mut self) {
        if self.cursor.row == self.scroll_top {
            let top = self.scroll_top;
            let bottom = self.scroll_bottom;
            self.active_grid_mut().scroll_down(top, bottom);
        } else if self.cursor.row > 0 {
            self.cursor.row -= 1;
        }
        self.dirty = true;
    }

    pub fn carriage_return(&mut self) {
        self.cursor.col = 0;
    }

    pub fn backspace(&mut self) {
        if self.cursor.col > 0 {
            self.cursor.col -= 1;
        }
    }

    pub fn tab(&mut self) {
        let start = self.cursor.col + 1;
        for i in start..self.cols {
            if self.tab_stops[i] {
                self.cursor.col = i;
                return;
            }
        }
        self.cursor.col = self.cols - 1;
    }

    pub fn erase_in_display(&mut self, mode: u16) {
        let (row, col) = (self.cursor.row, self.cursor.col);
        let grid = self.active_grid_mut();
        match mode {
            0 => {
                for c in col..grid.cols {
                    grid.cell_mut(row, c).reset();
                }
                for r in (row + 1)..grid.rows {
                    for c in 0..grid.cols {
                        grid.cell_mut(r, c).reset();
                    }
                }
            }
            1 => {
                for r in 0..row {
                    for c in 0..grid.cols {
                        grid.cell_mut(r, c).reset();
                    }
                }
                for c in 0..=col.min(grid.cols - 1) {
                    grid.cell_mut(row, c).reset();
                }
            }
            2 | 3 => {
                grid.clear();
            }
            _ => {}
        }
        self.dirty = true;
    }

    pub fn erase_in_line(&mut self, mode: u16) {
        let (row, col) = (self.cursor.row, self.cursor.col);
        let grid = self.active_grid_mut();
        match mode {
            0 => {
                for c in col..grid.cols {
                    grid.cell_mut(row, c).reset();
                }
            }
            1 => {
                for c in 0..=col.min(grid.cols - 1) {
                    grid.cell_mut(row, c).reset();
                }
            }
            2 => {
                for c in 0..grid.cols {
                    grid.cell_mut(row, c).reset();
                }
            }
            _ => {}
        }
        self.dirty = true;
    }

    pub fn insert_lines(&mut self, count: usize) {
        let row = self.cursor.row;
        if row < self.scroll_top || row >= self.scroll_bottom {
            return;
        }
        let bottom = self.scroll_bottom;
        for _ in 0..count {
            self.active_grid_mut().scroll_down(row, bottom);
        }
        self.dirty = true;
    }

    pub fn delete_lines(&mut self, count: usize) {
        let row = self.cursor.row;
        if row < self.scroll_top || row >= self.scroll_bottom {
            return;
        }
        let bottom = self.scroll_bottom;
        for _ in 0..count {
            self.active_grid_mut().scroll_up(row, bottom);
        }
        self.dirty = true;
    }

    pub fn delete_chars(&mut self, count: usize) {
        let row = self.cursor.row;
        let col = self.cursor.col;
        let grid = self.active_grid_mut();
        let cols = grid.cols;

        for c in col..cols {
            if c + count < cols {
                grid.cells[row][c] = grid.cells[row][c + count].clone();
            } else {
                grid.cells[row][c].reset();
            }
        }
        self.dirty = true;
    }

    pub fn erase_chars(&mut self, count: usize) {
        let row = self.cursor.row;
        let col = self.cursor.col;
        let grid = self.active_grid_mut();
        let end = (col + count).min(grid.cols);
        for c in col..end {
            grid.cell_mut(row, c).reset();
        }
        self.dirty = true;
    }

    pub fn insert_blanks(&mut self, count: usize) {
        let row = self.cursor.row;
        let col = self.cursor.col;
        let grid = self.active_grid_mut();
        let cols = grid.cols;

        // Shift characters right
        for c in (col..cols).rev() {
            if c >= col + count {
                grid.cells[row][c] = grid.cells[row][c - count].clone();
            } else {
                grid.cells[row][c].reset();
            }
        }
        self.dirty = true;
    }

    pub fn set_cursor_pos(&mut self, row: usize, col: usize) {
        self.cursor.row = row.min(self.rows - 1);
        self.cursor.col = col.min(self.cols - 1);
    }

    pub fn resize(&mut self, cols: usize, rows: usize) {
        self.primary.resize(cols, rows);
        self.alternate.resize(cols, rows);
        self.cols = cols;
        self.rows = rows;
        self.scroll_bottom = rows;
        if self.cursor.row >= rows {
            self.cursor.row = rows - 1;
        }
        if self.cursor.col >= cols {
            self.cursor.col = cols - 1;
        }
        self.tab_stops = vec![false; cols];
        for i in (0..cols).step_by(8) {
            self.tab_stops[i] = true;
        }
        self.dirty = true;
    }

    pub fn save_cursor(&mut self) {
        self.saved_cursor = Some(self.cursor.clone());
    }

    pub fn restore_cursor(&mut self) {
        if let Some(saved) = self.saved_cursor.clone() {
            self.cursor = saved;
        }
    }

    pub fn enter_alternate_screen(&mut self) {
        if !self.modes.alternate_screen {
            self.modes.alternate_screen = true;
            self.alternate.clear();
            self.save_cursor();
        }
    }

    pub fn exit_alternate_screen(&mut self) {
        if self.modes.alternate_screen {
            self.modes.alternate_screen = false;
            self.restore_cursor();
        }
    }

    pub fn set_scroll_region(&mut self, top: usize, bottom: usize) {
        let top = top.min(self.rows - 1);
        let bottom = bottom.min(self.rows);
        if top < bottom {
            self.scroll_top = top;
            self.scroll_bottom = bottom;
        }
    }
}
