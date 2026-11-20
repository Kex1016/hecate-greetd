//! The login screen's processes.
//!
//! greetd runs `hecate-greetd session` as the `greeter` user. That starts hecate with a
//! generated config: the system's greeter config (from Nix) plus `user.json`, the keyboard and
//! monitor layout of whoever is selected. hecate draws the background itself, its blobs, and
//! autostarts `hecate-greetd ui`, which runs the login screen (QuickShell, `greeter.qml`) on
//! top and gives hecate another user's layout when one is picked. When greetd has a session
//! to start the UI writes `launched.json` and the supervisor tells hecate to exit, with nothing
//! but the blobs on screen: hecate leaves that frame up and writes down where its blobs were
//! (`background.blobs.save`), and the session's hecate carries on from there with its first
//! frame. The UI goes with the compositor.

use std::fs;
use std::io;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitStatus, Stdio};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use crate::export;
use crate::sessions::{self, User};
use crate::sys;

unsafe extern "C" {
    fn umask(mask: u32) -> u32;
}

fn log(msg: impl AsRef<str>) {
    eprintln!("hecate-greetd: {}", msg.as_ref());
    sys::journal(msg.as_ref());
}

/// Where the UI and the supervisor talk (users, sessions, the choice, the result), and the
/// users' home copies. Not the runtime dir itself: hecate reloads its config on any JSON
/// written next to it.
fn ui_dir(runtime: &Path) -> io::Result<PathBuf> {
    let dir = runtime.join("ui");
    fs::create_dir_all(&dir)?;
    Ok(dir)
}

fn runtime() -> io::Result<PathBuf> {
    match std::env::var_os("HECATE_GREETD_RUNTIME") {
        Some(dir) => Ok(PathBuf::from(dir)),
        None => sys::runtime_dir("hecate-greetd"),
    }
}

fn state_file() -> PathBuf {
    sys::state_dir().join("greeter/state.json")
}

fn load_state() -> Value {
    sys::read_json_limited(&state_file(), 1 << 20)
        .filter(Value::is_object)
        .unwrap_or_else(|| json!({}))
}

fn save_state(state: &Value) {
    let path = state_file();
    if path.parent().is_some_and(Path::is_dir)
        && let Err(e) = sys::write_json(&path, state, 0o600)
    {
        log(format!("saving {}: {e}", path.display()));
    }
}

/// Remember the login's choice for next time, and that a session ran this boot.
fn remember_login(state: &mut Value, ui: &Path) {
    if let Some(result) = sys::read_json_limited(&ui.join("result.json"), 1 << 16)
        && let Some(u) = result["user"].as_str()
    {
        state["last_user"] = json!(u);
        if let Some(s) = result["session"].as_str() {
            if !state["sessions"].is_object() {
                state["sessions"] = json!({});
            }
            state["sessions"][u] = json!(s);
        }
    }
    if let Some(boot) = boot_id() {
        state["session_boot_id"] = json!(boot);
    }
    save_state(state);
}

/// Whether the hecate this runs in still answers on its socket.
fn compositor_alive() -> bool {
    std::env::var_os("HECATE_SOCKET")
        .is_some_and(|path| std::os::unix::net::UnixStream::connect(path).is_ok())
}

fn boot_id() -> Option<String> {
    fs::read_to_string("/proc/sys/kernel/random/boot_id")
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

/// Whether a session was started from this login screen since boot: then the one that just
/// ended left its blobs on screen, and the login screen carries on from where they were.
/// After a boot there is nothing to carry on from.
fn after_session(state: &Value) -> bool {
    state["session_boot_id"]
        .as_str()
        .is_some_and(|b| Some(b) == boot_id().as_deref())
}

fn pick_user(users: &[User], runtime: &Path, state: &Value) -> Option<String> {
    let known = |n: &str| users.iter().any(|u| u.name == n);
    let requested = fs::read_to_string(runtime.join("next-user")).ok();
    let _ = fs::remove_file(runtime.join("next-user"));
    requested
        .map(|s| s.trim().to_string())
        .filter(|n| known(n))
        .or_else(|| {
            state["last_user"]
                .as_str()
                .map(String::from)
                .filter(|n| known(n))
        })
        .or_else(|| {
            std::env::var("HECATE_GREETD_DEFAULT_USER")
                .ok()
                .filter(|n| known(n))
        })
        .or_else(|| users.first().map(|u| u.name.clone()))
}

fn pick_session(sessions: &[sessions::Session], user: &str, state: &Value) -> Option<String> {
    let known = |id: &str| sessions.iter().any(|s| s.id == id);
    state["sessions"][user]
        .as_str()
        .map(String::from)
        .filter(|id| known(id))
        .or_else(|| {
            std::env::var("HECATE_GREETD_DEFAULT_SESSION")
                .ok()
                .filter(|id| known(id))
        })
        .or_else(|| known("hecate").then(|| "hecate".to_string()))
        .or_else(|| sessions.first().map(|s| s.id.clone()))
}

/// Where the greeter's hecate carries its blobs on from (`background.blobs.resume`). In the
/// UI's directory: hecate reloads its config on any JSON written next to it.
fn resume_file(runtime: &Path) -> PathBuf {
    runtime.join("ui/resume-blobs.json")
}

/// After a session this boot, a copy of where its hecate left the blobs, for the greeter's
/// hecate to start from: the login screen's first frame is then the frame the session left.
/// Otherwise nothing, and the blobs start anew. Returns whether there is something to carry on.
fn prepare_resume(runtime: &Path, state: &Value) -> bool {
    let dest = resume_file(runtime);
    let _ = fs::remove_file(&dest);
    if !after_session(state) {
        return false;
    }
    let blobs = state["last_user"]
        .as_str()
        .and_then(|name| sys::read_passwd().into_iter().find(|p| p.name == name))
        .as_ref()
        .and_then(export::session_blobs);
    match blobs {
        Some(blobs) => sys::write_json(&dest, &blobs, 0o600).is_ok(),
        None => false,
    }
}

/// What the greeter adds to a user's tables: nothing of theirs can take its place.
fn with_own_settings(mut fragment: Value, runtime: &Path) -> Value {
    fragment["background"] = json!({ "blobs": { "resume": resume_file(runtime) } });
    fragment
}

/// The selected user's keyboard and monitor layout, checked by `hecate validate` before hecate
/// sees it. Returns whether `user.json` changed.
fn write_user_compositor(runtime: &Path, user: Option<&str>) -> bool {
    let passwd = user.and_then(|name| sys::read_passwd().into_iter().find(|p| p.name == name));
    let snap = passwd.as_ref().and_then(export::snapshot);
    let fragment = snap
        .as_ref()
        .map(|snap| export::compositor_fragment(snap))
        .unwrap_or_else(|| json!({}));
    let path = runtime.join("user.json");
    let old = fs::read(&path)
        .ok()
        .and_then(|b| serde_json::from_slice::<Value>(&b).ok());
    if old == Some(with_own_settings(fragment.clone(), runtime)) {
        return false;
    }
    let candidate = runtime.join("ui/user.check.json");
    let mut checked = fragment.clone();
    // Nothing to check in an empty fragment (no export, or one with no compositor tables).
    let has_tables = fragment.as_object().is_some_and(|m| !m.is_empty());
    if has_tables && sys::write_json(&candidate, &fragment, 0o600).is_ok() {
        let ok = Command::new(sys::hecate_bin())
            .arg("validate")
            .arg(&candidate)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .status()
            .is_ok_and(|s| s.success());
        if !ok {
            log(format!(
                "{}'s compositor settings don't validate, using the defaults",
                user.unwrap_or("?")
            ));
            checked = json!({});
        }
        let _ = fs::remove_file(&candidate);
    }
    let checked = with_own_settings(checked, runtime);
    if old.as_ref() == Some(&checked) {
        return false;
    }
    if let Err(e) = sys::write_json(&path, &checked, 0o600) {
        log(format!("writing {}: {e}", path.display()));
    }
    true
}

/// `hecate-greetd session`: greetd's `default_session.command`.
pub fn session(extra_args: &[String]) -> io::Result<()> {
    let base = std::env::var("HECATE_GREETD_BASE_CONFIG").map_err(|_| {
        io::Error::other("HECATE_GREETD_BASE_CONFIG is not set (the NixOS module sets it)")
    })?;
    let runtime = sys::runtime_dir("hecate-greetd")?;

    // Start with the layout of whoever the login screen opens on.
    let users = sessions::users();
    let ui = ui_dir(&runtime)?;
    let state = load_state();
    let user = pick_user(&users, &ui, &state);
    let resumed = prepare_resume(&runtime, &state);
    write_user_compositor(&runtime, user.as_deref());
    if let Some(u) = &user {
        fs::write(ui.join("next-user"), u)?;
    }

    let config = runtime.join("config.json");
    sys::write_json(&config, &json!({ "include": [base, "user.json"] }), 0o600)?;

    log(format!(
        "starting hecate for the login screen (user {}, blobs carried on from the session: {resumed})",
        user.as_deref().unwrap_or("-")
    ));
    // The session's hecate reads where this one leaves its blobs: whatever greetd's umask is,
    // that file has to be readable by whoever logs in.
    // SAFETY: umask only sets this process's file mode mask and cannot fail.
    unsafe {
        umask(0o022);
    }
    let mut cmd = Command::new(sys::hecate_bin());
    cmd.arg("--config").arg(&config).args(extra_args);
    cmd.env("HECATE_GREETD_RUNTIME", &runtime)
        // No hecate-session.target or activation environment for the greeter user.
        .env("HECATE_NO_SESSION", "1")
        .env("XDG_SESSION_TYPE", "wayland")
        .env("XDG_CURRENT_DESKTOP", "hecate");
    if std::env::var_os("DBUS_SESSION_BUS_ADDRESS").is_none()
        && let Some(rt) = std::env::var_os("XDG_RUNTIME_DIR")
    {
        let bus = PathBuf::from(rt).join("bus");
        if bus.exists() {
            cmd.env(
                "DBUS_SESSION_BUS_ADDRESS",
                format!("unix:path={}", bus.display()),
            );
        }
    }
    Err(cmd.exec())
}

struct UiRun<'a> {
    qml: &'a str,
    runtime: &'a Path,
    user: Option<String>,
    preview: bool,
}

/// What the UI tells its supervisor while it runs.
enum UiEvent<'a> {
    /// Another user is selected (`request.json`).
    Selected(&'a str),
    /// greetd has accepted the session (`launched.json`).
    Launched,
}

/// The shell's home for the login screen: the same for every user, so nothing of theirs is in
/// it. Its settings are the shell's defaults, or `HECATE_GREETD_SHELL_CONFIG` (the NixOS
/// module's `shellSettings`).
fn prepare_home(runtime: &Path) -> io::Result<PathBuf> {
    let home = runtime.join("home");
    let config_dir = home.join(".config/illogical-impulse");
    fs::create_dir_all(&config_dir)?;
    // The shell only reads its config once it exists.
    let settings = std::env::var_os("HECATE_GREETD_SHELL_CONFIG")
        .and_then(|path| sys::read_json_limited(Path::new(&path), 1 << 20))
        .filter(Value::is_object)
        .unwrap_or_else(|| json!({}));
    sys::write_json(&config_dir.join("config.json"), &settings, 0o600)?;
    for d in [
        ".local/state/quickshell/user/generated",
        ".cache",
        ".local/share",
    ] {
        fs::create_dir_all(home.join(d))?;
    }
    Ok(home)
}

/// The user `request.json` asks for, once per write of it.
struct Requests {
    path: PathBuf,
    seen: Option<(std::time::SystemTime, u64)>,
}

impl Requests {
    fn poll(&mut self) -> Option<String> {
        let meta = fs::symlink_metadata(&self.path).ok()?;
        let stamp = (meta.modified().ok()?, meta.len());
        if self.seen == Some(stamp) {
            return None;
        }
        // Half written: the next poll reads it again.
        let request = sys::read_json_limited(&self.path, 1 << 16)?;
        self.seen = Some(stamp);
        request["user"].as_str().map(String::from)
    }
}

/// Run the UI once. `on_event` hears of another user being selected and, once, of greetd
/// having accepted the session, while the UI still runs.
fn run_ui(run: &UiRun, mut on_event: impl FnMut(UiEvent)) -> io::Result<ExitStatus> {
    let home = prepare_home(run.runtime)?;
    for stale in ["request.json", "result.json", "launched.json"] {
        let _ = fs::remove_file(run.runtime.join(stale));
    }

    let mut cmd = Command::new(sys::qs_bin());
    cmd.arg("-p").arg(run.qml);
    cmd.env("HOME", &home)
        .env("XDG_CONFIG_HOME", home.join(".config"))
        .env("XDG_STATE_HOME", home.join(".local/state"))
        .env("XDG_CACHE_HOME", home.join(".cache"))
        .env("XDG_DATA_HOME", home.join(".local/share"))
        .env("HECATE_GREETD_RUNTIME", run.runtime)
        .env("HECATE_GREETD_USER", run.user.as_deref().unwrap_or(""))
        .env("QT_QPA_PLATFORM", "wayland");
    if run.preview {
        cmd.env("HECATE_GREETD_PREVIEW", "1");
    } else {
        cmd.env_remove("HECATE_GREETD_PREVIEW");
    }
    // Its own process group, so nothing it started outlives it.
    cmd.process_group(0);
    // SAFETY: the hook only calls prctl, which is async-signal-safe.
    unsafe {
        cmd.pre_exec(sys::die_with_parent);
    }
    let mut child = cmd.spawn()?;
    let pgid = child.id();
    let launched = run.runtime.join("launched.json");
    let mut requests = Requests {
        path: run.runtime.join("request.json"),
        seen: None,
    };
    let mut seen_launch = false;
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break Ok(status),
            Ok(None) => {}
            Err(e) => break Err(e),
        }
        if !seen_launch {
            if let Some(user) = requests.poll() {
                on_event(UiEvent::Selected(&user));
            }
            if launched.is_file() {
                seen_launch = true;
                on_event(UiEvent::Launched);
            }
        }
        std::thread::sleep(Duration::from_millis(10));
    };
    // Whatever it started goes with it, but the handover to the session doesn't wait on
    // stragglers that aren't there.
    sys::kill_group(pgid, sys::SIGTERM);
    let deadline = Instant::now() + Duration::from_millis(100);
    while sys::group_alive(pgid) && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(5));
    }
    sys::kill_group(pgid, sys::SIGKILL);
    status
}

fn write_choices(runtime: &Path, users: &[User], sessions: &[sessions::Session]) -> io::Result<()> {
    sys::write_json(
        &runtime.join("users.json"),
        &serde_json::to_value(users)?,
        0o600,
    )?;
    sys::write_json(
        &runtime.join("sessions.json"),
        &serde_json::to_value(sessions)?,
        0o600,
    )
}

/// `hecate msg <args>` to the hecate this runs in.
fn hecate_msg(args: &[&str]) {
    let _ = Command::new(sys::hecate_bin())
        .arg("msg")
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
}

/// `hecate-greetd ui`: run inside the greeter's hecate.
pub fn ui() -> io::Result<()> {
    let runtime = runtime()?;
    let ui = ui_dir(&runtime)?;
    let qml = sys::env_or("HECATE_GREETD_QML", "");
    let fallback = sys::env_or("HECATE_GREETD_FALLBACK_QML", "");
    if qml.is_empty() {
        return Err(io::Error::other("HECATE_GREETD_QML is not set"));
    }
    let in_compositor = std::env::var_os("HECATE_SOCKET").is_some();

    let mut state = load_state();
    let mut failures = 0u32;
    let mut user: Option<String> = None;
    loop {
        let users = sessions::users();
        let sessions = sessions::sessions();
        write_choices(&ui, &users, &sessions)?;
        if user
            .as_ref()
            .is_none_or(|u| !users.iter().any(|x| &x.name == u))
        {
            user = pick_user(&users, &ui, &state);
        }
        let session = user
            .as_deref()
            .and_then(|u| pick_session(&sessions, u, &state));
        // What each user logged into last, for when the UI switches to them.
        let last: serde_json::Map<String, Value> = users
            .iter()
            .filter_map(|u| {
                Some((
                    u.name.clone(),
                    json!(pick_session(&sessions, &u.name, &state)?),
                ))
            })
            .collect();
        sys::write_json(
            &ui.join("selection.json"),
            &json!({ "user": user, "session": session, "sessions": last }),
            0o600,
        )?;

        if write_user_compositor(&runtime, user.as_deref()) && in_compositor {
            // Apply the layout before the UI maps its surfaces.
            hecate_msg(&["reload"]);
        }

        let use_fallback = failures >= 3 && !fallback.is_empty();
        let started = Instant::now();
        let status = run_ui(
            &UiRun {
                qml: if use_fallback { &fallback } else { &qml },
                runtime: &ui,
                user: user.clone(),
                preview: false,
            },
            |event| match event {
                UiEvent::Selected(name) => {
                    if user.as_deref() == Some(name) || !users.iter().any(|u| u.name == name) {
                        return;
                    }
                    // Their keyboard and monitors, while the UI stays up.
                    user = Some(name.to_string());
                    if write_user_compositor(&runtime, Some(name)) && in_compositor {
                        hecate_msg(&["reload"]);
                    }
                }
                UiEvent::Launched => {
                    // greetd has the session and starts it once hecate is gone. Remember the
                    // login first: this process goes down with hecate too, or soon after.
                    remember_login(&mut state, &ui);
                    log(format!(
                        "logging in after {:.1} s, telling hecate to exit",
                        started.elapsed().as_secs_f64()
                    ));
                    if in_compositor {
                        hecate_msg(&["exit"]);
                    }
                }
            },
        );
        let code = status.as_ref().ok().and_then(ExitStatus::code);
        // A login: the UI went down with hecate (any status), or exited 0 itself.
        let launched = ui.join("launched.json").is_file();
        log(format!(
            "the login screen ended ({code:?}, launched: {launched}) after {:.1} s",
            started.elapsed().as_secs_f64()
        ));
        if code == Some(0) || launched {
            remember_login(&mut state, &ui);
            break;
        }
        if in_compositor && !compositor_alive() {
            // Gone under us (it exits on the UI's request at login, but then
            // `launched.json` says so): nothing left to show anything on.
            log("the compositor is gone, stopping");
            return Ok(());
        }
        log(format!(
            "the login screen exited ({code:?}, {:?})",
            status.err()
        ));
        if started.elapsed() < Duration::from_secs(20) {
            failures += 1;
        } else {
            failures = 0;
        }
        if failures >= 6 {
            return Err(io::Error::other("the login screen keeps failing"));
        }
        std::thread::sleep(Duration::from_millis(500 * failures as u64));
    }

    // Normally done at the login and hecate is gone (the message fails at once); this is for
    // a UI that exited 0 without logging in, or whose message didn't get through.
    if in_compositor {
        hecate_msg(&["exit"]);
    }
    Ok(())
}

/// `hecate-greetd preview`: the login screen over your session, as it is at login.
/// Nothing logs in; Escape or "logging in" closes it.
pub fn preview() -> io::Result<()> {
    if let Err(e) = export::sync() {
        log(format!("sync: {e}"));
    }
    let me = sys::current_user()?;
    let runtime = sys::runtime_dir("hecate-greetd-preview")?;
    let users = vec![sessions::user_entry(&me)];
    let sessions = sessions::sessions();
    write_choices(&runtime, &users, &sessions)?;
    let state = json!({});
    sys::write_json(
        &runtime.join("selection.json"),
        &json!({ "user": me.name, "session": pick_session(&sessions, &me.name, &state), "sessions": {} }),
        0o600,
    )?;
    let qml = sys::env_or("HECATE_GREETD_QML", "");
    if qml.is_empty() {
        return Err(io::Error::other("HECATE_GREETD_QML is not set"));
    }
    run_ui(
        &UiRun {
            qml: &qml,
            runtime: &runtime,
            user: Some(me.name.clone()),
            preview: true,
        },
        |_| {},
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn blobs_carry_on_only_after_a_session_this_boot() {
        assert!(!after_session(&json!({})));
        assert!(!after_session(
            &json!({ "session_boot_id": "not this boot" })
        ));
        if let Some(boot) = boot_id() {
            assert!(after_session(&json!({ "session_boot_id": boot })));
        }
        let runtime = std::env::temp_dir().join(format!("hg-resume-{}", std::process::id()));
        fs::create_dir_all(runtime.join("ui")).unwrap();
        fs::write(resume_file(&runtime), b"{}").unwrap();
        assert!(!prepare_resume(&runtime, &json!({ "last_user": "root" })));
        assert!(!resume_file(&runtime).exists(), "a stale copy is gone");
        fs::remove_dir_all(&runtime).unwrap();
    }

    #[test]
    fn a_user_cannot_replace_the_greeters_own_settings() {
        let runtime = Path::new("/run/user/1/hecate-greetd");
        let theirs = json!({
            "keyboard": { "layout": "hu" },
            "background": { "blobs": { "enable": false, "resume": "/etc/passwd" } }
        });
        assert_eq!(
            with_own_settings(theirs, runtime),
            json!({
                "keyboard": { "layout": "hu" },
                "background": { "blobs": { "resume": "/run/user/1/hecate-greetd/ui/resume-blobs.json" } }
            })
        );
    }

    #[test]
    fn a_request_is_heard_once_per_write() {
        let dir = std::env::temp_dir().join(format!("hg-request-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let mut requests = Requests {
            path: dir.join("request.json"),
            seen: None,
        };
        assert_eq!(requests.poll(), None, "nothing asked yet");
        fs::write(&requests.path, b"{\"user\": \"gue").unwrap();
        assert_eq!(requests.poll(), None, "half written");
        fs::write(&requests.path, b"{\"user\": \"guest\", \"seq\": 1}").unwrap();
        assert_eq!(requests.poll().as_deref(), Some("guest"));
        assert_eq!(requests.poll(), None, "heard already");
        fs::write(&requests.path, b"{\"user\": \"cakes\", \"seq\": 12}").unwrap();
        assert_eq!(requests.poll().as_deref(), Some("cakes"));
        fs::remove_dir_all(&dir).unwrap();
    }
}
