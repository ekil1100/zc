//! Bounded reads, private dirfd-relative atomic writes, and process locks.
use std::{
    fs::File,
    io::{self, Read, Write},
    path::{Path, PathBuf},
    time::{Duration, Instant},
};

/// A directory sync error after visible rename does not imply rollback.
#[derive(Debug)]
pub struct WriteReceipt {
    pub durability_error: Option<io::Error>,
}

#[derive(Debug)]
pub struct SecureDir {
    file: File,
}

#[derive(Debug)]
pub struct FileLock {
    file: File,
}
impl FileLock {
    /// Verify that the held lock still names the same inode.
    pub fn validate(&self, dir: &SecureDir, name: &str) -> io::Result<()> {
        let current = dir.open_file(name, false, false)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt;
            let a = self.file.metadata()?;
            let b = current.metadata()?;
            if a.dev() != b.dev() || a.ino() != b.ino() {
                return Err(invalid("lock identity changed"));
            }
        }
        #[cfg(not(unix))]
        let _ = current;
        Ok(())
    }
}

fn invalid(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message)
}
pub fn single_component(name: &str) -> bool {
    !name.is_empty() && name != "." && name != ".." && !name.contains(['/', '\\', '\0'])
}
fn component(name: &str) -> io::Result<()> {
    if single_component(name) {
        Ok(())
    } else {
        Err(invalid("invalid storage path"))
    }
}
pub fn nonce() -> io::Result<String> {
    let mut bytes = [0; 16];
    getrandom::fill(&mut bytes).map_err(io::Error::other)?;
    Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
}

#[cfg(unix)]
fn check(file: &File, directory: bool, private: bool) -> io::Result<()> {
    check_metadata(&file.metadata()?, directory, private)
}
#[cfg(unix)]
fn check_metadata(m: &std::fs::Metadata, directory: bool, private: bool) -> io::Result<()> {
    use std::os::unix::fs::MetadataExt;
    if (directory && !m.is_dir()) || (!directory && !m.is_file()) {
        return Err(invalid("not a regular file or directory"));
    }
    if m.uid() != rustix::process::geteuid().as_raw() || (!directory && m.nlink() != 1) {
        return Err(invalid("unsafe file ownership or hard links"));
    }
    if private && m.mode() & 0o077 != 0 {
        return Err(invalid("permissions must be owner-only"));
    }
    Ok(())
}
#[cfg(not(unix))]
fn check(_: &File, _: bool, _: bool) -> io::Result<()> {
    Err(io::Error::new(
        io::ErrorKind::Unsupported,
        "secure filesystem operations require Unix",
    ))
}

impl SecureDir {
    pub fn open(path: impl AsRef<Path>) -> io::Result<Self> {
        #[cfg(unix)]
        {
            use rustix::fs::{Mode, OFlags, open};
            let file: File = open(
                path.as_ref(),
                OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
                Mode::empty(),
            )?
            .into();
            check(&file, true, true)?;
            Ok(Self { file })
        }
        #[cfg(not(unix))]
        {
            let _ = path;
            Err(io::Error::new(
                io::ErrorKind::Unsupported,
                "secure filesystem operations require Unix",
            ))
        }
    }
    /// Create a missing root; existing roots must be owned and private.
    pub fn create(path: impl AsRef<Path>) -> io::Result<Self> {
        let path = path.as_ref();
        if path.symlink_metadata().is_ok() {
            return Self::open(path);
        }
        let parent = path
            .parent()
            .filter(|p| !p.as_os_str().is_empty())
            .unwrap_or(Path::new("."));
        // Ancestors are not managed state: never chmod existing HOME or .config.
        std::fs::create_dir_all(parent)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::DirBuilderExt;
            match std::fs::DirBuilder::new().mode(0o700).create(path) {
                Ok(()) => (),
                Err(e) if e.kind() == io::ErrorKind::AlreadyExists => (),
                Err(e) => return Err(e),
            }
        }
        Self::open(path)
    }
    pub fn child(&self, name: &str, create: bool) -> io::Result<Self> {
        component(name)?;
        #[cfg(unix)]
        {
            use rustix::fs::{Mode, OFlags, mkdirat, openat};
            if create {
                match mkdirat(&self.file, name, Mode::from_raw_mode(0o700)) {
                    Ok(()) => self.sync()?,
                    Err(rustix::io::Errno::EXIST) => (),
                    Err(e) => return Err(e.into()),
                }
            }
            let file: File = openat(
                &self.file,
                name,
                OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
                Mode::empty(),
            )?
            .into();
            check(&file, true, true)?;
            Ok(Self { file })
        }
        #[cfg(not(unix))]
        {
            let _ = create;
            Err(io::Error::new(
                io::ErrorKind::Unsupported,
                "secure filesystem operations require Unix",
            ))
        }
    }
    fn open_file(&self, name: &str, write: bool, exclusive: bool) -> io::Result<File> {
        self.open_checked_file(name, write, exclusive, true)
    }
    fn open_checked_file(
        &self,
        name: &str,
        write: bool,
        exclusive: bool,
        private: bool,
    ) -> io::Result<File> {
        component(name)?;
        #[cfg(unix)]
        {
            use rustix::fs::{Mode, OFlags, openat};
            let mut flags = OFlags::NOFOLLOW | OFlags::NONBLOCK | OFlags::CLOEXEC;
            flags |= if write { OFlags::RDWR } else { OFlags::RDONLY };
            if exclusive {
                flags |= OFlags::EXCL | OFlags::CREATE;
            }
            let file: File = openat(&self.file, name, flags, Mode::from_raw_mode(0o600))?.into();
            check(&file, false, private)?;
            Ok(file)
        }
        #[cfg(not(unix))]
        {
            let _ = (write, exclusive);
            Err(io::Error::new(
                io::ErrorKind::Unsupported,
                "secure filesystem operations require Unix",
            ))
        }
    }
    pub fn read(&self, name: &str, limit: usize) -> io::Result<Vec<u8>> {
        read_bounded(self.open_file(name, false, false)?, limit, 0o077)
    }
    pub fn exists(&self, name: &str) -> io::Result<bool> {
        component(name)?;
        #[cfg(unix)]
        {
            match rustix::fs::statat(&self.file, name, rustix::fs::AtFlags::SYMLINK_NOFOLLOW) {
                Ok(_) => Ok(true),
                Err(rustix::io::Errno::NOENT) => Ok(false),
                Err(e) => Err(e.into()),
            }
        }
        #[cfg(not(unix))]
        {
            Err(io::Error::new(
                io::ErrorKind::Unsupported,
                "secure filesystem operations require Unix",
            ))
        }
    }
    pub fn sync(&self) -> io::Result<()> {
        self.file.sync_all()
    }
    pub fn write_new(&self, name: &str, bytes: &[u8]) -> io::Result<()> {
        let mut file = self.open_file(name, true, true)?;
        file.write_all(bytes)?;
        file.sync_all()
    }
    pub fn remove_file(&self, name: &str) -> io::Result<()> {
        component(name)?;
        #[cfg(unix)]
        {
            rustix::fs::unlinkat(&self.file, name, rustix::fs::AtFlags::empty()).map_err(Into::into)
        }
        #[cfg(not(unix))]
        {
            Err(io::Error::new(
                io::ErrorKind::Unsupported,
                "secure filesystem operations require Unix",
            ))
        }
    }
    /// Callers must hold the directory lock. Reject unverified destinations.
    pub fn atomic_write(&self, name: &str, bytes: &[u8]) -> io::Result<WriteReceipt> {
        self.atomic_write_checked(name, bytes, true)
    }
    fn atomic_write_checked(
        &self,
        name: &str,
        bytes: &[u8],
        private: bool,
    ) -> io::Result<WriteReceipt> {
        component(name)?;
        if self.exists(name)? {
            if private {
                self.open_file(name, false, false)?;
            } else {
                self.open_cache_file(name)?;
            }
        }
        let temp = format!(".write-{}", nonce()?);
        let result = (|| {
            self.write_new(&temp, bytes)?;
            self.rename(&temp, name)?;
            Ok(WriteReceipt {
                durability_error: self.sync().err(),
            })
        })();
        let _ = self.remove_file(&temp);
        result
    }
    /// Atomically install a new immutable file without replacing any destination.
    pub fn install_new(&self, name: &str, bytes: &[u8]) -> io::Result<WriteReceipt> {
        component(name)?;
        let temp = format!(".install-{}", nonce()?);
        let result = (|| {
            self.write_new(&temp, bytes)?;
            #[cfg(unix)]
            {
                rustix::fs::linkat(
                    &self.file,
                    &temp,
                    &self.file,
                    name,
                    rustix::fs::AtFlags::empty(),
                )?;
                self.remove_file(&temp)?;
                Ok(WriteReceipt {
                    durability_error: self.sync().err(),
                })
            }
            #[cfg(not(unix))]
            {
                Err(io::Error::new(
                    io::ErrorKind::Unsupported,
                    "secure filesystem operations require Unix",
                ))
            }
        })();
        let _ = self.remove_file(&temp);
        result
    }
    /// Same-directory rename. Directory publishers must lock and check absence.
    pub fn rename(&self, from: &str, to: &str) -> io::Result<()> {
        component(from)?;
        component(to)?;
        #[cfg(unix)]
        {
            rustix::fs::renameat(&self.file, from, &self.file, to).map_err(Into::into)
        }
        #[cfg(not(unix))]
        {
            Err(io::Error::new(
                io::ErrorKind::Unsupported,
                "secure filesystem operations require Unix",
            ))
        }
    }
    pub fn lock(&self, name: &str, timeout: Duration) -> io::Result<FileLock> {
        let start = Instant::now();
        // Match Zig's stable-inode protocol: create exclusively, close, then open.
        // On APFS, simultaneous O_CREAT opens can otherwise report ENOENT.
        let file = loop {
            match self.open_file(name, true, false) {
                Ok(file) => break file,
                Err(e) if e.kind() == io::ErrorKind::NotFound => {
                    match self.open_file(name, true, true) {
                        Ok(created) => {
                            created.sync_all()?;
                            self.sync()?;
                        }
                        Err(e) if e.kind() == io::ErrorKind::AlreadyExists => (),
                        Err(e) => return Err(e),
                    }
                    if start.elapsed() >= timeout {
                        return Err(io::Error::new(
                            io::ErrorKind::TimedOut,
                            "storage lock creation deadline exceeded",
                        ));
                    }
                }
                Err(e) => return Err(e),
            }
        };
        loop {
            match file.try_lock() {
                Ok(()) => break,
                Err(std::fs::TryLockError::WouldBlock) if start.elapsed() < timeout => {
                    std::thread::sleep(
                        Duration::from_millis(5).min(timeout.saturating_sub(start.elapsed())),
                    )
                }
                Err(std::fs::TryLockError::WouldBlock) => {
                    return Err(io::Error::new(
                        io::ErrorKind::TimedOut,
                        "storage lock deadline exceeded",
                    ));
                }
                Err(std::fs::TryLockError::Error(e)) => return Err(e),
            }
        }
        let guard = FileLock { file };
        guard.validate(self, name)?;
        Ok(guard)
    }
}

fn read_bounded(file: File, limit: usize, forbidden_permissions: u32) -> io::Result<Vec<u8>> {
    let before = file.metadata()?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        // Validate the capture snapshot itself, not an earlier checked-open stat.
        check_metadata(&before, false, false)?;
        if before.mode() & forbidden_permissions != 0 {
            return Err(invalid("unsafe file permissions during capture"));
        }
    }
    if before.len() > limit as u64 {
        return Err(invalid("file exceeds byte limit"));
    }
    let mut result = Vec::new();
    (&file).take(limit as u64 + 1).read_to_end(&mut result)?;
    let after = file.metadata()?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if before.ctime() != after.ctime()
            || before.ctime_nsec() != after.ctime_nsec()
            || before.nlink() != after.nlink()
            || before.uid() != after.uid()
            || before.mode() != after.mode()
        {
            return Err(invalid("file metadata changed during capture"));
        }
    }
    if result.len() > limit
        || result.len() as u64 != after.len()
        || before.len() != after.len()
        || before.modified()? != after.modified()?
    {
        return Err(invalid("file too large or changed during capture"));
    }
    Ok(result)
}

/// Read a caller-supplied path with a no-follow, nonblocking final open.
pub fn read_regular(path: impl AsRef<Path>, limit: usize) -> io::Result<Vec<u8>> {
    #[cfg(unix)]
    {
        use rustix::fs::{Mode, OFlags, open};
        let file: File = open(
            path.as_ref(),
            OFlags::RDONLY | OFlags::NOFOLLOW | OFlags::NONBLOCK | OFlags::CLOEXEC,
            Mode::empty(),
        )?
        .into();
        check(&file, false, false)?;
        read_bounded(file, limit, 0)
    }
    #[cfg(not(unix))]
    {
        let _ = (path, limit);
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "secure filesystem operations require Unix",
        ))
    }
}

/// Resolve inside a fixed root, rejecting intermediate escapes; return target and bytes.
pub fn read_contained(root: &Path, logical: &str, limit: usize) -> io::Result<(String, Vec<u8>)> {
    #[cfg(unix)]
    {
        use rustix::fs::{Mode, OFlags, open, openat, readlinkat};
        use std::{collections::VecDeque, os::unix::ffi::OsStrExt};
        if logical.is_empty() || logical.contains('\0') {
            return Err(invalid("invalid asset path"));
        }
        let root_path = root.canonicalize()?;
        let input = Path::new(logical);
        let relative = if input.is_absolute() {
            input
                .strip_prefix(&root_path)
                .map_err(|_| invalid("asset outside source root"))?
        } else {
            input
        };
        let root_file: File = open(
            &root_path,
            OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
            Mode::empty(),
        )?
        .into();
        let mut dirs = vec![root_file];
        let mut names = Vec::<String>::new();
        let mut pending: VecDeque<String> = relative
            .to_str()
            .ok_or_else(|| invalid("non-UTF8 asset path"))?
            .split('/')
            .map(str::to_owned)
            .collect();
        let mut hops = 0;
        let mut steps = 0;
        while let Some(part) = pending.pop_front() {
            steps += 1;
            if steps > 163840 {
                return Err(invalid("asset path walk limit exceeded"));
            }
            match part.as_str() {
                "" | "." => continue,
                ".." => {
                    if dirs.len() == 1 {
                        return Err(invalid("asset outside source root"));
                    }
                    dirs.pop();
                    names.pop();
                    continue;
                }
                _ => (),
            }
            let parent = dirs.last().expect("root directory");
            // readlinkat never follows the link. The eventual open still uses NOFOLLOW.
            if let Ok(target) = readlinkat(parent, part.as_str(), Vec::new()) {
                hops += 1;
                let hop_limit = if cfg!(target_os = "linux") { 40 } else { 32 };
                if hops > hop_limit {
                    return Err(invalid("too many asset symlinks"));
                }
                let target = std::str::from_utf8(target.to_bytes())
                    .map_err(|_| invalid("non-UTF8 symlink"))?;
                let target = if Path::new(target).is_absolute() {
                    let rel = Path::new(target)
                        .strip_prefix(&root_path)
                        .map_err(|_| invalid("asset symlink outside source root"))?;
                    dirs.truncate(1);
                    names.clear();
                    std::str::from_utf8(rel.as_os_str().as_bytes())
                        .map_err(|_| invalid("non-UTF8 symlink"))?
                } else {
                    target
                };
                for piece in target.split('/').rev() {
                    pending.push_front(piece.to_owned());
                }
                continue;
            }
            let last = pending.is_empty();
            let flags = OFlags::RDONLY
                | OFlags::NOFOLLOW
                | OFlags::NONBLOCK
                | OFlags::CLOEXEC
                | if last {
                    OFlags::empty()
                } else {
                    OFlags::DIRECTORY
                };
            let file: File = openat(parent, part.as_str(), flags, Mode::empty())?.into();
            names.push(part);
            if last {
                check(&file, false, false)?;
                return Ok((names.join("/"), read_bounded(file, limit, 0)?));
            }
            dirs.push(file);
        }
        Err(invalid("asset is not a regular file"))
    }
    #[cfg(not(unix))]
    {
        let _ = (root, logical, limit);
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "secure filesystem operations require Unix",
        ))
    }
}

/// Zig default location; this function performs no filesystem I/O.
pub fn default_store_root() -> io::Result<PathBuf> {
    std::env::var_os("HOME")
        .filter(|v| !v.is_empty())
        .map(|v| PathBuf::from(v).join(".config/zc"))
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "HOME is not configured"))
}

impl FileLock {
    /// Duplicate the same open description for safe stdin-based exec handoff.
    pub fn inherited_file(&self) -> io::Result<File> {
        self.file.try_clone()
    }
    pub fn from_inherited(file: File, dir: &SecureDir, name: &str) -> io::Result<Self> {
        check(&file, false, true)?;
        let lock = Self { file };
        lock.validate(dir, name)?;
        // A separately opened descriptor must conflict with the inherited lock.
        match dir.open_file(name, true, false)?.try_lock() {
            Err(std::fs::TryLockError::WouldBlock) => Ok(lock),
            _ => Err(invalid("inherited file does not hold the daemon lock")),
        }
    }
    pub fn write_contents(&self, bytes: &[u8]) -> io::Result<()> {
        use std::os::unix::fs::FileExt;
        self.file.set_len(0)?;
        self.file.write_all_at(bytes, 0)?;
        self.file.sync_all()
    }
}
impl SecureDir {
    /// Walk an absolute canonical path without following any symlink component.
    pub fn open_owned_absolute(path: &Path, private: bool) -> io::Result<Self> {
        use rustix::fs::{Mode, OFlags, open, openat};
        use std::os::unix::fs::MetadataExt;
        let text = path.to_str().ok_or_else(|| invalid("non-UTF8 directory"))?;
        if !path.is_absolute()
            || text
                .split('/')
                .skip(1)
                .any(|v| v.is_empty() || v == "." || v == "..")
        {
            return Err(invalid("directory path must be absolute and canonical"));
        }
        let flags = OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC;
        let mut file: File = open("/", flags, Mode::empty())?.into();
        for part in text.split('/').skip(1) {
            file = openat(&file, part, flags, Mode::empty())?.into();
        }
        check(&file, true, private)?;
        let mode = file.metadata()?.mode() & 0o777;
        if (private && mode != 0o700) || (!private && mode & 0o022 != 0) {
            return Err(invalid("unsafe directory permissions"));
        }
        Ok(Self { file })
    }
    /// Owned fallback ancestors may be searchable, but never group/other writable.
    pub fn owned_child(&self, name: &str, create: bool, private: bool) -> io::Result<Self> {
        use rustix::fs::{Mode, OFlags, mkdirat, openat};
        use std::os::unix::fs::MetadataExt;
        component(name)?;
        if create {
            match mkdirat(&self.file, name, Mode::from_raw_mode(0o700)) {
                Ok(()) => self.sync()?,
                Err(rustix::io::Errno::EXIST) => (),
                Err(e) => return Err(e.into()),
            }
        }
        let file: File = openat(
            &self.file,
            name,
            OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
            Mode::empty(),
        )?
        .into();
        check(&file, true, private)?;
        let mode = file.metadata()?.mode() & 0o777;
        if (private && mode != 0o700) || mode & 0o022 != 0 {
            return Err(invalid("unsafe directory permissions"));
        }
        Ok(Self { file })
    }
    pub fn validate_path(&self, path: &Path) -> io::Result<()> {
        use std::os::unix::fs::MetadataExt;
        let current = Self::open_owned_absolute(path, true)?;
        let a = self.file.metadata()?;
        let b = current.file.metadata()?;
        if a.dev() != b.dev() || a.ino() != b.ino() {
            return Err(invalid("directory identity changed"));
        }
        Ok(())
    }
    /// Capture bytes and identity from one verified open, even across log rotation.
    pub fn read_with_metadata(
        &self,
        name: &str,
        limit: usize,
    ) -> io::Result<(Vec<u8>, std::fs::Metadata)> {
        let file = self.open_file(name, false, false)?;
        let metadata = file.metadata()?;
        let bytes = read_bounded(file, limit, 0o077)?;
        Ok((bytes, metadata))
    }
    pub fn file_metadata(&self, name: &str) -> io::Result<std::fs::Metadata> {
        self.open_file(name, false, false)?.metadata()
    }
    pub fn append_bounded(&self, name: &str, bytes: &[u8], limit: usize) -> io::Result<()> {
        if bytes.len() > limit {
            return Err(invalid("log record exceeds limit"));
        }
        let mut file = match self.open_file(name, true, false) {
            Ok(file) => file,
            Err(e) if e.kind() == io::ErrorKind::NotFound => self.open_file(name, true, true)?,
            Err(e) => return Err(e),
        };
        if file.metadata()?.len() + bytes.len() as u64 > limit as u64 {
            self.atomic_write(name, bytes)?;
        } else {
            use std::io::{Seek, SeekFrom};
            file.seek(SeekFrom::End(0))?;
            file.write_all(bytes)?;
        }
        Ok(())
    }
}

impl SecureDir {
    /// Hold a source identity relative to the already held cache root.
    /// Source permissions are not cache permissions.
    pub fn hold_cache_source(&self, name: &str) -> io::Result<File> {
        self.open_checked_file(name, false, false, false)
    }
    fn open_cache_file(&self, name: &str) -> io::Result<File> {
        use std::os::unix::fs::MetadataExt;
        let file = self.open_checked_file(name, false, false, false)?;
        if file.metadata()?.mode() & 0o022 != 0 {
            return Err(invalid("cache must not be group/other writable"));
        }
        Ok(file)
    }
    /// Existing caches may be publicly readable, but must be owned, single-link
    /// regular files with no group/other POSIX write bits (not an ACL guarantee).
    /// Opens never follow links or block on FIFOs.
    pub fn cache_metadata(&self, name: &str) -> io::Result<std::fs::Metadata> {
        self.open_cache_file(name)?.metadata()
    }
    pub fn read_cache(&self, name: &str, limit: usize) -> io::Result<Vec<u8>> {
        read_bounded(self.open_cache_file(name)?, limit, 0o022)
    }
    /// Caller holds the directory lock. New bytes are always owner-only.
    pub fn write_cache(&self, name: &str, bytes: &[u8]) -> io::Result<WriteReceipt> {
        self.atomic_write_checked(name, bytes, false)
    }
}
