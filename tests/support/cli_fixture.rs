//! Isolate independent CLI fixtures from macOS socket/CLOEXEC spawn races.
use std::sync::{Mutex, MutexGuard};

/// Hold until child processes, sockets and temporary directories are dropped.
/// Concurrency being tested must remain explicit inside the guarded fixture.
pub fn serial() -> MutexGuard<'static, ()> {
    static FIXTURES: Mutex<()> = Mutex::new(());
    FIXTURES.lock().unwrap_or_else(|error| error.into_inner())
}
