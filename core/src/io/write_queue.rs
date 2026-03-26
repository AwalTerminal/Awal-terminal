use std::collections::VecDeque;

/// A queue of pending PTY writes with partial-write tracking.
pub struct WriteQueue {
    queue: VecDeque<Vec<u8>>,
    /// Byte offset into the front chunk (for partial writes).
    offset: usize,
}

impl Default for WriteQueue {
    fn default() -> Self {
        Self::new()
    }
}

impl WriteQueue {
    pub fn new() -> Self {
        WriteQueue {
            queue: VecDeque::new(),
            offset: 0,
        }
    }

    /// Push data onto the write queue.
    pub fn push(&mut self, data: &[u8]) {
        if !data.is_empty() {
            self.queue.push_back(data.to_vec());
        }
    }

    /// Check if there is pending data.
    pub fn has_pending(&self) -> bool {
        !self.queue.is_empty()
    }

    /// Drain the queue by writing to the given fd.
    /// Returns total bytes written, or -1 on hard error.
    /// Stops on WouldBlock and preserves remaining data.
    pub fn drain(&mut self, fd: std::os::fd::RawFd) -> i32 {
        let mut total: i32 = 0;

        while let Some(chunk) = self.queue.front() {
            let remaining = &chunk[self.offset..];
            if remaining.is_empty() {
                self.queue.pop_front();
                self.offset = 0;
                continue;
            }

            match nix::unistd::write(
                unsafe { std::os::fd::BorrowedFd::borrow_raw(fd) },
                remaining,
            ) {
                Ok(n) => {
                    total += n as i32;
                    self.offset += n;
                    if self.offset >= chunk.len() {
                        self.queue.pop_front();
                        self.offset = 0;
                    }
                }
                Err(nix::Error::EAGAIN) => {
                    // PTY buffer full — stop, we'll resume when writable
                    break;
                }
                Err(_) => {
                    return -1;
                }
            }
        }

        total
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn new_queue_has_no_pending() {
        let q = WriteQueue::new();
        assert!(!q.has_pending());
    }

    #[test]
    fn default_queue_has_no_pending() {
        let q = WriteQueue::default();
        assert!(!q.has_pending());
    }

    #[test]
    fn push_makes_pending() {
        let mut q = WriteQueue::new();
        q.push(b"hello");
        assert!(q.has_pending());
    }

    #[test]
    fn push_empty_data_is_ignored() {
        let mut q = WriteQueue::new();
        q.push(b"");
        assert!(!q.has_pending());
    }

    #[test]
    fn push_multiple_chunks() {
        let mut q = WriteQueue::new();
        q.push(b"one");
        q.push(b"two");
        q.push(b"three");
        assert!(q.has_pending());
    }

    #[test]
    fn push_preserves_data_order() {
        let mut q = WriteQueue::new();
        q.push(b"first");
        q.push(b"second");
        // Verify the front chunk is "first"
        assert_eq!(q.queue.front().unwrap(), b"first");
        assert_eq!(q.queue.back().unwrap(), b"second");
    }

    #[test]
    fn push_single_byte() {
        let mut q = WriteQueue::new();
        q.push(&[0x42]);
        assert!(q.has_pending());
        assert_eq!(q.queue.front().unwrap(), &[0x42]);
    }

    #[test]
    fn push_large_data() {
        let mut q = WriteQueue::new();
        let big = vec![0xAA; 65536];
        q.push(&big);
        assert!(q.has_pending());
        assert_eq!(q.queue.front().unwrap().len(), 65536);
    }
}
