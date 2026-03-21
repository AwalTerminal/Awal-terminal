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

/// Default tool names used by Claude Code.
const DEFAULT_TOOL_NAMES: &[&str] = &[
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
    "Skill",
    "TaskCreate",
    "TaskUpdate",
    "CronCreate",
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
    /// Whether remote control mode has been detected.
    remote_control_active: bool,
    /// The remote control session URL, if detected.
    remote_control_url: Option<String>,
    /// Configurable tool names (default: DEFAULT_TOOL_NAMES).
    tool_names: Vec<String>,
    /// Pre-compiled tool header patterns: "ToolName(" and "ToolName ("
    tool_patterns: Vec<(String, String)>,
}

impl AiAnalyzer {
    pub fn new() -> Self {
        let tool_names: Vec<String> = DEFAULT_TOOL_NAMES.iter().map(|s| s.to_string()).collect();
        let tool_patterns = Self::build_tool_patterns(&tool_names);
        Self {
            regions: Vec::new(),
            last_scrollback_len: 0,
            last_screen_hash: 0,
            enabled: false,
            current_region: None,
            in_code_fence: false,
            remote_control_active: false,
            remote_control_url: None,
            tool_names,
            tool_patterns,
        }
    }

    /// Set custom tool names (rebuilds match patterns).
    pub fn set_tool_names(&mut self, names: Vec<String>) {
        self.tool_patterns = Self::build_tool_patterns(&names);
        self.tool_names = names;
    }

    fn build_tool_patterns(names: &[String]) -> Vec<(String, String)> {
        names
            .iter()
            .map(|n| (format!("{}(", n), format!("{} (", n)))
            .collect()
    }

    pub fn set_enabled(&mut self, enabled: bool) {
        self.enabled = enabled;
        if !enabled {
            self.regions.clear();
            self.current_region = None;
            self.in_code_fence = false;
            self.remote_control_active = false;
            self.remote_control_url = None;
        }
    }

    pub fn is_enabled(&self) -> bool {
        self.enabled
    }

    /// Check if remote control mode is active.
    pub fn is_remote_control_active(&self) -> bool {
        self.remote_control_active
    }

    /// Get the remote control session URL, if any.
    pub fn remote_control_url(&self) -> Option<&str> {
        self.remote_control_url.as_deref()
    }

    /// Clear remote control state.
    pub fn clear_remote_control(&mut self) {
        self.remote_control_active = false;
        self.remote_control_url = None;
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

        // Remote control detection
        // Claude Code outputs: "/remote-control is active. Code in CLI or at"
        // followed by a URL line, and later "Remote Control active" in the status area
        if trimmed.contains("remote-control is active")
            || trimmed.contains("Remote Control active")
            || trimmed.contains("Remote Control connecting")
            || trimmed.contains("claude.ai/code/session")
        {
            self.remote_control_active = true;
            if self.remote_control_url.is_none() {
                self.remote_control_url = Self::extract_url(trimmed);
            }
        } else if self.remote_control_active && self.remote_control_url.is_none() {
            self.remote_control_url = Self::extract_url(trimmed);
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
        // Claude Code tool headers contain tool names (use pre-compiled patterns)
        for (pat_paren, pat_space) in &self.tool_patterns {
            if text.contains(pat_paren.as_str()) || text.contains(pat_space.as_str()) {
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
        for name in &self.tool_names {
            if let Some(pos) = text.find(name.as_str()) {
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
        // Fast path: check for the unique middle-dot pattern first (no allocation)
        if text.contains(" in ·") && text.contains(" out") {
            return true;
        }
        // Check for token/cost patterns (only lowercase if needed)
        let has_dollar = text.contains('$');
        let bytes = text.as_bytes();
        let has_token = bytes.windows(5).any(|w| w.eq_ignore_ascii_case(b"token"));
        if has_token {
            let has_input = bytes.windows(5).any(|w| w.eq_ignore_ascii_case(b"input"));
            let has_output = bytes.windows(6).any(|w| w.eq_ignore_ascii_case(b"output"));
            if has_input || has_output {
                return true;
            }
        }
        if has_dollar {
            let has_cost = bytes.windows(4).any(|w| w.eq_ignore_ascii_case(b"cost"));
            if has_cost {
                return true;
            }
        }
        false
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
            .all(|c| c == '─' || c == '━' || c == '═' || c == '-' || c == '=' || c == '—')
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

    /// Extract a URL starting with https:// from a line of text.
    fn extract_url(text: &str) -> Option<String> {
        if let Some(start) = text.find("https://") {
            let url_part = &text[start..];
            let end = url_part
                .find(|c: char| c.is_whitespace() || c == ')' || c == '>' || c == '"' || c == '\'')
                .unwrap_or(url_part.len());
            let url = &url_part[..end];
            if url.len() > 10 {
                return Some(url.to_string());
            }
        }
        None
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_is_separator_line() {
        let analyzer = AiAnalyzer::new();

        // Should be separators
        assert!(analyzer.is_separator_line("───────────────"));
        assert!(analyzer.is_separator_line("━━━━━━━━━━━━━━━"));
        assert!(analyzer.is_separator_line("═══════════════"));
        assert!(analyzer.is_separator_line("---------------"));
        assert!(analyzer.is_separator_line("==============="));
        assert!(analyzer.is_separator_line("———————————————")); // em-dashes

        // Too short
        assert!(!analyzer.is_separator_line("--"));
        assert!(analyzer.is_separator_line("——")); // two em-dashes

        // Mixed or non-separator content
        assert!(!analyzer.is_separator_line("--- title ---"));
        assert!(!analyzer.is_separator_line("hello world"));
    }
}
