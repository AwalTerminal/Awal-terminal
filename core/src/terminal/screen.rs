use std::collections::VecDeque;

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

    pub fn scroll_up(&mut self, top: usize, bottom: usize) -> Option<Vec<Cell>> {
        if top + 1 >= bottom || bottom > self.rows {
            return None;
        }
        let removed = self.cells.remove(top);
        let blank = (0..self.cols).map(|_| Cell::default()).collect();
        self.cells.insert(bottom - 1, blank);
        Some(removed)
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

/// Selection anchor points (in grid coordinates).
#[derive(Clone, Debug)]
pub struct Selection {
    pub start_col: usize,
    pub start_row: i64, // negative = scrollback
    pub end_col: usize,
    pub end_row: i64,
    pub active: bool,
    pub rectangular: bool, // block/column selection mode
}

impl Selection {
    pub fn new() -> Self {
        Self {
            start_col: 0,
            start_row: 0,
            end_col: 0,
            end_row: 0,
            active: false,
            rectangular: false,
        }
    }

    /// Return (start, end) with start <= end in reading order.
    pub fn ordered(&self) -> ((usize, i64), (usize, i64)) {
        if self.start_row < self.end_row
            || (self.start_row == self.end_row && self.start_col <= self.end_col)
        {
            ((self.start_col, self.start_row), (self.end_col, self.end_row))
        } else {
            ((self.end_col, self.end_row), (self.start_col, self.start_row))
        }
    }

    pub fn contains(&self, col: usize, row: i64) -> bool {
        if !self.active {
            return false;
        }
        let ((sc, sr), (ec, er)) = self.ordered();
        if row < sr || row > er {
            return false;
        }
        if self.rectangular {
            // Block selection: same column range on every row
            let left = sc.min(ec);
            let right = sc.max(ec);
            return col >= left && col <= right;
        }
        if row == sr && row == er {
            return col >= sc && col <= ec;
        }
        if row == sr {
            return col >= sc;
        }
        if row == er {
            return col <= ec;
        }
        true
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
    pub scrollback: VecDeque<Vec<Cell>>,
    pub scrollback_limit: usize,
    pub viewport_offset: usize,
    pub selection: Selection,
    pub title: String,
    pub working_directory: String,
    pub current_hyperlink: Option<String>,
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
            scrollback: VecDeque::new(),
            scrollback_limit: 10_000,
            viewport_offset: 0,
            selection: Selection::new(),
            title: String::new(),
            working_directory: String::new(),
            current_hyperlink: None,
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
                    self.do_scroll_up();
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

        let hyperlink = self.current_hyperlink.clone();
        let cell = self.active_grid_mut().cell_mut(row, col);
        cell.ch = ch;
        cell.fg = fg;
        cell.bg = bg;
        cell.attrs = attrs;
        cell.hyperlink = hyperlink;
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
            self.do_scroll_up();
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
        self.scroll_top = 0;
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

    /// Scroll the active grid up and capture scrollback (only for primary screen, full-width scroll region).
    pub fn do_scroll_up(&mut self) {
        let top = self.scroll_top;
        let bottom = self.scroll_bottom;
        let is_primary = !self.modes.alternate_screen;
        let full_region = top == 0 && bottom == self.rows;

        if let Some(removed) = self.active_grid_mut().scroll_up(top, bottom) {
            if is_primary && full_region {
                self.scrollback.push_back(removed);
                if self.scrollback.len() > self.scrollback_limit {
                    self.scrollback.pop_front();
                }
                // If user is scrolled up, keep their viewport stable
                if self.viewport_offset > 0 {
                    self.viewport_offset += 1;
                    // Clamp
                    if self.viewport_offset > self.scrollback.len() {
                        self.viewport_offset = self.scrollback.len();
                    }
                }
            }
        }
    }

    /// Get a cell from the viewport (scrollback-aware). Row 0 = top of viewport.
    pub fn viewport_cell(&self, row: usize, col: usize) -> &Cell {
        if self.viewport_offset == 0 || self.modes.alternate_screen {
            return self.active_grid().cell(row, col);
        }
        let scrollback_len = self.scrollback.len();
        let viewport_start = scrollback_len.saturating_sub(self.viewport_offset);
        let abs_row = viewport_start + row;
        if abs_row < scrollback_len {
            // Reading from scrollback
            let line = &self.scrollback[abs_row];
            if col < line.len() {
                &line[col]
            } else {
                // Out of bounds in scrollback line (different width), return default
                static DEFAULT_CELL: Cell = Cell {
                    ch: ' ',
                    fg: Color::Default,
                    bg: Color::Default,
                    attrs: CellAttrs::empty(),
                    hyperlink: None,
                };
                &DEFAULT_CELL
            }
        } else {
            // Reading from active grid
            let grid_row = abs_row - scrollback_len;
            if grid_row < self.active_grid().rows {
                self.active_grid().cell(grid_row, col)
            } else {
                static DEFAULT_CELL: Cell = Cell {
                    ch: ' ',
                    fg: Color::Default,
                    bg: Color::Default,
                    attrs: CellAttrs::empty(),
                    hyperlink: None,
                };
                &DEFAULT_CELL
            }
        }
    }

    pub fn scroll_viewport(&mut self, delta: i32) {
        let max_offset = self.scrollback.len();
        if delta > 0 {
            // Scroll up (into history)
            self.viewport_offset = (self.viewport_offset + delta as usize).min(max_offset);
        } else {
            // Scroll down (toward live)
            let abs_delta = delta.unsigned_abs() as usize;
            self.viewport_offset = self.viewport_offset.saturating_sub(abs_delta);
        }
        self.dirty = true;
    }

    /// Get selected text from the screen (scrollback-aware).
    pub fn get_selected_text(&self) -> String {
        if !self.selection.active {
            return String::new();
        }
        let ((sc, sr), (ec, er)) = self.selection.ordered();
        let mut result = String::new();

        if self.selection.rectangular {
            // Block selection: same column range per row
            let left = sc.min(ec);
            let right = sc.max(ec);
            for row in sr..=er {
                let mut line = String::new();
                for col in left..=right {
                    let cell = self.get_cell_at_absolute(col, row);
                    if cell.attrs.contains(CellAttrs::WIDE_SPACER) {
                        continue;
                    }
                    line.push(cell.ch);
                }
                let trimmed = line.trim_end();
                result.push_str(trimmed);
                if row < er {
                    result.push('\n');
                }
            }
        } else {
            for row in sr..=er {
                let row_start = if row == sr { sc } else { 0 };
                let row_end = if row == er { ec } else { self.cols.saturating_sub(1) };

                for col in row_start..=row_end {
                    let cell = self.get_cell_at_absolute(col, row);
                    if cell.attrs.contains(CellAttrs::WIDE_SPACER) {
                        continue;
                    }
                    result.push(cell.ch);
                }

                // Trim trailing spaces on each line
                if row < er {
                    let trimmed = result.trim_end_matches(' ');
                    result = trimmed.to_string();
                    result.push('\n');
                }
            }
            // Trim trailing spaces on last line
            while result.ends_with(' ') {
                result.pop();
            }
        }
        result
    }

    /// Get a cell at an absolute row position (negative = scrollback).
    fn get_cell_at_absolute(&self, col: usize, abs_row: i64) -> &Cell {
        static DEFAULT_CELL: Cell = Cell {
            ch: ' ',
            fg: Color::Default,
            bg: Color::Default,
            attrs: CellAttrs::empty(),
            hyperlink: None,
        };
        let scrollback_len = self.scrollback.len() as i64;
        if abs_row < 0 {
            // In scrollback
            let sb_idx = (scrollback_len + abs_row) as usize;
            if sb_idx < self.scrollback.len() {
                let line = &self.scrollback[sb_idx];
                if col < line.len() {
                    return &line[col];
                }
            }
            return &DEFAULT_CELL;
        }
        let grid_row = abs_row as usize;
        if grid_row < self.active_grid().rows && col < self.active_grid().cols {
            self.active_grid().cell(grid_row, col)
        } else {
            &DEFAULT_CELL
        }
    }

    /// Search scrollback + screen for a query string. Returns (col, absolute_row) pairs.
    /// Absolute row: negative = scrollback, 0+ = screen row.
    pub fn search(&self, query: &str) -> Vec<(usize, i64)> {
        if query.is_empty() {
            return Vec::new();
        }
        let query_chars: Vec<char> = query.chars().flat_map(|c| c.to_lowercase()).collect();
        let mut results = Vec::new();

        // Search scrollback
        for (sb_idx, line) in self.scrollback.iter().enumerate() {
            let line_chars: Vec<char> = line.iter().map(|c| c.ch).collect();
            let abs_row = sb_idx as i64 - self.scrollback.len() as i64;
            Self::find_char_matches(&line_chars, &query_chars, abs_row, &mut results);
        }

        // Search active grid
        let grid = self.active_grid();
        for row in 0..grid.rows {
            let line_chars: Vec<char> = grid.cells[row].iter().map(|c| c.ch).collect();
            Self::find_char_matches(&line_chars, &query_chars, row as i64, &mut results);
        }

        results
    }

    /// Find all occurrences of query_chars in line_chars (case-insensitive, char-based).
    fn find_char_matches(
        line_chars: &[char],
        query_chars: &[char],
        abs_row: i64,
        results: &mut Vec<(usize, i64)>,
    ) {
        if query_chars.is_empty() || line_chars.len() < query_chars.len() {
            return;
        }
        let lower_line: Vec<char> = line_chars.iter().flat_map(|c| c.to_lowercase()).collect();
        for col in 0..=lower_line.len() - query_chars.len() {
            if lower_line[col..col + query_chars.len()] == *query_chars {
                results.push((col, abs_row));
            }
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
