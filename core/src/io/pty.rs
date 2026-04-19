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
    /// If `command` is Some, the shell is invoked with `-l -c "command"` (login + command).
    pub fn spawn(
        shell: &str,
        cols: u16,
        rows: u16,
        env_vars: &[(&str, &str)],
    ) -> Result<Self, Box<dyn std::error::Error>> {
        Self::spawn_inner(shell, cols, rows, env_vars, None)
    }

    /// Spawn with an initial command to execute.
    pub fn spawn_with_command(
        shell: &str,
        cols: u16,
        rows: u16,
        env_vars: &[(&str, &str)],
        command: &str,
    ) -> Result<Self, Box<dyn std::error::Error>> {
        Self::spawn_inner(shell, cols, rows, env_vars, Some(command))
    }

    fn spawn_inner(
        shell: &str,
        cols: u16,
        rows: u16,
        env_vars: &[(&str, &str)],
        command: Option<&str>,
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

                if dup2(slave.as_fd(), &mut stdin_fd).is_err()
                    || dup2(slave.as_fd(), &mut stdout_fd).is_err()
                    || dup2(slave.as_fd(), &mut stderr_fd).is_err()
                {
                    unsafe { libc::_exit(1) };
                }

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

                // Remove Claude Code env vars so nested sessions work
                std::env::remove_var("CLAUDECODE");
                std::env::remove_var("CLAUDE_CODE_ENTRYPOINT");

                // Execute the shell — use _exit(1) on failure since we're in a
                // forked child where panic/unwrap would crash silently.
                let shell_cstr = match CString::new(shell) {
                    Ok(s) => s,
                    Err(_) => unsafe { libc::_exit(1) },
                };
                let base = shell.rsplit('/').next().unwrap_or(shell);
                let login_arg = match CString::new(format!("-{}", base)) {
                    Ok(s) => s,
                    Err(_) => unsafe { libc::_exit(1) },
                };
                #[allow(unreachable_code)]
                {
                    if let Some(cmd) = command {
                        // Use interactive (-i) login (-l) shell so user rc files
                        // (e.g. ~/.zshrc) get sourced — needed for tools like
                        // fnm/nvm/asdf that put node/npm on PATH from .zshrc.
                        let i_flag = match CString::new("-i") {
                            Ok(s) => s,
                            Err(_) => unsafe { libc::_exit(1) },
                        };
                        let c_flag = match CString::new("-c") {
                            Ok(s) => s,
                            Err(_) => unsafe { libc::_exit(1) },
                        };
                        let c_cmd = match CString::new(cmd) {
                            Ok(s) => s,
                            Err(_) => unsafe { libc::_exit(1) },
                        };
                        let _ = execvp(&shell_cstr, &[login_arg, i_flag, c_flag, c_cmd]);
                    } else {
                        let _ = execvp(&shell_cstr, &[login_arg]);
                    }
                    // execvp only returns on failure
                    unsafe { libc::_exit(1) };
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
        let result = unsafe { libc::ioctl(fd, libc::TIOCSWINSZ as _, &winsize as *const Winsize) };
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

impl Drop for Pty {
    fn drop(&mut self) {
        use nix::sys::signal::{kill, Signal};
        use nix::sys::wait::{waitpid, WaitPidFlag};

        let pid = self.child_pid;

        // Send SIGHUP (hangup) to the child process group
        let _ = kill(pid, Signal::SIGHUP);

        // Reap in background thread to avoid blocking the main thread
        std::thread::spawn(move || {
            // Try non-blocking reap
            if let Ok(nix::sys::wait::WaitStatus::StillAlive) =
                waitpid(pid, Some(WaitPidFlag::WNOHANG))
            {
                // Give it a brief moment, then force-kill
                std::thread::sleep(std::time::Duration::from_millis(50));
                if let Ok(nix::sys::wait::WaitStatus::StillAlive) =
                    waitpid(pid, Some(WaitPidFlag::WNOHANG))
                {
                    let _ = kill(pid, Signal::SIGKILL);
                    let _ = waitpid(pid, None); // blocking reap
                }
            }
        });
    }
}

use std::os::fd::FromRawFd;
