use crate::terminal::cell::Cell;
use std::collections::VecDeque;

/// Types of detected output regions in Claude Code sessions.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum RegionType {
    Normal = 0,
    ToolUse = 1,     // Tool invocation header (Read, Write, Edit, Bash, etc.)
    ToolOutput = 2,  // Output from a tool
    CodeBlock = 3,   // Fenced code block (```)
    Thinking = 4,    // Thinking/reasoning block
    Prompt = 5,      // AI prompt line (❯)
    CostSummary = 6, // Token/cost info line
    Diff = 7,        // Diff output (+/- lines)
    Separator = 8,   // Visual separator (─── lines)
}

/// A detected region in the terminal output.
#[derive(Clone, Debug)]
pub struct OutputRegion {
    pub start_row: i64, // absolute row (negative = scrollback)
    pub end_row: i64,
    pub region_type: RegionType,
    pub collapsed: bool,
    pub label: String,     // e.g., "Read(src/main.rs)" or "```python"
    pub line_count: usize, // number of lines in this region
}

/// Known tool names used by Claude Code.
const TOOL_NAMES: &[&str] = &[
    "Read",
    "Write",
    "Edit",
    "Bash",
    "Glob",
    "Grep",
    "Agent",
    "WebFetch",
    "WebSearch",
    "LSP",
    "TodoRead",
    "TodoWrite",
    "AskUser",
    "NotebookEdit",
    "MultiEdit",
];

/// AI Output Analyzer — detects Claude Code patterns in terminal cell rows.
pub struct AiAnalyzer {
    regions: Vec<OutputRegion>,
    /// Last analyzed scrollback row count (to detect new content).
    last_scrollback_len: usize,
    /// Last analyzed screen content hash (to detect changes).
    last_screen_hash: u64,
    /// Whether the analyzer is enabled (only for Claude sessions).
    enabled: bool,
    /// Track currently open region for incremental analysis.
    current_region: Option<(RegionType, i64, String)>,
    /// Track if we're inside a code fence.
    in_code_fence: bool,
    /// Latest detected plan title from "Here is Claude's plan:" pattern.
    detected_plan_title: Option<String>,
    /// Row where "Here is Claude's plan:" header was seen.
    plan_header_row: Option<i64>,
    /// Titles the user already dismissed (prevents re-showing).
    dismissed_plan_titles: Vec<String>,
}

impl AiAnalyzer {
    pub fn new() -> Self {
        Self {
            regions: Vec::new(),
            last_scrollback_len: 0,
            last_screen_hash: 0,
            enabled: false,
            current_region: None,
            in_code_fence: false,
            detected_plan_title: None,
            plan_header_row: None,
            dismissed_plan_titles: Vec::new(),
        }
    }

    pub fn set_enabled(&mut self, enabled: bool) {
        self.enabled = enabled;
        if !enabled {
            self.regions.clear();
            self.current_region = None;
            self.in_code_fence = false;
        }
    }

    pub fn is_enabled(&self) -> bool {
        self.enabled
    }

    /// Get the latest detected plan title, if any.
    pub fn detected_plan_title(&self) -> Option<&str> {
        self.detected_plan_title.as_deref()
    }

    /// Clear the detected plan title and mark it as dismissed.
    pub fn clear_plan_title(&mut self) {
        if let Some(title) = self.detected_plan_title.take() {
            self.dismissed_plan_titles.push(title);
        }
    }

    pub fn regions(&self) -> &[OutputRegion] {
        &self.regions
    }

    pub fn region_count(&self) -> usize {
        self.regions.len()
    }

    /// Toggle collapsed state for a region containing the given row.
    pub fn toggle_fold(&mut self, row: i64) -> bool {
        for region in &mut self.regions {
            if row >= region.start_row && row <= region.end_row {
                region.collapsed = !region.collapsed;
                return true;
            }
        }
        false
    }

    /// Analyze terminal output. Called after PTY processing.
    /// Scans scrollback + active grid rows, extracting text and detecting patterns.
    pub fn analyze(
        &mut self,
        scrollback: &VecDeque<Vec<Cell>>,
        grid_cells: &[Vec<Cell>],
        grid_rows: usize,
    ) {
        if !self.enabled {
            return;
        }

        let sb_len = scrollback.len();

        // Simple change detection: only re-analyze if content changed
        let screen_hash = self.compute_screen_hash(grid_cells, grid_rows);
        if sb_len == self.last_scrollback_len && screen_hash == self.last_screen_hash {
            return;
        }

        // Preserve collapsed state from old regions
        let old_collapsed: Vec<(i64, bool)> = self
            .regions
            .iter()
            .filter(|r| r.collapsed)
            .map(|r| (r.start_row, r.collapsed))
            .collect();

        self.regions.clear();
        self.current_region = None;
        self.in_code_fence = false;
        self.plan_header_row = None;

        // Scan scrollback
        for (idx, row_cells) in scrollback.iter().enumerate() {
            let abs_row = idx as i64 - sb_len as i64;
            let text = Self::cells_to_text(row_cells);
            self.process_line(&text, abs_row);
        }

        // Scan active grid
        for row in 0..grid_rows {
            if row < grid_cells.len() {
                let text = Self::cells_to_text(&grid_cells[row]);
                self.process_line(&text, row as i64);
            }
        }

        // Close any open region
        self.close_current_region(if grid_rows > 0 {
            grid_rows as i64 - 1
        } else {
            0
        });

        // Restore collapsed state
        for (start_row, collapsed) in old_collapsed {
            for region in &mut self.regions {
                if region.start_row == start_row {
                    region.collapsed = collapsed;
                    break;
                }
            }
        }

        // Compute line counts
        for region in &mut self.regions {
            region.line_count = (region.end_row - region.start_row + 1) as usize;
        }

        self.last_scrollback_len = sb_len;
        self.last_screen_hash = screen_hash;
    }

    fn process_line(&mut self, text: &str, abs_row: i64) {
        let trimmed = text.trim();
        if trimmed.is_empty() {
            return;
        }

        // Plan title detection: "Here is Claude's plan:" → separator → title
        if self.plan_header_row.is_some() {
            if self.is_separator_line(trimmed) {
                // Skip separator between header and title
                // (fall through to normal separator handling below)
            } else {
                // Non-empty, non-separator line after header → this is the plan title
                let title = trimmed.to_string();
                if !self.dismissed_plan_titles.contains(&title) {
                    self.detected_plan_title = Some(title);
                }
                self.plan_header_row = None;
            }
        }
        if trimmed.contains("Here is Claude's plan:")
            || trimmed.contains("Here is Claude\u{2019}s plan:")
        {
            self.plan_header_row = Some(abs_row);
        }

        // Detect code fence boundaries
        if trimmed.starts_with("```") {
            if self.in_code_fence {
                // Closing fence
                self.in_code_fence = false;
                // Extend current code block region to include this line
                if let Some((RegionType::CodeBlock, _, _)) = &self.current_region {
                    // Will be closed by next non-code line
                    self.close_current_region(abs_row);
                }
                return;
            } else {
                // Opening fence
                self.in_code_fence = true;
                self.close_current_region(abs_row.saturating_sub(1));
                let lang = trimmed.strip_prefix("```").unwrap_or("").trim().to_string();
                let label = if lang.is_empty() {
                    "code".to_string()
                } else {
                    lang
                };
                self.current_region = Some((RegionType::CodeBlock, abs_row, label));
                return;
            }
        }

        // Inside a code fence — everything is code
        if self.in_code_fence {
            return;
        }

        // Detect tool use patterns
        // Claude Code shows tool use with colored text like: ⏺ Read(file_path: "...")
        // or with box drawing: ╭─ or ├─ or │ or ╰─
        if self.is_tool_header(trimmed) {
            self.close_current_region(abs_row.saturating_sub(1));
            let label = self.extract_tool_label(trimmed);
            self.current_region = Some((RegionType::ToolUse, abs_row, label));
            return;
        }

        // Detect tool output continuation (box-drawing continuation)
        if self.is_box_continuation(trimmed) {
            if let Some((rt, _, _)) = &self.current_region {
                if *rt == RegionType::ToolUse || *rt == RegionType::ToolOutput {
                    return; // Continue current region
                }
            }
            self.close_current_region(abs_row.saturating_sub(1));
            self.current_region = Some((RegionType::ToolOutput, abs_row, String::new()));
            return;
        }

        // Detect box-drawing end
        if self.is_box_end(trimmed) {
            // Close the current tool region on this line
            if let Some((rt, _, _)) = &self.current_region {
                if *rt == RegionType::ToolUse || *rt == RegionType::ToolOutput {
                    self.close_current_region(abs_row);
                    return;
                }
            }
        }

        // Detect thinking blocks
        if self.is_thinking_marker(trimmed) {
            self.close_current_region(abs_row.saturating_sub(1));
            self.current_region = Some((RegionType::Thinking, abs_row, "thinking".to_string()));
            return;
        }

        // Detect prompt lines (❯ or similar)
        if self.is_prompt_line(trimmed) {
            self.close_current_region(abs_row.saturating_sub(1));
            self.regions.push(OutputRegion {
                start_row: abs_row,
                end_row: abs_row,
                region_type: RegionType::Prompt,
                collapsed: false,
                label: String::new(),
                line_count: 1,
            });
            return;
        }

        // Detect cost/token summary lines
        if self.is_cost_line(trimmed) {
            self.close_current_region(abs_row.saturating_sub(1));
            self.regions.push(OutputRegion {
                start_row: abs_row,
                end_row: abs_row,
                region_type: RegionType::CostSummary,
                collapsed: false,
                label: trimmed.to_string(),
                line_count: 1,
            });
            return;
        }

        // Detect diff lines
        if self.is_diff_line(trimmed) {
            if let Some((RegionType::Diff, _, _)) = &self.current_region {
                return; // Continue diff region
            }
            self.close_current_region(abs_row.saturating_sub(1));
            self.current_region = Some((RegionType::Diff, abs_row, "diff".to_string()));
            return;
        }

        // Detect separator lines (all dashes or box chars)
        if self.is_separator_line(trimmed) {
            self.close_current_region(abs_row.saturating_sub(1));
            self.regions.push(OutputRegion {
                start_row: abs_row,
                end_row: abs_row,
                region_type: RegionType::Separator,
                collapsed: false,
                label: String::new(),
                line_count: 1,
            });
            return;
        }

        // If we're in a tool use/output region and see non-matching content, close it
        if let Some((rt, _, _)) = &self.current_region {
            match rt {
                RegionType::Thinking => {
                    // Thinking continues until a non-thinking marker
                    return;
                }
                RegionType::Diff => {
                    // Diff ends when we see a non-diff line
                    self.close_current_region(abs_row.saturating_sub(1));
                }
                _ => {}
            }
        }
    }

    /// Maximum number of tracked regions to prevent unbounded memory growth.
    const MAX_REGIONS: usize = 1000;

    fn close_current_region(&mut self, end_row: i64) {
        if let Some((region_type, start_row, label)) = self.current_region.take() {
            let actual_end = end_row.max(start_row);
            // Drop oldest regions if we've hit the cap
            if self.regions.len() >= Self::MAX_REGIONS {
                let drain_count = self.regions.len() - Self::MAX_REGIONS + 1;
                self.regions.drain(..drain_count);
            }
            self.regions.push(OutputRegion {
                start_row,
                end_row: actual_end,
                region_type,
                collapsed: false,
                label,
                line_count: (actual_end - start_row + 1) as usize,
            });
        }
    }

    fn is_tool_header(&self, text: &str) -> bool {
        // Claude Code tool headers contain tool names
        for name in TOOL_NAMES {
            // Pattern: "⏺ ToolName(" or "ToolName:" or "── ToolName"
            if text.contains(&format!("{}(", name)) || text.contains(&format!("{} (", name)) {
                return true;
            }
        }

        // Box-drawing header pattern: ╭─ or ┌─
        if (text.starts_with('╭') || text.starts_with('┌')) && text.contains('─') {
            return true;
        }

        false
    }

    fn is_box_continuation(&self, text: &str) -> bool {
        text.starts_with('│') || text.starts_with('┃') || text.starts_with('├')
    }

    fn is_box_end(&self, text: &str) -> bool {
        (text.starts_with('╰') || text.starts_with('└')) && text.contains('─')
    }

    fn extract_tool_label(&self, text: &str) -> String {
        for name in TOOL_NAMES {
            if let Some(pos) = text.find(name) {
                // Try to extract tool name + first argument
                let after = &text[pos..];
                // Find the end of the tool call description
                if let Some(paren_pos) = after.find('(') {
                    if let Some(close_pos) = after[paren_pos..].find(')') {
                        let end = paren_pos + close_pos + 1;
                        return after[..end].to_string();
                    }
                    // No closing paren — take up to 60 chars safely
                    return after.chars().take(60).collect();
                }
                return name.to_string();
            }
        }

        // Fallback: first 40 chars
        text.chars().take(40).collect()
    }

    fn is_thinking_marker(&self, text: &str) -> bool {
        text.contains("Thinking") && (text.contains("...") || text.contains("…"))
            || text.starts_with("💭")
            || text.starts_with("🤔")
    }

    fn is_prompt_line(&self, text: &str) -> bool {
        text.starts_with('❯') || text.ends_with(" ❯") || (text.starts_with("> ") && text.len() < 4)
    }

    fn is_cost_line(&self, text: &str) -> bool {
        // Token/cost patterns: "Xk input · Yk output" or "tokens:" or "$X.XX"
        let lower = text.to_lowercase();
        (lower.contains("token") && (lower.contains("input") || lower.contains("output")))
            || (lower.contains("cost") && lower.contains('$'))
            || (text.contains(" in ·") && text.contains(" out"))
    }

    fn is_diff_line(&self, text: &str) -> bool {
        // Only match diff lines when we're already in a diff context,
        // or for unambiguous diff headers.
        if text.starts_with("diff --git") || text.starts_with("@@") {
            return true;
        }
        if text.starts_with("+++") || text.starts_with("---") {
            // Must look like a diff header (e.g. "+++ a/file" or "--- b/file")
            return text.len() > 4 && text.as_bytes().get(3) == Some(&b' ');
        }
        // Single +/- lines only count as diff if we're already in a diff region
        if let Some((RegionType::Diff, _, _)) = &self.current_region {
            if text.starts_with('+') || text.starts_with('-') {
                return true;
            }
        }
        false
    }

    fn is_separator_line(&self, text: &str) -> bool {
        if text.len() < 3 {
            return false;
        }
        // All dashes, all box-drawing horizontal, or all equals
        text.chars()
            .all(|c| c == '─' || c == '━' || c == '═' || c == '-' || c == '=')
    }

    /// Extract text content from a row of cells.
    fn cells_to_text(cells: &[Cell]) -> String {
        let text: String = cells.iter().map(|c| c.ch).collect();
        // Trim trailing spaces
        text.trim_end().to_string()
    }

    /// Simple hash for change detection on the active screen grid.
    fn compute_screen_hash(&self, grid_cells: &[Vec<Cell>], grid_rows: usize) -> u64 {
        let mut hash: u64 = 0;
        for row in 0..grid_rows.min(grid_cells.len()) {
            for cell in &grid_cells[row] {
                hash = hash.wrapping_mul(31).wrapping_add(cell.ch as u64);
            }
        }
        hash
    }

    /// Get summary info for the side panel: count of each region type.
    pub fn region_summary(&self) -> RegionSummary {
        let mut summary = RegionSummary::default();
        for region in &self.regions {
            match region.region_type {
                RegionType::ToolUse => {
                    summary.tool_use_count += 1;
                    // Extract file references from tool labels
                    if let Some(file) = Self::extract_file_ref(&region.label) {
                        if !summary.file_refs.contains(&file) {
                            summary.file_refs.push(file);
                        }
                    }
                }
                RegionType::CodeBlock => summary.code_block_count += 1,
                RegionType::Thinking => summary.thinking_count += 1,
                RegionType::Diff => summary.diff_count += 1,
                _ => {}
            }
        }
        summary
    }

    /// Extract file path from a tool label like "Read(src/main.rs)".
    fn extract_file_ref(label: &str) -> Option<String> {
        // Only extract from file-oriented tools, skip Bash/shell commands
        let file_tools = ["Read", "Write", "Edit", "Glob", "Grep"];
        let is_file_tool = file_tools.iter().any(|t| label.starts_with(t));
        if !is_file_tool {
            return None;
        }
        // Look for patterns like: Read(file_path) or Edit(file_path, ...)
        if let Some(paren_start) = label.find('(') {
            let inner = &label[paren_start + 1..];
            let end = inner
                .find(|c: char| c == ')' || c == ',')
                .unwrap_or(inner.len());
            let mut path = inner[..end].trim().trim_matches('"').trim_matches('\'');
            // Strip parameter name prefix like "file_path: " or "path: "
            if let Some(colon_pos) = path.find(':') {
                path = path[colon_pos + 1..]
                    .trim()
                    .trim_matches('"')
                    .trim_matches('\'');
            }
            if !path.is_empty() && path != "null" && (path.contains('/') || path.contains('.')) {
                return Some(path.to_string());
            }
        }
        None
    }
}

/// Summary of detected regions for the side panel.
#[derive(Default, Debug)]
pub struct RegionSummary {
    pub tool_use_count: usize,
    pub code_block_count: usize,
    pub thinking_count: usize,
    pub diff_count: usize,
    pub file_refs: Vec<String>,
}
