//! Small system helpers: paths, the passwd database, files.

use std::fs;
use std::io::{self, Write};
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};

unsafe extern "C" {
    fn getuid() -> u32;
    fn kill(pid: i32, sig: i32) -> i32;
    fn prctl(option: i32, arg2: u64, arg3: u64, arg4: u64, arg5: u64) -> i32;
}

const PR_SET_PDEATHSIG: i32 = 1;

/// In a child between fork and exec: get SIGTERM when the parent dies, so a UI never outlives
/// its supervisor.
pub fn die_with_parent() -> io::Result<()> {
    // SAFETY: prctl(PR_SET_PDEATHSIG) only sets a flag on the calling process; async-signal-safe.
    if unsafe { prctl(PR_SET_PDEATHSIG, SIGTERM as u64, 0, 0, 0) } == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

pub const SIGTERM: i32 = 15;
pub const SIGKILL: i32 = 9;
const ESRCH: i32 = 3;

pub fn uid() -> u32 {
    // SAFETY: getuid has no preconditions and cannot fail.
    unsafe { getuid() }
}

/// Signal a process group (`pgid` > 0).
pub fn kill_group(pgid: u32, sig: i32) {
    if pgid > 0 && pgid <= i32::MAX as u32 {
        // SAFETY: plain syscall; a stale group just returns ESRCH.
        unsafe {
            kill(-(pgid as i32), sig);
        }
    }
}

/// Whether anything is left in a process group.
pub fn group_alive(pgid: u32) -> bool {
    if pgid == 0 || pgid > i32::MAX as u32 {
        return false;
    }
    // SAFETY: signal 0 only checks; ESRCH means the group is gone.
    let rc = unsafe { kill(-(pgid as i32), 0) };
    rc == 0 || io::Error::last_os_error().raw_os_error() != Some(ESRCH)
}

/// A line to the systemd journal (`journalctl -t hecate-greetd`), where it can be read back:
/// under greetd, stderr is the VT nobody sees, and the UI's supervisor runs with stderr
/// closed. Nothing happens without a journal.
pub fn journal(msg: &str) {
    let Ok(sock) = std::os::unix::net::UnixDatagram::unbound() else {
        return;
    };
    let mut payload = b"SYSLOG_IDENTIFIER=hecate-greetd\nPRIORITY=6\n".to_vec();
    // A message with newlines goes as a length-prefixed field (journal native protocol).
    if msg.contains('\n') {
        payload.extend_from_slice(b"MESSAGE\n");
        payload.extend_from_slice(&(msg.len() as u64).to_le_bytes());
        payload.extend_from_slice(msg.as_bytes());
        payload.push(b'\n');
    } else {
        payload.extend_from_slice(format!("MESSAGE={msg}\n").as_bytes());
    }
    let _ = sock.send_to(&payload, "/run/systemd/journal/socket");
}

pub fn env_or(key: &str, default: &str) -> String {
    std::env::var(key)
        .ok()
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| default.to_string())
}

/// Where greeter state and the users' exports live (`services.hecate-greetd.stateDir`).
pub fn state_dir() -> PathBuf {
    PathBuf::from(env_or("HECATE_GREETD_STATE_DIR", "/var/lib/hecate-greetd"))
}

pub fn users_dir() -> PathBuf {
    state_dir().join("users")
}

pub fn hecate_bin() -> String {
    env_or("HECATE_GREETD_HECATE", "hecate")
}

pub fn qs_bin() -> String {
    env_or("HECATE_GREETD_QS", "qs")
}

/// `$XDG_RUNTIME_DIR/<name>`, created 0700. Falls back to /tmp when there is no runtime dir.
pub fn runtime_dir(name: &str) -> io::Result<PathBuf> {
    let dir = match std::env::var_os("XDG_RUNTIME_DIR").map(PathBuf::from) {
        Some(base) if base.is_dir() => base.join(name),
        _ => PathBuf::from(format!("/tmp/{name}-{}", uid())),
    };
    fs::create_dir_all(&dir)?;
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o700))?;
    Ok(dir)
}

#[derive(Debug, Clone)]
pub struct Passwd {
    pub name: String,
    pub uid: u32,
    pub gecos: String,
    pub home: PathBuf,
    pub shell: String,
}

impl Passwd {
    /// The GECOS full name, else the login name.
    pub fn display_name(&self) -> String {
        let full = self.gecos.split(',').next().unwrap_or("").trim();
        if full.is_empty() {
            self.name.clone()
        } else {
            full.to_string()
        }
    }
}

pub fn read_passwd() -> Vec<Passwd> {
    let text = fs::read_to_string("/etc/passwd").unwrap_or_default();
    text.lines()
        .filter_map(|line| {
            let f: Vec<&str> = line.split(':').collect();
            if f.len() < 7 {
                return None;
            }
            Some(Passwd {
                name: f[0].to_string(),
                uid: f[2].parse().ok()?,
                gecos: f[4].to_string(),
                home: PathBuf::from(f[5]),
                shell: f[6].to_string(),
            })
        })
        .collect()
}

pub fn current_user() -> io::Result<Passwd> {
    let me = uid();
    read_passwd()
        .into_iter()
        .find(|p| p.uid == me)
        .ok_or_else(|| io::Error::other(format!("uid {me} is not in /etc/passwd")))
}

/// Write via a temporary file and rename, so readers never see half a file.
pub fn write_atomic(path: &Path, data: &[u8], mode: u32) -> io::Result<()> {
    let dir = path.parent().unwrap_or(Path::new("."));
    let tmp = dir.join(format!(
        ".{}.{}.tmp",
        path.file_name().and_then(|n| n.to_str()).unwrap_or("file"),
        std::process::id()
    ));
    {
        let mut f = fs::File::create(&tmp)?;
        f.write_all(data)?;
        f.sync_all()?;
    }
    fs::set_permissions(&tmp, fs::Permissions::from_mode(mode))?;
    fs::rename(&tmp, path)
}

pub fn write_json(path: &Path, value: &serde_json::Value, mode: u32) -> io::Result<()> {
    let mut text = serde_json::to_string_pretty(value).map_err(io::Error::other)?;
    text.push('\n');
    write_atomic(path, text.as_bytes(), mode)
}

/// Read a JSON file no bigger than `limit` bytes, without following a symlink at `path`.
pub fn read_json_limited(path: &Path, limit: u64) -> Option<serde_json::Value> {
    let meta = fs::symlink_metadata(path).ok()?;
    if !meta.is_file() || meta.len() > limit {
        return None;
    }
    serde_json::from_slice(&fs::read(path).ok()?).ok()
}

/// A directory (not a symlink) owned by `uid`.
pub fn is_owned_dir(path: &Path, uid: u32) -> bool {
    fs::symlink_metadata(path).is_ok_and(|m| m.is_dir() && m.uid() == uid)
}

/// Copy a tree, skipping symlinks, special files and files over `max_file` bytes.
pub fn copy_tree(from: &Path, to: &Path, max_file: u64, depth: u32) -> io::Result<()> {
    fs::create_dir_all(to)?;
    if depth == 0 {
        return Ok(());
    }
    for entry in fs::read_dir(from)? {
        let entry = entry?;
        let meta = entry.metadata()?; // DirEntry::metadata does not follow symlinks
        let dest = to.join(entry.file_name());
        if meta.is_dir() {
            copy_tree(&entry.path(), &dest, max_file, depth - 1)?;
        } else if meta.is_file() && meta.len() <= max_file {
            fs::copy(entry.path(), &dest)?;
            fs::set_permissions(&dest, fs::Permissions::from_mode(0o600))?;
        }
    }
    Ok(())
}

/// Percent-decode a `file://` URL path (`%20` and friends).
pub fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%'
            && i + 2 < bytes.len()
            && let Ok(b) =
                u8::from_str_radix(std::str::from_utf8(&bytes[i + 1..i + 3]).unwrap_or(""), 16)
        {
            out.push(b);
            i += 3;
            continue;
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8(out).unwrap_or_else(|_| s.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_percent() {
        assert_eq!(percent_decode("/a%20b/c.png"), "/a b/c.png");
        assert_eq!(percent_decode("/100%"), "/100%");
        assert_eq!(percent_decode("/x%2"), "/x%2");
    }
}
