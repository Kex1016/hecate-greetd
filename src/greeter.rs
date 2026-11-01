//! The login screen's processes.
//!
//! greetd runs `hecate-greetd session` as the `greeter` user. That starts hecate with a
//! generated config: the system's greeter config (from Nix) plus `user.json`, the compositor
//! settings of whoever is selected (monitor layout, keyboard, ...). hecate autostarts
//! `hecate-greetd ui`, which runs the shell's lock screen (QuickShell, `greeter.qml`) with that
//! user's look and restarts it when another user is picked. When greetd has a session to start
//! the UI writes `launched.json` and tells hecate to quit itself, while its surfaces (the
//! user's desktop picture) are still up: hecate leaves that frame on screen, and the session's
//! first frame, the same picture, replaces it. The UI goes with the compositor.

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

/// The UI asks for another user (`request.json` says which).
const EXIT_SWITCH_USER: i32 = 10;

fn log(msg: impl AsRef<str>) {
    eprintln!("hecate-greetd: {}", msg.as_ref());
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

/// Whether the hecate this runs in still answers on its socket.
fn compositor_alive() -> bool {
    std::env::var_os("HECATE_SOCKET")
        .is_some_and(|path| std::os::unix::net::UnixStream::connect(path).is_ok())
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

/// The selected user's compositor settings, checked by `hecate validate` before hecate
/// sees them. Returns whether `user.json` changed.
fn write_user_compositor(runtime: &Path, user: Option<&str>) -> bool {
    let fragment = user
        .and_then(|name| sys::read_passwd().into_iter().find(|p| p.name == name))
        .and_then(|p| export::snapshot(&p))
        .map(|snap| export::compositor_fragment(&snap))
        .unwrap_or_else(|| json!({}));
    let path = runtime.join("user.json");
    let old = fs::read(&path)
        .ok()
        .and_then(|b| serde_json::from_slice::<Value>(&b).ok());
    if old.as_ref() == Some(&fragment) {
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
    let user = pick_user(&users, &ui, &load_state());
    write_user_compositor(&runtime, user.as_deref());
    if let Some(u) = &user {
        fs::write(ui.join("next-user"), u)?;
    }

    let config = runtime.join("config.json");
    sys::write_json(&config, &json!({ "include": [base, "user.json"] }), 0o600)?;

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
    user: Option<&'a str>,
    preview: bool,
}

/// Prepare the user's home copy and run the UI once.
fn run_ui(run: &UiRun) -> io::Result<ExitStatus> {
    let name = run.user.unwrap_or("nobody");
    let home = run.runtime.join(format!("home-{name}"));
    let passwd = run
        .user
        .and_then(|n| sys::read_passwd().into_iter().find(|p| p.name == n));
    let snap = passwd.as_ref().and_then(export::snapshot);
    match (&passwd, &snap) {
        (Some(passwd), Some(snap)) => {
            export::copy_home(snap, export::splash_dir(passwd).as_deref(), &home)?
        }
        _ => {
            if home.exists() {
                fs::remove_dir_all(&home)?;
            }
        }
    }
    // The shell only reads its config once it exists.
    let config_dir = home.join(".config/illogical-impulse");
    fs::create_dir_all(&config_dir)?;
    if !config_dir.join("config.json").exists() {
        fs::write(config_dir.join("config.json"), "{}\n")?;
    }
    for d in [
        ".local/state/quickshell/user/generated",
        ".cache",
        ".local/share",
    ] {
        fs::create_dir_all(home.join(d))?;
    }
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
        .env("HECATE_GREETD_USER", run.user.unwrap_or(""))
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
    let status = child.wait();
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
        sys::write_json(
            &ui.join("selection.json"),
            &json!({ "user": user, "session": session }),
            0o600,
        )?;

        if write_user_compositor(&runtime, user.as_deref()) && in_compositor {
            // Apply the layout before the UI maps its surfaces.
            let _ = Command::new(sys::hecate_bin())
                .args(["msg", "reload"])
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .status();
        }

        let use_fallback = failures >= 3 && !fallback.is_empty();
        let started = Instant::now();
        let status = run_ui(&UiRun {
            qml: if use_fallback { &fallback } else { &qml },
            runtime: &ui,
            user: user.as_deref(),
            preview: false,
        });
        let code = status.as_ref().ok().and_then(ExitStatus::code);
        // greetd has the session: the UI told hecate to exit with the desktop picture still
        // up, and went down with it (any status), or exited 0 itself.
        let launched = ui.join("launched.json").is_file();
        if code == Some(0) || launched {
            // Remember the choice for next time.
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
            save_state(&state);
            break;
        }
        match code {
            Some(EXIT_SWITCH_USER) => {
                failures = 0;
                let req = sys::read_json_limited(&ui.join("request.json"), 1 << 16);
                if let Some(u) = req.as_ref().and_then(|r| r["user"].as_str()) {
                    user = Some(u.to_string());
                }
            }
            other => {
                if in_compositor && !compositor_alive() {
                    // Gone under us (it exits on the UI's request at login, but then
                    // `launched.json` says so): nothing left to show anything on.
                    log("the compositor is gone, stopping");
                    return Ok(());
                }
                log(format!(
                    "the login screen exited ({other:?}, {:?})",
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
        }
    }

    // Normally the UI has already done this and hecate is gone (the message fails at once);
    // this is for a UI that exited 0 without, or whose message didn't get through.
    if in_compositor {
        let _ = Command::new(sys::hecate_bin())
            .args(["msg", "exit"])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
    }
    Ok(())
}

/// `hecate-greetd preview`: the login screen with your current look, in your session.
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
        &json!({ "user": me.name, "session": pick_session(&sessions, &me.name, &state) }),
        0o600,
    )?;
    let qml = sys::env_or("HECATE_GREETD_QML", "");
    if qml.is_empty() {
        return Err(io::Error::other("HECATE_GREETD_QML is not set"));
    }
    run_ui(&UiRun {
        qml: &qml,
        runtime: &runtime,
        user: Some(&me.name),
        preview: true,
    })?;
    Ok(())
}
