//! A user's export: what the login screen takes from them.
//!
//! The login screen looks the same for everyone: hecate's blobs and the haiiro kit. What comes
//! along per user is their keyboard and monitor layout and their avatar. The greeter can't
//! read home directories, so `hecate-greetd sync` (run by the user's shell) copies those into
//! `<state>/users/<user>/`, a directory the user owns and the `greeter` group can read (setgid,
//! created by the NixOS module):
//!
//! ```text
//! users/<user>/
//!   current -> home-<time>      the latest snapshot, swapped atomically
//!   home-<time>/
//!     .face                     avatar
//!     compositor.json           hecate settings for the login screen (outputs, keyboard, ...)
//!     manifest.json
//!   blobs.json                  where the session's hecate left its blobs, written by hecate
//!                               itself (`background.blobs.save`) when it exits, which the
//!                               login screen carries on from after a logout
//! ```
//!
//! Everything in there is the user's to write, so the greeter treats it as untrusted: it checks
//! ownership, never follows symlinks, caps sizes and only takes a few compositor tables.

use std::fs;
use std::io;
use std::os::unix::fs::{MetadataExt, PermissionsExt, symlink};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{Map, Value, json};

use crate::sys::{self, Passwd};

/// Compositor tables the login screen takes from a user: where their monitors are and how
/// their keyboard and pointer are set up. How it looks is not theirs to say (the blobs run
/// for everyone), and anything else (autostart, binds, environment, rules) could run commands
/// as the greeter, so it never gets through.
pub const COMPOSITOR_KEYS_DISPLAYS: &[&str] = &["outputs"];
pub const COMPOSITOR_KEYS_INPUT: &[&str] = &["keyboard", "input", "cursor"];

const MAX_SMALL: u64 = 4 << 20;
/// A few kilobytes per monitor; anything bigger isn't hecate's.
const MAX_BLOBS: u64 = 1 << 20;

/// What earlier versions kept in an export (wallpapers and desktop pictures).
const LEGACY_DIRS: &[&str] = &["files", "splash"];

pub fn export_dir(user: &str) -> PathBuf {
    sys::users_dir().join(user)
}

fn now() -> (u64, u32) {
    let d = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    (d.as_secs(), d.subsec_nanos())
}

// ---------------------------------------------------------------------------------------------
// Reading an export (greeter side)

/// The user's current snapshot, if the export exists and is really theirs.
pub fn snapshot(user: &Passwd) -> Option<PathBuf> {
    let dir = export_dir(&user.name);
    if !sys::is_owned_dir(&dir, user.uid) {
        return None;
    }
    let target = fs::read_link(dir.join("current")).ok()?;
    let name = target.to_str()?;
    // Only a sibling `home-<digits>` directory, nothing that points elsewhere.
    let digits = name.strip_prefix("home-")?;
    if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let snap = dir.join(name);
    sys::is_owned_dir(&snap, user.uid).then_some(snap)
}

/// The avatar in a snapshot, as a path the greeter can load.
pub fn avatar(snap: &Path) -> Option<PathBuf> {
    [".face", ".face.icon"]
        .iter()
        .map(|n| snap.join(n))
        .find(|p| {
            fs::symlink_metadata(p)
                .is_ok_and(|m| m.is_file() && m.len() > 0 && m.len() <= MAX_SMALL)
        })
}

/// The user's compositor settings, reduced to the tables the login screen accepts.
pub fn compositor_fragment(snap: &Path) -> Value {
    let Some(Value::Object(map)) = sys::read_json_limited(&snap.join("compositor.json"), 1 << 20)
    else {
        return json!({});
    };
    let allowed: Vec<&str> = COMPOSITOR_KEYS_DISPLAYS
        .iter()
        .chain(COMPOSITOR_KEYS_INPUT)
        .copied()
        .collect();
    Value::Object(
        map.into_iter()
            .filter(|(k, v)| allowed.contains(&k.as_str()) && v.is_object())
            .collect(),
    )
}

/// Where the user's session left its blobs (hecate's `background.blobs.save`, pointed here by
/// their config), if the file is really theirs and looks like what hecate writes.
pub fn session_blobs(user: &Passwd) -> Option<Value> {
    blobs_in(&export_dir(&user.name), user.uid)
}

fn blobs_in(dir: &Path, uid: u32) -> Option<Value> {
    if !sys::is_owned_dir(dir, uid) {
        return None;
    }
    let path = dir.join("blobs.json");
    let meta = fs::symlink_metadata(&path).ok()?;
    if !meta.is_file() || meta.uid() != uid {
        return None;
    }
    sys::read_json_limited(&path, MAX_BLOBS).filter(|v| v["outputs"].is_array())
}

// ---------------------------------------------------------------------------------------------
// Writing an export (user side): `hecate-greetd sync`

fn xdg(var: &str, home: &Path, fallback: &str) -> PathBuf {
    std::env::var_os(var)
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .unwrap_or_else(|| home.join(fallback))
}

fn not_set_up(dir: &Path, user: &str) -> io::Error {
    io::Error::other(format!(
        "{} isn't set up for {user}. Enable services.hecate-greetd on NixOS (it creates it for every normal user), or create it: sudo install -d -m 2750 -o {user} -g greeter {}",
        dir.display(),
        dir.display()
    ))
}

pub fn sync() -> io::Result<Value> {
    let me = sys::current_user()?;
    let dir = export_dir(&me.name);
    if !sys::is_owned_dir(&dir, me.uid) {
        return Err(not_set_up(&dir, &me.name));
    }

    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| me.home.clone());
    let config_home = xdg("XDG_CONFIG_HOME", &home, ".config");

    // The shell's switches: share at all, and which of the two layouts.
    let shell_config_path = config_home.join("illogical-impulse/config.json");
    let shell_config = sys::read_json_limited(&shell_config_path, MAX_SMALL)
        .filter(Value::is_object)
        .unwrap_or_else(|| json!({}));
    let greeter = shell_config.get("greeter").cloned().unwrap_or(json!({}));
    let flag = |key: &str| greeter.get(key).and_then(Value::as_bool).unwrap_or(true);

    if !flag("share") {
        clear(&dir)?;
        let status = json!({ "shared": false, "user": me.name, "synced_at": now().0 });
        sys::write_json(&dir.join("manifest.json"), &status, 0o640)?;
        return Ok(status);
    }

    let (secs, nanos) = now();
    let snap_name = format!("home-{secs}{nanos:09}");
    let snap = dir.join(&snap_name);
    let result = (|| -> io::Result<Value> {
        fs::create_dir_all(&snap)?;

        let mut avatar = false;
        for face in [".face", ".face.icon"] {
            let src = home.join(face);
            if fs::metadata(&src).is_ok_and(|m| m.is_file() && m.len() <= MAX_SMALL) {
                copy_readable(&src, &snap.join(face))?;
                avatar = true;
                break;
            }
        }

        // hecate settings from the running compositor (Nix config + the shell's hecate page).
        let mut keys: Vec<&str> = Vec::new();
        if flag("displays") {
            keys.extend(COMPOSITOR_KEYS_DISPLAYS);
        }
        if flag("input") {
            keys.extend(COMPOSITOR_KEYS_INPUT);
        }
        let compositor = match running_compositor_config() {
            Some(cfg) => pick(&cfg, &keys),
            // Not in a hecate session (a TTY, ssh): keep what the last sync found.
            None => snapshot(&me)
                .map(|old| pick(&compositor_fragment(&old), &keys))
                .unwrap_or_else(|| json!({})),
        };
        sys::write_json(&snap.join("compositor.json"), &compositor, 0o640)?;

        let outputs: Vec<String> = compositor
            .get("outputs")
            .and_then(Value::as_object)
            .map(|o| o.keys().cloned().collect())
            .unwrap_or_default();
        let status = json!({
            "shared": true,
            "user": me.name,
            "synced_at": secs,
            "files": u32::from(avatar),
            "avatar": avatar,
            "outputs": outputs,
            "keyboard": compositor.get("keyboard").and_then(|k| k.get("layout")).cloned().unwrap_or(Value::Null),
        });
        sys::write_json(&snap.join("manifest.json"), &status, 0o640)?;
        set_tree_perms(&snap)?;

        // Swap `current` over to the new snapshot in one rename.
        let tmp_link = dir.join(format!(".current.{}", std::process::id()));
        let _ = fs::remove_file(&tmp_link);
        symlink(&snap_name, &tmp_link)?;
        fs::rename(&tmp_link, dir.join("current"))?;

        prune(&dir, &snap_name);
        Ok(status)
    })();

    if result.is_err() {
        let _ = fs::remove_dir_all(&snap);
    }
    result
}

/// Stop sharing: remove everything but the directory itself.
fn clear(dir: &Path) -> io::Result<()> {
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        let path = entry.path();
        if entry.file_type()?.is_dir() {
            fs::remove_dir_all(&path)?;
        } else {
            fs::remove_file(&path)?;
        }
    }
    Ok(())
}

/// Old snapshots, and what earlier versions kept here.
fn prune(dir: &Path, keep_snap: &str) {
    if let Ok(entries) = fs::read_dir(dir) {
        for entry in entries.flatten() {
            let name = entry.file_name();
            let name = name.to_string_lossy();
            let old_snap = name.starts_with("home-") && name != keep_snap;
            if (old_snap || LEGACY_DIRS.contains(&name.as_ref()))
                && entry.file_type().is_ok_and(|t| t.is_dir())
            {
                let _ = fs::remove_dir_all(entry.path());
            }
        }
    }
}

fn set_tree_perms(path: &Path) -> io::Result<()> {
    let meta = fs::symlink_metadata(path)?;
    if meta.is_dir() {
        fs::set_permissions(path, fs::Permissions::from_mode(0o2750))?;
        for entry in fs::read_dir(path)? {
            set_tree_perms(&entry?.path())?;
        }
    } else if meta.is_file() {
        fs::set_permissions(path, fs::Permissions::from_mode(0o640))?;
    }
    Ok(())
}

fn copy_readable(from: &Path, to: &Path) -> io::Result<()> {
    let data = fs::read(from)?;
    sys::write_atomic(to, &data, 0o640)
}

/// `hecate msg -j config`: the config as loaded, includes merged, without runtime overrides
/// (Game Mode's), so the login screen gets your settings and not a temporary state.
fn running_compositor_config() -> Option<Value> {
    std::env::var_os("HECATE_SOCKET")?;
    let out = Command::new(sys::hecate_bin())
        .args(["msg", "-j", "config"])
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    serde_json::from_slice(&out.stdout)
        .ok()
        .filter(Value::is_object)
}

/// The given top-level tables, with nulls dropped (unset options keep hecate's defaults).
pub fn pick(config: &Value, keys: &[&str]) -> Value {
    let mut out = Map::new();
    for key in keys {
        if let Some(v) = config.get(*key)
            && v.is_object()
        {
            out.insert((*key).to_string(), strip_nulls(v.clone()));
        }
    }
    Value::Object(out)
}

fn strip_nulls(v: Value) -> Value {
    match v {
        Value::Object(m) => Value::Object(
            m.into_iter()
                .filter(|(_, v)| !v.is_null())
                .map(|(k, v)| (k, strip_nulls(v)))
                .collect(),
        ),
        Value::Array(a) => Value::Array(a.into_iter().map(strip_nulls).collect()),
        other => other,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn picks_tables_and_strips_nulls() {
        let cfg = json!({
            "autostart": [["sh"]],
            "outputs": { "DP-1": { "mode": "1920x1080@60", "scale": null } },
            "keyboard": { "layout": "hu" },
            "binds": { "Mod+T": { "spawn": ["foot"] } }
        });
        let out = pick(&cfg, &["outputs", "keyboard", "autostart"]);
        assert_eq!(
            out,
            json!({ "outputs": { "DP-1": { "mode": "1920x1080@60" } }, "keyboard": { "layout": "hu" } })
        );
    }

    #[test]
    fn takes_layout_tables_only() {
        let tmp = std::env::temp_dir().join(format!("hg-fragment-{}", std::process::id()));
        fs::create_dir_all(&tmp).unwrap();
        fs::write(
            tmp.join("compositor.json"),
            json!({
                "outputs": { "DP-1": { "scale": 1.5 } },
                "keyboard": { "layout": "hu" },
                "cursor": "not a table",
                "animations": { "enable": false },
                "background": { "blobs": { "enable": false } },
                "autostart": [["sh"]]
            })
            .to_string(),
        )
        .unwrap();
        assert_eq!(
            compositor_fragment(&tmp),
            json!({ "outputs": { "DP-1": { "scale": 1.5 } }, "keyboard": { "layout": "hu" } })
        );
        fs::remove_dir_all(&tmp).unwrap();
    }

    #[test]
    fn prunes_old_snapshots_and_legacy_pictures() {
        let tmp = std::env::temp_dir().join(format!("hg-prune-{}", std::process::id()));
        for d in ["home-1", "home-2", "files", "splash", "other"] {
            fs::create_dir_all(tmp.join(d)).unwrap();
        }
        fs::write(tmp.join("blobs.json"), b"{}").unwrap();
        prune(&tmp, "home-2");
        let mut left: Vec<String> = fs::read_dir(&tmp)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        left.sort();
        assert_eq!(left, ["blobs.json", "home-2", "other"]);
        fs::remove_dir_all(&tmp).unwrap();
    }

    #[test]
    fn session_blobs_must_be_the_users_own_file() {
        let dir = std::env::temp_dir().join(format!("hg-blobs-{}", std::process::id()));
        let elsewhere = std::env::temp_dir().join(format!("hg-blobs-{}.json", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let me = sys::uid();
        assert_eq!(blobs_in(&dir, me), None, "no file yet");

        let state = json!({ "outputs": [{ "output": "DP-1", "blobs": [] }] });
        fs::write(dir.join("blobs.json"), state.to_string()).unwrap();
        assert_eq!(blobs_in(&dir, me), Some(state.clone()));
        assert_eq!(blobs_in(&dir, me + 1), None, "not their directory");

        fs::write(dir.join("blobs.json"), b"{\"outputs\": 3}").unwrap();
        assert_eq!(blobs_in(&dir, me), None, "not what hecate writes");

        fs::remove_file(dir.join("blobs.json")).unwrap();
        fs::write(&elsewhere, state.to_string()).unwrap();
        symlink(&elsewhere, dir.join("blobs.json")).unwrap();
        assert_eq!(blobs_in(&dir, me), None, "a link is never followed");
        fs::remove_dir_all(&dir).unwrap();
        fs::remove_file(&elsewhere).unwrap();
    }
}
