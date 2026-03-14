use std::collections::{HashMap, VecDeque};

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
    base: usize, // ring buffer offset for O(1) full-screen scrolling
    pub hyperlinks: HashMap<(usize, usize), String>,
    /// Tracks whether row `i` was soft-wrapped (auto-wrap at column boundary).
    /// Indexed via `(base + row) % rows`, same as cells.
    pub wrapped: Vec<bool>,
}

impl Grid {
    pub fn new(cols: usize, rows: usize) -> Self {
        let cells = (0..rows)
            .map(|_| (0..cols).map(|_| Cell::default()).collect())
            .collect();
        let wrapped = vec![false; rows];
        Self {
            cols,
            rows,
            cells,
            base: 0,
            hyperlinks: HashMap::new(),
            wrapped,
        }
    }

    pub fn cell(&self, row: usize, col: usize) -> &Cell {
        &self.cells[(self.base + row) % self.rows][col]
    }

    pub fn cell_mut(&mut self, row: usize, col: usize) -> &mut Cell {
        let physical = (self.base + row) % self.rows;
        &mut self.cells[physical][col]
    }

    pub fn clear(&mut self) {
        for row in &mut self.cells {
            for cell in row {
                cell.reset();
            }
        }
        self.base = 0;
        self.hyperlinks.clear();
        for w in &mut self.wrapped {
            *w = false;
        }
    }

    /// Get the physical row index for a logical row.
    pub fn physical_row(&self, row: usize) -> usize {
        (self.base + row) % self.rows
    }

    pub fn get_hyperlink(&self, row: usize, col: usize) -> Option<&String> {
        self.hyperlinks.get(&(self.physical_row(row), col))
    }

    pub fn set_hyperlink(&mut self, row: usize, col: usize, url: String) {
        self.hyperlinks.insert((self.physical_row(row), col), url);
    }

    pub fn remove_hyperlink(&mut self, row: usize, col: usize) {
        self.hyperlinks.remove(&(self.physical_row(row), col));
    }

    /// Scroll up within a region. Returns the removed row and its wrapped flag.
    pub fn scroll_up(&mut self, top: usize, bottom: usize) -> Option<(Vec<Cell>, bool)> {
        if top + 1 >= bottom || bottom > self.rows {
            return None;
        }

        // Fast path: full-screen scroll — O(1) ring buffer rotation
        if top == 0 && bottom == self.rows {
            let physical = self.base % self.rows;
            let removed = std::mem::replace(
                &mut self.cells[physical],
                (0..self.cols).map(|_| Cell::default()).collect(),
            );
            let was_wrapped = std::mem::replace(&mut self.wrapped[physical], false);
            // Remove hyperlinks for the recycled physical row (logical row 0)
            let phys_row0 = self.base % self.rows;
            self.hyperlinks.retain(|&(r, _), _| r != phys_row0);
            // No key shifting needed — physical keys remain valid after base rotation
            self.base = (self.base + 1) % self.rows;
            return Some((removed, was_wrapped));
        }

        // Partial scroll region: linearize then use remove/insert
        self.linearize();
        let removed = self.cells.remove(top);
        let was_wrapped = self.wrapped.remove(top);
        let blank = (0..self.cols).map(|_| Cell::default()).collect();
        self.cells.insert(bottom - 1, blank);
        self.wrapped.insert(bottom - 1, false);
        // Remove hyperlinks for the removed row, shift affected rows
        self.hyperlinks.retain(|&(r, _), _| r != top);
        let old: Vec<_> = self.hyperlinks.drain().collect();
        for ((r, c), v) in old {
            if r > top && r < bottom {
                self.hyperlinks.insert((r - 1, c), v);
            } else {
                self.hyperlinks.insert((r, c), v);
            }
        }
        Some((removed, was_wrapped))
    }

    pub fn scroll_down(&mut self, top: usize, bottom: usize) {
        if top + 1 >= bottom || bottom > self.rows {
            return;
        }
        self.linearize();
        self.cells.remove(bottom - 1);
        self.wrapped.remove(bottom - 1);
        let blank = (0..self.cols).map(|_| Cell::default()).collect();
        self.cells.insert(top, blank);
        self.wrapped.insert(top, false);
        // Remove hyperlinks for the removed bottom row, shift affected rows up
        self.hyperlinks.retain(|&(r, _), _| r != bottom - 1);
        let old: Vec<_> = self.hyperlinks.drain().collect();
        for ((r, c), v) in old {
            if r >= top && r < bottom {
                self.hyperlinks.insert((r + 1, c), v);
            } else {
                self.hyperlinks.insert((r, c), v);
            }
        }
    }

    pub fn resize(&mut self, new_cols: usize, new_rows: usize) {
        self.linearize();
        while self.cells.len() < new_rows {
            self.cells
                .push((0..new_cols).map(|_| Cell::default()).collect());
            self.wrapped.push(false);
        }
        self.cells.truncate(new_rows);
        self.wrapped.truncate(new_rows);
        for row in &mut self.cells {
            row.resize(new_cols, Cell::default());
        }
        self.cols = new_cols;
        self.rows = new_rows;
        // Remove out-of-bounds hyperlinks
        self.hyperlinks
            .retain(|&(r, c), _| r < new_rows && c < new_cols);
    }

    /// Linearize the ring buffer so logical row 0 is at cells[0].
    fn linearize(&mut self) {
        if self.base == 0 {
            return;
        }
        let physical_base = self.base % self.rows;
        self.cells.rotate_left(physical_base);
        self.wrapped.rotate_left(physical_base);
        // Remap hyperlink keys from old physical indices to new (logical, since base becomes 0)
        let old: Vec<_> = self.hyperlinks.drain().collect();
        for ((p, c), v) in old {
            let new_p = (p + self.rows - physical_base) % self.rows;
            self.hyperlinks.insert((new_p, c), v);
        }
        self.base = 0;
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
            (
                (self.start_col, self.start_row),
                (self.end_col, self.end_row),
            )
        } else {
            (
                (self.end_col, self.end_row),
                (self.start_col, self.start_row),
            )
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
    /// Sparse hyperlink storage for scrollback lines, keyed by (scrollback_hyperlink_base + index, col).
    pub scrollback_hyperlinks: HashMap<(usize, usize), String>,
    /// Base offset for scrollback hyperlink keys, incremented on eviction to avoid O(n) key shifting.
    pub(crate) scrollback_hyperlink_base: usize,
    /// Wrapped flags parallel to scrollback — true if row was soft-wrapped.
    pub scrollback_wrapped: VecDeque<bool>,
    /// After resize, the child process replays content already in scrollback.
    /// This counter tracks how many scroll-up events to suppress (don't add
    /// to scrollback) to avoid duplication. Decremented in do_scroll_up.
    scrollback_replay_remaining: usize,
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
            scrollback_hyperlinks: HashMap::new(),
            scrollback_hyperlink_base: 0,
            scrollback_wrapped: VecDeque::new(),
            scrollback_replay_remaining: 0,
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
                // Mark the current row as soft-wrapped
                let wrap_row = self.cursor.row;
                let phys = self.active_grid().physical_row(wrap_row);
                self.active_grid_mut().wrapped[phys] = true;
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

        let cell = self.active_grid_mut().cell_mut(row, col);
        cell.ch = ch;
        cell.fg = fg;
        cell.bg = bg;
        cell.attrs = attrs;
        if let Some(url) = self.current_hyperlink.clone() {
            self.active_grid_mut().set_hyperlink(row, col, url);
        } else {
            self.active_grid_mut().remove_hyperlink(row, col);
        }
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
        // Mark current row as NOT wrapped (hard newline)
        {
            let row = self.cursor.row;
            let phys = self.active_grid().physical_row(row);
            self.active_grid_mut().wrapped[phys] = false;
        }
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
                    grid.remove_hyperlink(row, c);
                }
                for r in (row + 1)..grid.rows {
                    for c in 0..grid.cols {
                        grid.cell_mut(r, c).reset();
                        grid.remove_hyperlink(r, c);
                    }
                }
            }
            1 => {
                for r in 0..row {
                    for c in 0..grid.cols {
                        grid.cell_mut(r, c).reset();
                        grid.remove_hyperlink(r, c);
                    }
                }
                for c in 0..=col.min(grid.cols - 1) {
                    grid.cell_mut(row, c).reset();
                    grid.remove_hyperlink(row, c);
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
                    grid.remove_hyperlink(row, c);
                }
            }
            1 => {
                for c in 0..=col.min(grid.cols - 1) {
                    grid.cell_mut(row, c).reset();
                    grid.remove_hyperlink(row, c);
                }
            }
            2 => {
                for c in 0..grid.cols {
                    grid.cell_mut(row, c).reset();
                    grid.remove_hyperlink(row, c);
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
        let phys = grid.physical_row(row);

        // Collect hyperlinks that survive the shift (from c+count → c)
        let mut shifted_links = Vec::new();
        for c in col..cols {
            if c + count < cols {
                if let Some(url) = grid.hyperlinks.get(&(phys, c + count)) {
                    shifted_links.push((c, url.clone()));
                }
            }
        }

        // Shift cells left and clear hyperlinks in affected range
        for c in col..cols {
            if c + count < cols {
                grid.cells[phys][c] = grid.cells[phys][c + count].clone();
            } else {
                grid.cells[phys][c].reset();
            }
            grid.hyperlinks.remove(&(phys, c));
        }

        // Re-insert shifted hyperlinks
        for (c, url) in shifted_links {
            grid.hyperlinks.insert((phys, c), url);
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
            grid.remove_hyperlink(row, c);
        }
        self.dirty = true;
    }

    pub fn insert_blanks(&mut self, count: usize) {
        let row = self.cursor.row;
        let col = self.cursor.col;
        let grid = self.active_grid_mut();
        let cols = grid.cols;
        let phys = grid.physical_row(row);

        // Collect hyperlinks that survive the shift (from c → c+count)
        let mut shifted_links = Vec::new();
        for c in col..cols {
            if c + count < cols {
                if let Some(url) = grid.hyperlinks.get(&(phys, c)) {
                    shifted_links.push((c + count, url.clone()));
                }
            }
        }

        // Shift characters right and clear hyperlinks in affected range
        for c in (col..cols).rev() {
            if c >= col + count {
                grid.cells[phys][c] = grid.cells[phys][c - count].clone();
            } else {
                grid.cells[phys][c].reset();
            }
            grid.hyperlinks.remove(&(phys, c));
        }

        // Re-insert shifted hyperlinks
        for (c, url) in shifted_links {
            grid.hyperlinks.insert((phys, c), url);
        }

        self.dirty = true;
    }

    pub fn set_cursor_pos(&mut self, row: usize, col: usize) {
        self.cursor.row = row.min(self.rows - 1);
        self.cursor.col = col.min(self.cols - 1);
    }

    /// Reflow scrollback lines to a new column width.
    /// Joins consecutive soft-wrapped rows into logical lines, then re-wraps
    /// each logical line to `new_cols`.
    fn reflow_scrollback(&mut self, new_cols: usize) {
        if self.scrollback.is_empty() {
            return;
        }

        let old_sb: Vec<Vec<Cell>> = self.scrollback.drain(..).collect();
        let old_wrapped: Vec<bool> = self.scrollback_wrapped.drain(..).collect();

        // Build logical lines by joining consecutive wrapped rows
        let mut logical_lines: Vec<Vec<Cell>> = Vec::new();
        let mut current_line: Vec<Cell> = Vec::new();

        for (i, row) in old_sb.into_iter().enumerate() {
            // Trim trailing spaces from this row before appending
            let mut trimmed = row;
            while trimmed.last().map_or(false, |c| {
                c.ch == ' '
                    && c.fg == Color::Default
                    && c.bg == Color::Default
                    && c.attrs == CellAttrs::empty()
            }) {
                trimmed.pop();
            }
            current_line.extend(trimmed);

            let was_wrapped = old_wrapped.get(i).copied().unwrap_or(false);
            if !was_wrapped {
                // Hard break — end of logical line
                logical_lines.push(std::mem::take(&mut current_line));
            }
        }
        // Don't forget the last line if it was wrapped (no hard break at end)
        if !current_line.is_empty() {
            logical_lines.push(current_line);
        }

        // Re-wrap each logical line to new_cols
        for line in logical_lines {
            if line.is_empty() {
                // Empty logical line → single empty row
                self.scrollback.push_back(vec![Cell::default(); new_cols]);
                self.scrollback_wrapped.push_back(false);
                continue;
            }

            let chunks = line.chunks(new_cols);
            let num_chunks = (line.len() + new_cols - 1) / new_cols;
            for (chunk_idx, chunk) in chunks.enumerate() {
                let mut new_row = chunk.to_vec();
                // Pad to new_cols
                while new_row.len() < new_cols {
                    new_row.push(Cell::default());
                }
                let is_last = chunk_idx == num_chunks - 1;
                self.scrollback.push_back(new_row);
                // All chunks except the last are soft-wrapped
                self.scrollback_wrapped.push_back(!is_last);
            }
        }

        // Clear hyperlinks (they reference old row indices)
        self.scrollback_hyperlinks.clear();
        self.scrollback_hyperlink_base = 0;

        // Enforce scrollback limit
        while self.scrollback.len() > self.scrollback_limit {
            self.scrollback.pop_front();
            self.scrollback_wrapped.pop_front();
            self.scrollback_hyperlink_base += 1;
        }
    }

    pub fn resize(&mut self, cols: usize, rows: usize) {
        let old_cols = self.cols;
        let old_rows = self.rows;

        // Invalidate selection — coordinates become meaningless after resize
        self.selection.active = false;

        if self.modes.alternate_screen {
            // Alternate screen: simple resize + clear (TUI apps redraw after SIGWINCH)
            self.primary.resize(cols, rows);
            self.alternate.resize(cols, rows);
            self.alternate.clear();
            self.cursor.row = 0;
            self.cursor.col = 0;
        } else {
            // Primary screen resize.
            //
            // Height-only change: use content-matched replay suppression.
            // The child's replayed rows match scrollback content exactly
            // since width is unchanged.
            //
            // Width change: reflow scrollback to new width, then use
            // content-matched suppression. The child's post-SIGWINCH
            // output wraps at the new width, matching reflowed scrollback.
            if cols != old_cols {
                self.reflow_scrollback(cols);
            }
            self.primary.resize(cols, rows);
            self.alternate.resize(cols, rows);
            self.scrollback_replay_remaining = self.scrollback.len();
        }

        self.cols = cols;
        self.rows = rows;
        self.scroll_top = 0;
        self.scroll_bottom = rows;
        self.viewport_offset = 0;
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

        // Before scrolling, capture hyperlinks from logical row 0 (for scrollback migration)
        let row0_hyperlinks: Vec<(usize, String)> = if is_primary && full_region {
            let grid = self.active_grid();
            let phys_row0 = grid.physical_row(0);
            grid.hyperlinks
                .iter()
                .filter(|&(&(r, _), _)| r == phys_row0)
                .map(|(&(_, c), v)| (c, v.clone()))
                .collect()
        } else {
            Vec::new()
        };

        if let Some((removed, was_wrapped)) = self.active_grid_mut().scroll_up(top, bottom) {
            if is_primary && full_region {
                // Content-matched replay suppression: after resize, the child
                // replays content already in scrollback. Compare the row being
                // pushed against existing scrollback to detect replays.
                if self.scrollback_replay_remaining > 0 {
                    let check_idx = self.scrollback.len() - self.scrollback_replay_remaining;
                    if check_idx < self.scrollback.len() {
                        let existing = &self.scrollback[check_idx];
                        let matches = removed
                            .iter()
                            .zip(existing.iter())
                            .all(|(a, b)| a.ch == b.ch);
                        if matches {
                            self.scrollback_replay_remaining -= 1;
                            return; // Suppress duplicate — content already in scrollback
                        }
                    }
                    // Content mismatch — stop suppressing, add normally
                    self.scrollback_replay_remaining = 0;
                }

                let abs_idx = self.scrollback_hyperlink_base + self.scrollback.len();
                self.scrollback.push_back(removed);
                self.scrollback_wrapped.push_back(was_wrapped);

                // Migrate row 0 hyperlinks to scrollback using absolute index
                for (c, url) in row0_hyperlinks {
                    self.scrollback_hyperlinks.insert((abs_idx, c), url);
                }

                if self.scrollback.len() > self.scrollback_limit {
                    self.scrollback.pop_front();
                    self.scrollback_wrapped.pop_front();
                    // Remove hyperlinks for the evicted scrollback line and advance base
                    self.scrollback_hyperlinks
                        .retain(|&(r, _), _| r != self.scrollback_hyperlink_base);
                    self.scrollback_hyperlink_base += 1;
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
                let row_end = if row == er {
                    ec
                } else {
                    self.cols.saturating_sub(1)
                };

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

#[cfg(test)]
mod tests {
    use super::*;

    /// Helper: write a string to the screen character by character.
    fn write_str(screen: &mut Screen, s: &str) {
        for ch in s.chars() {
            if ch == '\n' {
                screen.newline();
                screen.carriage_return();
            } else {
                screen.write_char(ch);
            }
        }
    }

    /// Helper: read a row from the grid as a string (trimmed).
    fn read_row(screen: &Screen, row: usize) -> String {
        let grid = screen.active_grid();
        let s: String = (0..grid.cols).map(|c| grid.cell(row, c).ch).collect();
        s.trim_end().to_string()
    }

    /// Helper: read a scrollback row as a string (trimmed).
    #[allow(dead_code)]
    fn read_scrollback_row(screen: &Screen, idx: usize) -> String {
        let s: String = screen.scrollback[idx].iter().map(|c| c.ch).collect();
        s.trim_end().to_string()
    }

    #[test]
    fn test_resize_height_preserves_grid() {
        // Grid content is preserved on resize (Ghostty-like: child overwrites after SIGWINCH)
        let mut screen = Screen::new(10, 5);
        write_str(&mut screen, "line0\nline1\nline2\nline3\nline4");

        screen.resize(10, 3);

        // Grid should keep top rows (Grid::resize truncates bottom)
        assert_eq!(read_row(&screen, 0), "line0");
        assert_eq!(read_row(&screen, 1), "line1");
        assert_eq!(read_row(&screen, 2), "line2");
        // Cursor clamped to new bounds
        assert!(screen.cursor.row < 3);
    }

    #[test]
    fn test_content_matched_replay_suppression() {
        // Simulate: output fills screen + scrollback, then resize, then child replays
        let mut screen = Screen::new(20, 3);
        for i in 0..6 {
            write_str(&mut screen, &format!("line {}", i));
            if i < 5 {
                screen.newline();
                screen.carriage_return();
            }
        }
        // scrollback should have lines 0-2, grid has lines 3-5
        let sb_before = screen.scrollback.len();
        assert!(sb_before > 0);

        // Resize triggers replay suppression
        screen.resize(20, 3);

        // Simulate child replaying: output same lines again from cursor home
        screen.cursor.row = 0;
        screen.cursor.col = 0;
        for i in 0..6 {
            write_str(&mut screen, &format!("line {}", i));
            if i < 5 {
                screen.newline();
                screen.carriage_return();
            }
        }

        // Scrollback should NOT have grown — replayed rows were suppressed
        assert_eq!(
            screen.scrollback.len(),
            sb_before,
            "scrollback grew from {} to {} (duplicates not suppressed)",
            sb_before,
            screen.scrollback.len()
        );
    }

    #[test]
    fn test_replay_suppression_stops_on_new_content() {
        let mut screen = Screen::new(20, 3);
        for i in 0..6 {
            write_str(&mut screen, &format!("line {}", i));
            if i < 5 {
                screen.newline();
                screen.carriage_return();
            }
        }
        let sb_before = screen.scrollback.len();

        screen.resize(20, 3);

        // Simulate child replaying some lines then outputting NEW content
        screen.cursor.row = 0;
        screen.cursor.col = 0;
        for i in 0..3 {
            write_str(&mut screen, &format!("line {}", i));
            screen.newline();
            screen.carriage_return();
        }
        // Now output new content that doesn't match scrollback
        for i in 0..5 {
            write_str(&mut screen, &format!("NEW {}", i));
            if i < 4 {
                screen.newline();
                screen.carriage_return();
            }
        }

        // Scrollback should have grown — new content was added after mismatch
        assert!(
            screen.scrollback.len() > sb_before,
            "new content should have been added to scrollback"
        );
    }

    #[test]
    fn test_width_change_reflows_scrollback() {
        let mut screen = Screen::new(10, 3);
        // Write 6 lines of 10-char content → 3 go to scrollback
        for i in 0..6 {
            write_str(&mut screen, &format!("line{:05}", i));
            if i < 5 {
                screen.newline();
                screen.carriage_return();
            }
        }
        let sb_before = screen.scrollback.len();
        assert!(sb_before > 0);

        // Width change should reflow scrollback (not clear it)
        screen.resize(5, 3);
        // Each 10-char line at width 5 → 2 rows, so scrollback grows
        assert!(
            screen.scrollback.len() >= sb_before,
            "scrollback should be reflowed on width change, not cleared"
        );
        // Content should be preserved: first scrollback row should start with "line0"
        let first_row: String = screen.scrollback[0].iter().map(|c| c.ch).collect();
        assert!(
            first_row.starts_with("line0"),
            "reflowed scrollback should preserve content"
        );
    }

    #[test]
    fn test_resize_cursor_clamped() {
        let mut screen = Screen::new(10, 5);
        write_str(&mut screen, "some text");
        screen.cursor.row = 4;
        screen.cursor.col = 7;

        // Cursor should be clamped to new bounds
        screen.resize(10, 3);
        assert!(screen.cursor.row < 3);
        assert!(screen.cursor.col < 10);
    }

    #[test]
    fn test_selection_cleared_on_resize() {
        let mut screen = Screen::new(10, 5);
        screen.selection.active = true;
        screen.selection.start_col = 0;
        screen.selection.start_row = 0;
        screen.selection.end_col = 5;
        screen.selection.end_row = 2;

        screen.resize(10, 3);
        assert!(!screen.selection.active);
    }

    #[test]
    fn test_alternate_screen_resize() {
        let mut screen = Screen::new(10, 5);
        screen.enter_alternate_screen();
        write_str(&mut screen, "alt content");

        screen.resize(15, 8);
        assert_eq!(screen.cursor.row, 0);
        assert_eq!(screen.cursor.col, 0);
        assert_eq!(screen.rows, 8);
        assert_eq!(screen.cols, 15);
    }

    #[test]
    fn test_scrollback_preserved_on_resize() {
        let mut screen = Screen::new(20, 5);
        for i in 0..10 {
            write_str(&mut screen, &format!("line {}", i));
            if i < 9 {
                screen.newline();
                screen.carriage_return();
            }
        }
        let sb_len = screen.scrollback.len();
        assert!(sb_len > 0, "should have scrollback");

        screen.resize(20, 3);
        assert_eq!(
            screen.scrollback.len(),
            sb_len,
            "scrollback should be preserved on resize"
        );
    }
}
