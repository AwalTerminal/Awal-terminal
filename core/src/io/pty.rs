use nix::pty::{openpty, OpenptyResult, Winsize};
use nix::unistd::{dup2, execvp, fork, read, setsid, write, ForkResult};
use std::ffi::CString;
use std::os::fd::{AsFd, AsRawFd, OwnedFd, RawFd};

pub struct Pty {
    pub master: OwnedFd,
    pub child_pid: nix::unistd::Pid,
}

impl Pty {
    /// Open a new PTY and spawn a shell process.
    pub fn spawn(
        shell: &str,
        cols: u16,
        rows: u16,
        env_vars: &[(&str, &str)],
    ) -> Result<Self, Box<dyn std::error::Error>> {
        let winsize = Winsize {
            ws_row: rows,
            ws_col: cols,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };

        let OpenptyResult { master, slave } = openpty(&winsize, None)?;

        let slave_raw = slave.as_raw_fd();

        match unsafe { fork()? } {
            ForkResult::Child => {
                // Close master in child
                drop(master);

                // Create a new session
                setsid().ok();

                // Set controlling terminal
                unsafe {
                    libc::ioctl(slave_raw, libc::TIOCSCTTY as _, 0);
                }

                // Redirect stdio to the slave PTY
                // We need OwnedFds for stdin/stdout/stderr
                let mut stdin_fd = unsafe { OwnedFd::from_raw_fd(libc::STDIN_FILENO) };
                let mut stdout_fd = unsafe { OwnedFd::from_raw_fd(libc::STDOUT_FILENO) };
                let mut stderr_fd = unsafe { OwnedFd::from_raw_fd(libc::STDERR_FILENO) };

                dup2(slave.as_fd(), &mut stdin_fd).unwrap();
                dup2(slave.as_fd(), &mut stdout_fd).unwrap();
                dup2(slave.as_fd(), &mut stderr_fd).unwrap();

                // Forget the OwnedFds so they don't close stdin/stdout/stderr
                std::mem::forget(stdin_fd);
                std::mem::forget(stdout_fd);
                std::mem::forget(stderr_fd);

                if slave_raw > 2 {
                    drop(slave);
                }

                // Set environment variables
                for (key, value) in env_vars {
                    std::env::set_var(key, value);
                }
                std::env::set_var("TERM", "xterm-256color");
                std::env::set_var("COLORTERM", "truecolor");

                // Execute the shell
                let shell_cstr = CString::new(shell).unwrap();
                let login_arg = CString::new(format!(
                    "-{}",
                    shell.rsplit('/').next().unwrap_or(shell)
                ))
                .unwrap();
                #[allow(unreachable_code)]
                {
                    execvp(&shell_cstr, &[login_arg]).expect("execvp failed");
                    unreachable!();
                }
            }
            ForkResult::Parent { child } => {
                // Close slave in parent
                drop(slave);

                // Make master non-blocking
                let master_raw = master.as_raw_fd();
                let flags = unsafe { libc::fcntl(master_raw, libc::F_GETFL) };
                unsafe { libc::fcntl(master_raw, libc::F_SETFL, flags | libc::O_NONBLOCK) };

                Ok(Pty {
                    master,
                    child_pid: child,
                })
            }
        }
    }

    /// Read available bytes from the PTY master.
    pub fn read(&self, buf: &mut [u8]) -> Result<usize, nix::Error> {
        read(self.master.as_fd(), buf)
    }

    /// Write bytes to the PTY master (input to the child process).
    pub fn write(&self, data: &[u8]) -> Result<usize, nix::Error> {
        write(&self.master, data)
    }

    /// Resize the PTY.
    pub fn resize(&self, cols: u16, rows: u16) -> Result<(), nix::Error> {
        let winsize = Winsize {
            ws_row: rows,
            ws_col: cols,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        let fd = self.master.as_raw_fd();
        let result = unsafe {
            libc::ioctl(fd, libc::TIOCSWINSZ as _, &winsize as *const Winsize)
        };
        if result == -1 {
            Err(nix::Error::last())
        } else {
            Ok(())
        }
    }

    pub fn master_fd(&self) -> RawFd {
        self.master.as_raw_fd()
    }
}

use std::os::fd::FromRawFd;
