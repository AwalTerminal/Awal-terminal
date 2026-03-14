use std::collections::VecDeque;

/// A queue of pending PTY writes with partial-write tracking.
pub struct WriteQueue {
    queue: VecDeque<Vec<u8>>,
    /// Byte offset into the front chunk (for partial writes).
    offset: usize,
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
