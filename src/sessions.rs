//! Login choices: who can log in and into what.

use std::fs;
use std::path::{Path, PathBuf};

use serde::Serialize;

use crate::export;
use crate::sys::{self, Passwd};

#[derive(Debug, Clone, Serialize)]
pub struct User {
    pub name: String,
    #[serde(rename = "displayName")]
    pub display_name: String,
    pub uid: u32,
    /// Avatar from the user's export, else AccountsService's.
    pub avatar: Option<String>,
    /// The user shares their look (`hecate-greetd sync` has run).
    pub shared: bool,
}

/// Users shown on the login screen: `HECATE_GREETD_USERS` (comma separated) when set, else
/// every account with a uid in 1000..60000 and a real login shell.
pub fn users() -> Vec<User> {
    let allow: Option<Vec<String>> = std::env::var("HECATE_GREETD_USERS")
        .ok()
        .filter(|v| !v.trim().is_empty())
        .map(|v| {
            v.split(',')
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .collect()
        });
    let passwd = sys::read_passwd();
    let mut list: Vec<&Passwd> = match &allow {
        Some(names) => names
            .iter()
            .filter_map(|n| passwd.iter().find(|p| &p.name == n))
            .collect(),
        None => passwd
            .iter()
            .filter(|p| (1000..60000).contains(&p.uid) && !is_nologin(&p.shell))
            .collect(),
    };
    if allow.is_none() {
        list.sort_by_key(|p| p.uid);
    }
    list.into_iter().map(user_entry).collect()
}

pub fn user_entry(p: &Passwd) -> User {
    let snap = export::snapshot(p);
    let avatar = snap
        .as_deref()
        .and_then(export::avatar)
        .or_else(|| {
            let icon = PathBuf::from("/var/lib/AccountsService/icons").join(&p.name);
            icon.is_file().then_some(icon)
        })
        .map(|p| p.display().to_string());
    User {
        name: p.name.clone(),
        display_name: p.display_name(),
        uid: p.uid,
        avatar,
        shared: snap.is_some(),
    }
}

fn is_nologin(shell: &str) -> bool {
    shell.is_empty() || shell.ends_with("/nologin") || shell.ends_with("/false")
}

#[derive(Debug, Clone, Serialize)]
pub struct Session {
    /// Desktop file name without `.desktop` (`hecate`).
    pub id: String,
    pub name: String,
    pub comment: String,
    pub exec: Vec<String>,
    #[serde(rename = "desktopNames")]
    pub desktop_names: Vec<String>,
}

/// Wayland sessions from `HECATE_GREETD_SESSION_DIRS` (colon separated), first one of an id wins.
pub fn sessions() -> Vec<Session> {
    let dirs = sys::env_or(
        "HECATE_GREETD_SESSION_DIRS",
        "/run/current-system/sw/share/wayland-sessions:/usr/local/share/wayland-sessions:/usr/share/wayland-sessions",
    );
    let mut out: Vec<Session> = Vec::new();
    for dir in dirs.split(':').filter(|d| !d.is_empty()) {
        let Ok(entries) = fs::read_dir(dir) else {
            continue;
        };
        let mut paths: Vec<PathBuf> = entries
            .flatten()
            .map(|e| e.path())
            .filter(|p| p.extension().is_some_and(|e| e == "desktop"))
            .collect();
        paths.sort();
        for path in paths {
            if let Some(s) = parse_desktop(&path)
                && !out.iter().any(|o| o.id == s.id)
            {
                out.push(s);
            }
        }
    }
    out
}

fn parse_desktop(path: &Path) -> Option<Session> {
    let text = fs::read_to_string(path).ok()?;
    let id = path.file_stem()?.to_str()?.to_string();
    let (mut name, mut comment, mut exec, mut names) = (None, String::new(), None, Vec::new());
    let mut in_entry = false;
    for line in text.lines() {
        let line = line.trim();
        if line.starts_with('[') {
            in_entry = line == "[Desktop Entry]";
            continue;
        }
        if !in_entry {
            continue;
        }
        let Some((k, v)) = line.split_once('=') else {
            continue;
        };
        match k.trim() {
            "Name" => name = Some(v.trim().to_string()),
            "Comment" => comment = v.trim().to_string(),
            "Exec" => exec = Some(v.trim().to_string()),
            "DesktopNames" => {
                names = v
                    .split(';')
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                    .map(String::from)
                    .collect()
            }
            "Hidden" | "NoDisplay" if v.trim() == "true" => return None,
            _ => {}
        }
    }
    let exec = split_exec(&exec?);
    if exec.is_empty() {
        return None;
    }
    Some(Session {
        name: name.unwrap_or_else(|| id.clone()),
        id,
        comment,
        exec,
        desktop_names: names,
    })
}

/// Split a desktop entry `Exec` value into argv: double quotes group, field codes (`%f`, ...)
/// are dropped and `%%` is a literal percent.
pub fn split_exec(exec: &str) -> Vec<String> {
    let mut args = Vec::new();
    let mut cur = String::new();
    let mut has = false;
    let mut quoted = false;
    let mut chars = exec.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '"' => {
                quoted = !quoted;
                has = true;
            }
            '\\' if quoted => {
                if let Some(n) = chars.next() {
                    cur.push(n);
                }
            }
            c if c.is_whitespace() && !quoted => {
                if has {
                    args.push(std::mem::take(&mut cur));
                    has = false;
                }
            }
            '%' => {
                if chars.next() == Some('%') {
                    cur.push('%');
                    has = true;
                }
            }
            c => {
                cur.push(c);
                has = true;
            }
        }
    }
    if has {
        args.push(cur);
    }
    args.retain(|a| !a.is_empty());
    args
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_exec() {
        assert_eq!(split_exec("hecate"), vec!["hecate"]);
        assert_eq!(
            split_exec(r#"/bin/start "my session" --flag %U 100%%"#),
            vec!["/bin/start", "my session", "--flag", "100%"]
        );
    }

    #[test]
    fn parses_desktop_files() {
        let dir = std::env::temp_dir().join(format!("hg-sessions-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        fs::write(
            dir.join("hecate.desktop"),
            "[Desktop Entry]\nName=hecate\nExec=hecate\nDesktopNames=hecate\n[Desktop Action x]\nExec=nope\n",
        )
        .unwrap();
        fs::write(
            dir.join("hidden.desktop"),
            "[Desktop Entry]\nName=h\nExec=h\nHidden=true\n",
        )
        .unwrap();
        let s = parse_desktop(&dir.join("hecate.desktop")).unwrap();
        assert_eq!(s.exec, vec!["hecate"]);
        assert_eq!(s.desktop_names, vec!["hecate"]);
        assert!(parse_desktop(&dir.join("hidden.desktop")).is_none());
        fs::remove_dir_all(&dir).unwrap();
    }
}
