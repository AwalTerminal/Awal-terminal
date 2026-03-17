use crate::terminal::cell::CCell;
use std::os::raw::c_char;

/// Magic bytes for .awalrec format.
const MAGIC: [u8; 4] = [b'A', b'W', b'R', b'C'];
/// Current recording format version.
const FORMAT_VERSION: u32 = 1;

/// A region snapshot for chapter markers in recordings.
#[repr(C)]
#[derive(Clone, Debug)]
pub struct RecordedRegion {
    pub start_row: i32,
    pub end_row: i32,
    pub region_type: u8,
    pub label_len: u32,
    pub label: String,
}

/// Cursor state for a single frame.
#[derive(Clone, Debug)]
struct CursorState {
    row: u32,
    col: u32,
    visible: bool,
}

/// A single frame in a recording — either a full keyframe or a sparse delta.
#[derive(Clone, Debug)]
enum FrameData {
    /// Full snapshot of all cells.
    Keyframe(Vec<CCell>),
    /// Sparse changes: (cell_index, new_cell).
    Delta(Vec<(u32, CCell)>),
}

/// A recorded frame with timestamp and metadata.
#[derive(Clone, Debug)]
struct Frame {
    /// Milliseconds since recording start.
    timestamp_ms: u64,
    data: FrameData,
    cursor: CursorState,
    /// AI regions at this point in time.
    regions: Vec<RecordedRegion>,
}

/// Recording header metadata.
#[derive(Clone, Debug)]
struct RecordingHeader {
    cols: u32,
    rows: u32,
    model: String,
    project_path: String,
    start_timestamp: u64,
}

/// A complete recording that can be saved/loaded.
pub struct Recording {
    header: RecordingHeader,
    frames: Vec<Frame>,
    /// Previous frame cells for delta computation.
    prev_cells: Vec<CCell>,
    /// Mandatory keyframe interval.
    keyframe_interval: u32,
    /// Frame counter since last keyframe.
    frames_since_keyframe: u32,
}

/// C-compatible region for FFI.
#[repr(C)]
pub struct CRecordedRegion {
    pub start_row: i32,
    pub end_row: i32,
    pub region_type: u8,
    pub label: *mut c_char,
}

/// C-compatible frame snapshot for FFI reads.
#[repr(C)]
pub struct CFrameSnapshot {
    pub timestamp_ms: u64,
    pub cursor_row: u32,
    pub cursor_col: u32,
    pub cursor_visible: bool,
    pub region_count: u32,
}

impl Recording {
    pub fn new(cols: u32, rows: u32, model: &str, project_path: &str) -> Self {
        let total = (cols * rows) as usize;
        let start = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as u64;

        Self {
            header: RecordingHeader {
                cols,
                rows,
                model: model.to_string(),
                project_path: project_path.to_string(),
                start_timestamp: start,
            },
            frames: Vec::new(),
            prev_cells: vec![
                CCell {
                    codepoint: 32,
                    fg_r: 229,
                    fg_g: 229,
                    fg_b: 229,
                    fg_a: 255,
                    bg_r: 30,
                    bg_g: 30,
                    bg_b: 30,
                    bg_a: 255,
                    attrs: 0,
                };
                total
            ],
            keyframe_interval: 300,
            frames_since_keyframe: 300, // Force keyframe on first frame
        }
    }

    /// Add a frame from the current terminal state.
    pub fn add_frame(
        &mut self,
        cells: &[CCell],
        cursor_row: u32,
        cursor_col: u32,
        cursor_visible: bool,
        regions: Vec<RecordedRegion>,
        timestamp_ms: u64,
    ) {
        let total = (self.header.cols * self.header.rows) as usize;
        if cells.len() < total {
            return;
        }
        let cells_slice = &cells[..total];

        // Idle detection: skip if zero cells changed and cursor didn't move
        if !self.frames.is_empty() {
            let changed = cells_slice
                .iter()
                .zip(self.prev_cells.iter())
                .any(|(a, b)| a.codepoint != b.codepoint || a.fg_r != b.fg_r || a.bg_r != b.bg_r);
            if !changed {
                // Check cursor change
                if let Some(last) = self.frames.last() {
                    if last.cursor.row == cursor_row
                        && last.cursor.col == cursor_col
                        && last.cursor.visible == cursor_visible
                    {
                        return; // Truly idle — skip frame
                    }
                }
            }
        }

        self.frames_since_keyframe += 1;

        let data = if self.frames_since_keyframe >= self.keyframe_interval {
            // Keyframe
            self.frames_since_keyframe = 0;
            FrameData::Keyframe(cells_slice.to_vec())
        } else {
            // Delta: compare with previous
            let mut changes: Vec<(u32, CCell)> = Vec::new();
            for (i, (new, old)) in cells_slice.iter().zip(self.prev_cells.iter()).enumerate() {
                if new.codepoint != old.codepoint
                    || new.fg_r != old.fg_r
                    || new.fg_g != old.fg_g
                    || new.fg_b != old.fg_b
                    || new.bg_r != old.bg_r
                    || new.bg_g != old.bg_g
                    || new.bg_b != old.bg_b
                    || new.attrs != old.attrs
                {
                    changes.push((i as u32, *new));
                }
            }

            // If >50% changed, use keyframe instead
            if changes.len() > total / 2 {
                self.frames_since_keyframe = 0;
                FrameData::Keyframe(cells_slice.to_vec())
            } else {
                FrameData::Delta(changes)
            }
        };

        // Update previous state
        self.prev_cells[..total].copy_from_slice(cells_slice);

        self.frames.push(Frame {
            timestamp_ms,
            data,
            cursor: CursorState {
                row: cursor_row,
                col: cursor_col,
                visible: cursor_visible,
            },
            regions,
        });
    }

    pub fn frame_count(&self) -> u32 {
        self.frames.len() as u32
    }

    /// Reconstruct the full cell buffer for frame at `index`.
    /// Returns None if index is out of bounds.
    /// Returns (cells, timestamp_ms, cursor_row, cursor_col, cursor_visible, region_count).
    pub fn get_frame_cells(&self, index: u32) -> Option<(Vec<CCell>, u64, u32, u32, bool, u32)> {
        let idx = index as usize;
        if idx >= self.frames.len() {
            return None;
        }

        let total = (self.header.cols * self.header.rows) as usize;
        let mut cells = vec![
            CCell {
                codepoint: 32,
                fg_r: 229,
                fg_g: 229,
                fg_b: 229,
                fg_a: 255,
                bg_r: 30,
                bg_g: 30,
                bg_b: 30,
                bg_a: 255,
                attrs: 0,
            };
            total
        ];

        // Walk from the most recent keyframe up to and including idx
        let mut start = idx;
        for i in (0..=idx).rev() {
            if matches!(self.frames[i].data, FrameData::Keyframe(_)) {
                start = i;
                break;
            }
            if i == 0 {
                start = 0;
                break;
            }
        }

        for i in start..=idx {
            match &self.frames[i].data {
                FrameData::Keyframe(frame_cells) => {
                    let count = frame_cells.len().min(total);
                    cells[..count].copy_from_slice(&frame_cells[..count]);
                }
                FrameData::Delta(changes) => {
                    for &(cell_idx, cell) in changes {
                        if (cell_idx as usize) < total {
                            cells[cell_idx as usize] = cell;
                        }
                    }
                }
            }
        }

        let frame = &self.frames[idx];
        Some((
            cells,
            frame.timestamp_ms,
            frame.cursor.row,
            frame.cursor.col,
            frame.cursor.visible,
            frame.regions.len() as u32,
        ))
    }

    /// Save recording to a binary .awalrec file.
    pub fn save(&self, path: &str) -> i32 {
        let mut data = Vec::new();

        // Magic + version
        data.extend_from_slice(&MAGIC);
        data.extend_from_slice(&FORMAT_VERSION.to_le_bytes());

        // Header
        data.extend_from_slice(&self.header.cols.to_le_bytes());
        data.extend_from_slice(&self.header.rows.to_le_bytes());
        data.extend_from_slice(&self.header.start_timestamp.to_le_bytes());

        // Model string (length-prefixed)
        let model_bytes = self.header.model.as_bytes();
        data.extend_from_slice(&(model_bytes.len() as u32).to_le_bytes());
        data.extend_from_slice(model_bytes);

        // Project path string
        let path_bytes = self.header.project_path.as_bytes();
        data.extend_from_slice(&(path_bytes.len() as u32).to_le_bytes());
        data.extend_from_slice(path_bytes);

        // Frame count
        data.extend_from_slice(&(self.frames.len() as u32).to_le_bytes());

        // Frames
        for frame in &self.frames {
            data.extend_from_slice(&frame.timestamp_ms.to_le_bytes());
            data.extend_from_slice(&frame.cursor.row.to_le_bytes());
            data.extend_from_slice(&frame.cursor.col.to_le_bytes());
            data.push(if frame.cursor.visible { 1 } else { 0 });

            // Frame data type + content
            match &frame.data {
                FrameData::Keyframe(cells) => {
                    data.push(0); // type = keyframe
                    data.extend_from_slice(&(cells.len() as u32).to_le_bytes());
                    for cell in cells {
                        write_cell(&mut data, cell);
                    }
                }
                FrameData::Delta(changes) => {
                    data.push(1); // type = delta
                    data.extend_from_slice(&(changes.len() as u32).to_le_bytes());
                    for (idx, cell) in changes {
                        data.extend_from_slice(&idx.to_le_bytes());
                        write_cell(&mut data, cell);
                    }
                }
            }

            // Regions
            data.extend_from_slice(&(frame.regions.len() as u32).to_le_bytes());
            for region in &frame.regions {
                data.extend_from_slice(&region.start_row.to_le_bytes());
                data.extend_from_slice(&region.end_row.to_le_bytes());
                data.push(region.region_type);
                let label_bytes = region.label.as_bytes();
                data.extend_from_slice(&(label_bytes.len() as u32).to_le_bytes());
                data.extend_from_slice(label_bytes);
            }
        }

        match std::fs::write(path, &data) {
            Ok(_) => 0,
            Err(_) => -1,
        }
    }

    /// Load a recording from a binary .awalrec file.
    pub fn load(path: &str) -> Option<Self> {
        let data = std::fs::read(path).ok()?;
        let mut pos: usize = 0;

        // Magic
        if data.len() < 8 {
            return None;
        }
        if data[0..4] != MAGIC {
            return None;
        }
        pos += 4;

        let version = read_u32(&data, &mut pos)?;
        if version != FORMAT_VERSION {
            return None;
        }

        let cols = read_u32(&data, &mut pos)?;
        let rows = read_u32(&data, &mut pos)?;
        let start_timestamp = read_u64(&data, &mut pos)?;

        let model = read_string(&data, &mut pos)?;
        let project_path = read_string(&data, &mut pos)?;
        let frame_count = read_u32(&data, &mut pos)?;

        let total = (cols * rows) as usize;
        let mut frames = Vec::with_capacity(frame_count as usize);

        for _ in 0..frame_count {
            let timestamp_ms = read_u64(&data, &mut pos)?;
            let cursor_row = read_u32(&data, &mut pos)?;
            let cursor_col = read_u32(&data, &mut pos)?;
            let cursor_visible = read_u8(&data, &mut pos)? != 0;

            let frame_type = read_u8(&data, &mut pos)?;
            let frame_data = match frame_type {
                0 => {
                    // Keyframe
                    let count = read_u32(&data, &mut pos)? as usize;
                    let mut cells = Vec::with_capacity(count);
                    for _ in 0..count {
                        cells.push(read_cell(&data, &mut pos)?);
                    }
                    FrameData::Keyframe(cells)
                }
                1 => {
                    // Delta
                    let count = read_u32(&data, &mut pos)? as usize;
                    let mut changes = Vec::with_capacity(count);
                    for _ in 0..count {
                        let idx = read_u32(&data, &mut pos)?;
                        let cell = read_cell(&data, &mut pos)?;
                        changes.push((idx, cell));
                    }
                    FrameData::Delta(changes)
                }
                _ => return None,
            };

            let region_count = read_u32(&data, &mut pos)? as usize;
            let mut regions = Vec::with_capacity(region_count);
            for _ in 0..region_count {
                let start_row = read_i32(&data, &mut pos)?;
                let end_row = read_i32(&data, &mut pos)?;
                let region_type = read_u8(&data, &mut pos)?;
                let label = read_string(&data, &mut pos)?;
                regions.push(RecordedRegion {
                    start_row,
                    end_row,
                    region_type,
                    label_len: label.len() as u32,
                    label,
                });
            }

            frames.push(Frame {
                timestamp_ms,
                data: frame_data,
                cursor: CursorState {
                    row: cursor_row,
                    col: cursor_col,
                    visible: cursor_visible,
                },
                regions,
            });
        }

        Some(Self {
            header: RecordingHeader {
                cols,
                rows,
                model,
                project_path,
                start_timestamp,
            },
            frames,
            prev_cells: vec![
                CCell {
                    codepoint: 32,
                    fg_r: 229,
                    fg_g: 229,
                    fg_b: 229,
                    fg_a: 255,
                    bg_r: 30,
                    bg_g: 30,
                    bg_b: 30,
                    bg_a: 255,
                    attrs: 0,
                };
                total
            ],
            keyframe_interval: 300,
            frames_since_keyframe: 0,
        })
    }

    pub fn cols(&self) -> u32 {
        self.header.cols
    }
    pub fn rows(&self) -> u32 {
        self.header.rows
    }
}

// Binary helpers

fn write_cell(data: &mut Vec<u8>, cell: &CCell) {
    data.extend_from_slice(&cell.codepoint.to_le_bytes());
    data.push(cell.fg_r);
    data.push(cell.fg_g);
    data.push(cell.fg_b);
    data.push(cell.fg_a);
    data.push(cell.bg_r);
    data.push(cell.bg_g);
    data.push(cell.bg_b);
    data.push(cell.bg_a);
    data.extend_from_slice(&cell.attrs.to_le_bytes());
}

fn read_u8(data: &[u8], pos: &mut usize) -> Option<u8> {
    if *pos >= data.len() {
        return None;
    }
    let v = data[*pos];
    *pos += 1;
    Some(v)
}

fn read_u32(data: &[u8], pos: &mut usize) -> Option<u32> {
    if *pos + 4 > data.len() {
        return None;
    }
    let v = u32::from_le_bytes([data[*pos], data[*pos + 1], data[*pos + 2], data[*pos + 3]]);
    *pos += 4;
    Some(v)
}

fn read_i32(data: &[u8], pos: &mut usize) -> Option<i32> {
    if *pos + 4 > data.len() {
        return None;
    }
    let v = i32::from_le_bytes([data[*pos], data[*pos + 1], data[*pos + 2], data[*pos + 3]]);
    *pos += 4;
    Some(v)
}

fn read_u64(data: &[u8], pos: &mut usize) -> Option<u64> {
    if *pos + 8 > data.len() {
        return None;
    }
    let bytes: [u8; 8] = data[*pos..*pos + 8].try_into().ok()?;
    *pos += 8;
    Some(u64::from_le_bytes(bytes))
}

fn read_string(data: &[u8], pos: &mut usize) -> Option<String> {
    let len = read_u32(data, pos)? as usize;
    if *pos + len > data.len() {
        return None;
    }
    let s = String::from_utf8(data[*pos..*pos + len].to_vec()).ok()?;
    *pos += len;
    Some(s)
}

fn read_cell(data: &[u8], pos: &mut usize) -> Option<CCell> {
    let codepoint = read_u32(data, pos)?;
    let fg_r = read_u8(data, pos)?;
    let fg_g = read_u8(data, pos)?;
    let fg_b = read_u8(data, pos)?;
    let fg_a = read_u8(data, pos)?;
    let bg_r = read_u8(data, pos)?;
    let bg_g = read_u8(data, pos)?;
    let bg_b = read_u8(data, pos)?;
    let bg_a = read_u8(data, pos)?;
    if *pos + 2 > data.len() {
        return None;
    }
    let attrs = u16::from_le_bytes([data[*pos], data[*pos + 1]]);
    *pos += 2;
    Some(CCell {
        codepoint,
        fg_r,
        fg_g,
        fg_b,
        fg_a,
        bg_r,
        bg_g,
        bg_b,
        bg_a,
        attrs,
    })
}

// ---- FFI ----

/// Create a new recording.
#[no_mangle]
pub extern "C" fn at_recording_new(
    cols: u32,
    rows: u32,
    model: *const c_char,
    path: *const c_char,
) -> *mut Recording {
    let model_str = if model.is_null() {
        ""
    } else {
        unsafe { std::ffi::CStr::from_ptr(model).to_str().unwrap_or("") }
    };
    let path_str = if path.is_null() {
        ""
    } else {
        unsafe { std::ffi::CStr::from_ptr(path).to_str().unwrap_or("") }
    };
    Box::into_raw(Box::new(Recording::new(cols, rows, model_str, path_str)))
}

/// Add a frame to the recording.
#[no_mangle]
pub extern "C" fn at_recording_add_frame(
    recording: *mut Recording,
    cells: *const CCell,
    count: u32,
    cursor_row: u32,
    cursor_col: u32,
    cursor_visible: bool,
    regions: *const CRecordedRegion,
    region_count: u32,
    timestamp_ms: u64,
) {
    if recording.is_null() || cells.is_null() {
        return;
    }
    let rec = unsafe { &mut *recording };
    let cells_slice = unsafe { std::slice::from_raw_parts(cells, count as usize) };

    let mut recorded_regions = Vec::new();
    if !regions.is_null() && region_count > 0 {
        let region_slice = unsafe { std::slice::from_raw_parts(regions, region_count as usize) };
        for r in region_slice {
            let label = if r.label.is_null() {
                String::new()
            } else {
                unsafe {
                    std::ffi::CStr::from_ptr(r.label)
                        .to_str()
                        .unwrap_or("")
                        .to_string()
                }
            };
            recorded_regions.push(RecordedRegion {
                start_row: r.start_row,
                end_row: r.end_row,
                region_type: r.region_type,
                label_len: label.len() as u32,
                label,
            });
        }
    }

    rec.add_frame(
        cells_slice,
        cursor_row,
        cursor_col,
        cursor_visible,
        recorded_regions,
        timestamp_ms,
    );
}

/// Get the number of frames in the recording.
#[no_mangle]
pub extern "C" fn at_recording_frame_count(recording: *const Recording) -> u32 {
    if recording.is_null() {
        return 0;
    }
    unsafe { (*recording).frame_count() }
}

/// Get a frame's cells and metadata.
/// Writes cells into `out_cells` (must have space for cols*rows cells)
/// and metadata into `out_snapshot`.
/// Returns true on success.
#[no_mangle]
pub extern "C" fn at_recording_get_frame(
    recording: *const Recording,
    index: u32,
    out_cells: *mut CCell,
    out_snapshot: *mut CFrameSnapshot,
) -> bool {
    if recording.is_null() || out_cells.is_null() || out_snapshot.is_null() {
        return false;
    }
    let rec = unsafe { &*recording };

    match rec.get_frame_cells(index) {
        Some((cells, timestamp_ms, cursor_row, cursor_col, cursor_visible, region_count)) => {
            let total = (rec.header.cols * rec.header.rows) as usize;
            let out_slice = unsafe { std::slice::from_raw_parts_mut(out_cells, total) };
            let count = cells.len().min(total);
            out_slice[..count].copy_from_slice(&cells[..count]);

            unsafe {
                (*out_snapshot).timestamp_ms = timestamp_ms;
                (*out_snapshot).cursor_row = cursor_row;
                (*out_snapshot).cursor_col = cursor_col;
                (*out_snapshot).cursor_visible = cursor_visible;
                (*out_snapshot).region_count = region_count;
            }
            true
        }
        None => false,
    }
}

/// Save the recording to a file. Returns 0 on success, -1 on failure.
#[no_mangle]
pub extern "C" fn at_recording_save(recording: *const Recording, path: *const c_char) -> i32 {
    if recording.is_null() || path.is_null() {
        return -1;
    }
    let rec = unsafe { &*recording };
    let path_str = unsafe {
        std::ffi::CStr::from_ptr(path)
            .to_str()
            .unwrap_or_else(|_| return "")
    };
    rec.save(path_str)
}

/// Load a recording from a file. Returns null on failure.
#[no_mangle]
pub extern "C" fn at_recording_load(path: *const c_char) -> *mut Recording {
    if path.is_null() {
        return std::ptr::null_mut();
    }
    let path_str = unsafe {
        std::ffi::CStr::from_ptr(path)
            .to_str()
            .unwrap_or_else(|_| return "")
    };
    match Recording::load(path_str) {
        Some(rec) => Box::into_raw(Box::new(rec)),
        None => std::ptr::null_mut(),
    }
}

/// Destroy a recording.
#[no_mangle]
pub extern "C" fn at_recording_destroy(recording: *mut Recording) {
    if !recording.is_null() {
        unsafe {
            drop(Box::from_raw(recording));
        }
    }
}

/// Get the grid dimensions of a recording.
#[no_mangle]
pub extern "C" fn at_recording_get_size(
    recording: *const Recording,
    cols: *mut u32,
    rows: *mut u32,
) {
    if recording.is_null() || cols.is_null() || rows.is_null() {
        return;
    }
    let rec = unsafe { &*recording };
    unsafe {
        *cols = rec.cols();
        *rows = rec.rows();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_record_and_playback() {
        let mut rec = Recording::new(80, 24, "Claude", "/tmp/test");

        // Create a simple cell buffer
        let total = 80 * 24;
        let mut cells = vec![
            CCell {
                codepoint: 32,
                fg_r: 229,
                fg_g: 229,
                fg_b: 229,
                fg_a: 255,
                bg_r: 30,
                bg_g: 30,
                bg_b: 30,
                bg_a: 255,
                attrs: 0,
            };
            total
        ];

        // Frame 1: initial state
        rec.add_frame(&cells, 0, 0, true, vec![], 0);
        assert_eq!(rec.frame_count(), 1);

        // Frame 2: change a cell
        cells[0].codepoint = b'H' as u32;
        rec.add_frame(&cells, 0, 1, true, vec![], 100);
        assert_eq!(rec.frame_count(), 2);

        // Frame 3: identical — should be skipped
        rec.add_frame(&cells, 0, 1, true, vec![], 200);
        assert_eq!(rec.frame_count(), 2); // Still 2

        // Playback frame 2
        let (playback_cells, timestamp_ms, _cursor_row, cursor_col, _visible, _regions) =
            rec.get_frame_cells(1).unwrap();
        assert_eq!(playback_cells[0].codepoint, b'H' as u32);
        assert_eq!(timestamp_ms, 100);
        assert_eq!(cursor_col, 1);
    }

    #[test]
    fn test_save_and_load() {
        let mut rec = Recording::new(10, 5, "Claude", "/tmp/test");
        let total = 10 * 5;
        let mut cells = vec![
            CCell {
                codepoint: 32,
                fg_r: 229,
                fg_g: 229,
                fg_b: 229,
                fg_a: 255,
                bg_r: 30,
                bg_g: 30,
                bg_b: 30,
                bg_a: 255,
                attrs: 0,
            };
            total
        ];

        cells[5].codepoint = b'X' as u32;
        rec.add_frame(&cells, 2, 3, true, vec![], 0);
        cells[6].codepoint = b'Y' as u32;
        rec.add_frame(&cells, 2, 4, true, vec![], 500);

        let path = "/tmp/test_recording.awalrec";
        assert_eq!(rec.save(path), 0);

        let loaded = Recording::load(path).expect("Failed to load");
        assert_eq!(loaded.frame_count(), 2);
        assert_eq!(loaded.cols(), 10);
        assert_eq!(loaded.rows(), 5);

        let (loaded_cells, _, _, _, _, _) = loaded.get_frame_cells(1).unwrap();
        assert_eq!(loaded_cells[5].codepoint, b'X' as u32);
        assert_eq!(loaded_cells[6].codepoint, b'Y' as u32);

        std::fs::remove_file(path).ok();
    }
}
