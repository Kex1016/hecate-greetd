//! A user's export: what the login screen may show for them.
//!
//! The greeter can't read home directories, so `hecate-greetd sync` (run by the user's shell)
//! copies what the shell's lock screen needs into `<state>/users/<user>/`, a directory the user
//! owns and the `greeter` group can read (setgid, created by the NixOS module):
//!
//! ```text
//! users/<user>/
//!   current -> home-<time>      the latest snapshot, swapped atomically
//!   home-<time>/                laid out like a home directory, so the shell reads it unchanged
//!     .config/illogical-impulse/config.json    shell config, image paths pointing into files/
//!     .local/state/quickshell/user/generated/  generated Material colours (colors.json, ...)
//!     .face                                    avatar
//!     compositor.json          hecate settings for the login screen (outputs, keyboard, ...)
//!     manifest.json
//!   files/<hash>.<ext>          wallpapers and other images the config refers to
//!   splash/<output>.png         the desktop as it was, written by hecate itself (`splash.dir`)
//!                               at lock and logout, which the login screen fades into
//! ```
//!
//! Everything in there is the user's to write, so the greeter treats it as untrusted: it checks
//! ownership, never follows symlinks, caps sizes and only takes a few compositor tables.

use std::collections::HashSet;
use std::fs;
use std::hash::{DefaultHasher, Hash, Hasher};
use std::io;
use std::os::unix::fs::{MetadataExt, PermissionsExt, symlink};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{Map, Value, json};

use crate::sys::{self, Passwd};

/// Compositor tables the login screen takes from a user. Anything else (autostart, binds,
/// environment, rules) could run commands as the greeter, so it never gets through.
pub const COMPOSITOR_KEYS_DISPLAYS: &[&str] = &["outputs"];
pub const COMPOSITOR_KEYS_INPUT: &[&str] = &["keyboard", "input", "cursor"];
pub const COMPOSITOR_KEYS_LOOK: &[&str] = &["blur", "animations"];

const IMAGE_EXTS: &[&str] = &[
    "png", "jpg", "jpeg", "webp", "gif", "bmp", "avif", "tif", "tiff", "svg", "jxl",
];
const MAX_IMAGE: u64 = 64 << 20;
const MAX_SMALL: u64 = 4 << 20;

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
        .chain(COMPOSITOR_KEYS_LOOK)
        .copied()
        .collect();
    Value::Object(
        map.into_iter()
            .filter(|(k, v)| allowed.contains(&k.as_str()) && v.is_object())
            .collect(),
    )
}

/// Copy a snapshot's home tree into `dest` (the greeter's private, writable copy), and the
/// user's splash pictures (`splash_dir`) where hecate looks for them by default.
pub fn copy_home(snap: &Path, splash: Option<&Path>, dest: &Path) -> io::Result<()> {
    if dest.exists() {
        fs::remove_dir_all(dest)?;
    }
    sys::copy_tree(snap, dest, MAX_SMALL, 8)?;
    for meta_file in ["compositor.json", "manifest.json"] {
        let _ = fs::remove_file(dest.join(meta_file));
    }
    if let Some(splash) = splash {
        sys::copy_tree(
            splash,
            &dest.join(".local/state/hecate/snapshots"),
            MAX_IMAGE,
            1,
        )?;
    }
    Ok(())
}

/// The user's splash pictures, if the directory is really theirs.
pub fn splash_dir(user: &Passwd) -> Option<PathBuf> {
    let dir = export_dir(&user.name).join("splash");
    sys::is_owned_dir(&dir, user.uid).then_some(dir)
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
    let state_home = xdg("XDG_STATE_HOME", &home, ".local/state");

    let shell_config_path = config_home.join("illogical-impulse/config.json");
    let mut shell_config = sys::read_json_limited(&shell_config_path, MAX_SMALL)
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
    let files = dir.join("files");
    let result = (|| -> io::Result<Value> {
        for d in [
            snap.join(".config/illogical-impulse"),
            snap.join(".local/state/quickshell/user/generated"),
            files.clone(),
        ] {
            fs::create_dir_all(&d)?;
        }

        // Shell config, with every image it names under $HOME copied into files/.
        let mut used = HashSet::new();
        rewrite_paths(&mut shell_config, &home, &files, &mut used);
        sys::write_json(
            &snap.join(".config/illogical-impulse/config.json"),
            &shell_config,
            0o640,
        )?;

        // Generated colours (and the lock screen's own, for a separate lock wallpaper).
        let generated = state_home.join("quickshell/user/generated");
        if let Ok(entries) = fs::read_dir(&generated) {
            for entry in entries.flatten() {
                let path = entry.path();
                let small_json = path.extension().is_some_and(|e| e == "json")
                    && entry
                        .metadata()
                        .is_ok_and(|m| m.is_file() && m.len() <= MAX_SMALL);
                if small_json {
                    copy_readable(
                        &path,
                        &snap
                            .join(".local/state/quickshell/user/generated")
                            .join(entry.file_name()),
                    )?;
                }
            }
        }

        for face in [".face", ".face.icon"] {
            let src = home.join(face);
            if fs::metadata(&src).is_ok_and(|m| m.is_file() && m.len() <= MAX_SMALL) {
                copy_readable(&src, &snap.join(face))?;
                break;
            }
        }

        // hecate settings from the running compositor (Nix config + the shell's hecate page).
        let mut keys: Vec<&str> = COMPOSITOR_KEYS_LOOK.to_vec();
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
            "files": used.len(),
            "outputs": outputs,
            "keyboard": compositor.get("keyboard").and_then(|k| k.get("layout")).cloned().unwrap_or(Value::Null),
        });
        sys::write_json(&snap.join("manifest.json"), &status, 0o640)?;
        set_tree_perms(&snap)?;
        fs::set_permissions(&files, fs::Permissions::from_mode(0o2750))?;

        // Swap `current` over to the new snapshot in one rename.
        let tmp_link = dir.join(format!(".current.{}", std::process::id()));
        let _ = fs::remove_file(&tmp_link);
        symlink(&snap_name, &tmp_link)?;
        fs::rename(&tmp_link, dir.join("current"))?;

        prune(&dir, &snap_name, &files, &used);
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

fn prune(dir: &Path, keep_snap: &str, files: &Path, used: &HashSet<String>) {
    if let Ok(entries) = fs::read_dir(dir) {
        for entry in entries.flatten() {
            let name = entry.file_name();
            let name = name.to_string_lossy();
            if name.starts_with("home-") && name != keep_snap {
                let _ = fs::remove_dir_all(entry.path());
            }
        }
    }
    if let Ok(entries) = fs::read_dir(files) {
        for entry in entries.flatten() {
            if !used.contains(entry.file_name().to_string_lossy().as_ref()) {
                let _ = fs::remove_file(entry.path());
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

/// Point every image path under `home` at a copy in `files`.
fn rewrite_paths(v: &mut Value, home: &Path, files: &Path, used: &mut HashSet<String>) {
    match v {
        Value::Object(m) => m
            .values_mut()
            .for_each(|v| rewrite_paths(v, home, files, used)),
        Value::Array(a) => a
            .iter_mut()
            .for_each(|v| rewrite_paths(v, home, files, used)),
        Value::String(s) => {
            if let Some(new) = export_image(s, home, files, used) {
                *s = new;
            }
        }
        _ => {}
    }
}

fn export_image(s: &str, home: &Path, files: &Path, used: &mut HashSet<String>) -> Option<String> {
    let (prefix, raw) = match s.strip_prefix("file://") {
        Some(rest) => ("file://", sys::percent_decode(rest)),
        None => ("", s.to_string()),
    };
    let path = Path::new(&raw);
    if !path.is_absolute() || !path.starts_with(home) {
        return None;
    }
    let ext = path.extension()?.to_str()?.to_ascii_lowercase();
    if !IMAGE_EXTS.contains(&ext.as_str()) {
        return None;
    }
    let meta = fs::metadata(path).ok()?;
    if !meta.is_file() || meta.len() > MAX_IMAGE {
        return None;
    }
    let mut h = DefaultHasher::new();
    raw.hash(&mut h);
    meta.len().hash(&mut h);
    meta.mtime().hash(&mut h);
    meta.mtime_nsec().hash(&mut h);
    let name = format!("{:016x}.{ext}", h.finish());
    let dest = files.join(&name);
    if !dest.exists() {
        copy_readable(path, &dest).ok()?;
    }
    used.insert(name);
    Some(format!("{prefix}{}", dest.display()))
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
    fn copies_splash_pictures_but_not_links() {
        let tmp = std::env::temp_dir().join(format!("hg-splash-{}", std::process::id()));
        let (snap, splash, dest) = (tmp.join("snap"), tmp.join("splash"), tmp.join("dest"));
        fs::create_dir_all(&snap).unwrap();
        fs::create_dir_all(&splash).unwrap();
        fs::write(splash.join("DP-1.png"), b"png").unwrap();
        symlink("/etc/shadow", splash.join("DP-2.png")).unwrap();
        copy_home(&snap, Some(&splash), &dest).unwrap();
        let pictures = dest.join(".local/state/hecate/snapshots");
        assert_eq!(fs::read(pictures.join("DP-1.png")).unwrap(), b"png");
        assert!(fs::symlink_metadata(pictures.join("DP-2.png")).is_err());
        fs::remove_dir_all(&tmp).unwrap();
    }

    #[test]
    fn rewrites_images_under_home() {
        let tmp = std::env::temp_dir().join(format!("hg-test-{}", std::process::id()));
        let home = tmp.join("home");
        let files = tmp.join("files");
        fs::create_dir_all(home.join("Pictures")).unwrap();
        fs::create_dir_all(&files).unwrap();
        fs::write(home.join("Pictures/wall paper.png"), b"png").unwrap();
        let mut cfg = json!({
            "background": {
                "wallpaperPath": home.join("Pictures/wall paper.png").display().to_string(),
                "thumb": format!("file://{}", home.join("Pictures/wall%20paper.png").display()),
                "elsewhere": "/nix/store/x.png",
                "missing": home.join("nope.png").display().to_string(),
                "list": [{ "monitor": "DP-1", "path": home.join("Pictures/wall paper.png").display().to_string() }]
            }
        });
        let mut used = HashSet::new();
        rewrite_paths(&mut cfg, &home, &files, &mut used);
        let wall = cfg["background"]["wallpaperPath"].as_str().unwrap();
        assert!(wall.starts_with(files.to_str().unwrap()));
        assert!(
            cfg["background"]["thumb"]
                .as_str()
                .unwrap()
                .starts_with("file://")
        );
        assert_eq!(cfg["background"]["elsewhere"], "/nix/store/x.png");
        assert!(
            cfg["background"]["missing"]
                .as_str()
                .unwrap()
                .ends_with("nope.png")
        );
        assert_eq!(cfg["background"]["list"][0]["path"].as_str().unwrap(), wall);
        assert_eq!(used.len(), 1);
        assert_eq!(fs::read(wall).unwrap(), b"png");
        fs::remove_dir_all(&tmp).unwrap();
    }
}
