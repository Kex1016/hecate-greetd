# hecate-greetd

A [greetd](https://sr.ht/~kennylevinsen/greetd/) greeter for
[hecate](https://github.com/Kex1016/wl-hex): the login screen **is** the bundled shell's lock
screen, running inside hecate, with the look of whoever is logging in.

- **Same code, same look.** The greeter is a QuickShell entry point (`greeter.qml`) installed
  next to the shell's `shell.qml`, so it runs the shell's own `LockSurface`, wallpaper layer,
  clock and desktop widgets, colours and animations: the centered wallpaper in its shape (click
  to thump, scroll to change the shape) or the zoomed blur, material-shape password dots, the
  shake on a wrong password, the toolbar pop-in, and on login the shell's unlock animation, then
  a fade into your desktop as it was (hecate's login splash), which the session keeps on screen
  until its shell is up.
- **The selected user's settings.** Their shell config, generated Material colours, wallpapers
  (per-monitor ones too), avatar, clock style and widgets.
- **The selected user's monitors.** Their hecate `outputs` (mode, refresh rate, scale,
  orientation, position, VRR; from the Nix config and the shell's hecate page) and keyboard,
  mouse and cursor settings are merged into the greeter's compositor config the moment they
  are picked. hecate does the hot-plugging: a monitor plugged in later gets that user's
  settings, and the greeter puts a surface on it.
- **Configured from the shell.** Settings → hecate-greetd (next to hecate): share or not,
  wallpaper style (as the lock screen, centered shape, blurred), a wallpaper of its own, the
  status line under the clock, toolbars, monitor layout and input, Sync now and Preview.

## How it fits together

```
greetd ── hecate-greetd session            (as the `greeter` user)
            └─ hecate --config $XDG_RUNTIME_DIR/hecate-greetd/config.json
                 include = [ <greeter config from Nix>, "user.json" ]   ← selected user's
                 └─ autostart: hecate-greetd ui                          outputs/keyboard/...
                      └─ qs -p …/shell/greeter.qml   (HOME = a copy of the user's export)
                           exit 10: another user was picked → apply their layout, restart
                           exit 0:  greetd has the session → `hecate msg exit`
```

The greeter can't read home directories, so the user's shell shares what it needs:
`hecate-greetd sync` (run by the shell at startup and after any relevant change) copies the
shell config (image paths rewritten to copies), the generated colours, the avatar and the
compositor tables the login screen takes (`outputs`, `keyboard`, `input`, `cursor`, `blur`,
`animations`, read from the running hecate) into `/var/lib/hecate-greetd/users/<user>/`,
which the user owns and the `greeter` group reads. Snapshots are swapped atomically. hecate
writes its login splash pictures (`<output>.png`, wallpaper and shell, never windows) straight
to `splash/` in there when `splash.dir` points at it, at every lock and logout; the login
screen only uses them while the user shares their look.

Between the login screen and the session, the screen doesn't go dark: hecate leaves its last
frame up when it exits and starts without turning outputs off, and the NixOS module's
`hecate-greetd-hold-gpu` service keeps the GPU open in between, so the kernel doesn't put the
text console back. The login screen's last frame (your desktop picture) stays until the
session's first frame, the same picture, replaces it. greetd itself switches tty1 to text mode
before each session, so `services.hecate-greetd.hideConsole` (on by default) keeps the console
off tty1 (`fbcon=vc:2-63`); boot messages and the emergency shell go to tty2 (`console=tty2`,
Ctrl+Alt+F2).

The greeter treats an export as untrusted: it checks the owner, never follows symlinks, caps
sizes, takes only those compositor tables (no autostart, binds or environment), validates them
with `hecate validate`, works on a private copy and kills everything a UI instance started
when it exits.

If the shell-based login screen fails to start three times in a row (a broken config, a
missing Qt module), a minimal fallback greeter with no shell code takes over.

## NixOS

```nix
# flake.nix
inputs.hecate-greetd = {
  url = "github:Kex1016/hecate-greetd";
  inputs.hecate.follows = "hecate";   # the same hecate and shell your users run
};

# configuration.nix
imports = [ inputs.hecate.nixosModules.default inputs.hecate-greetd.nixosModules.default ];
programs.hecate.enable = true;
services.hecate-greetd.enable = true;   # turn SDDM / GDM off
```

Options (`services.hecate-greetd.*`):

| option | default | |
| --- | --- | --- |
| `users` | every `isNormalUser` | accounts offered, in order; each gets its export directory |
| `defaultUser` | first user | selected on the first start; after that the last to log in |
| `defaultSession` | `services.displayManager.defaultSession` | else `hecate` |
| `settings` | `{ }` | hecate config for the greeter's compositor, under each user's settings |
| `fonts`, `extraPackages` | the shell's fonts, Bibata, Breeze icons | installed system-wide, since users' profiles are out of the greeter's reach |
| `hecatePackage`, `shellPackage` | `programs.hecate.package`, the flake's shell | |

`services.displayManager.autoLogin` maps to greetd's `initial_session` (straight into hecate).
The PAM stack is greetd's (the system `login` stack); the gnome-keyring is unlocked with the
login password.

## Commands

```
hecate-greetd session      greetd's default_session command
hecate-greetd ui           the login screen, autostarted by the greeter's hecate
hecate-greetd sync [--json]   share your look (the shell runs it for you)
hecate-greetd preview      the login screen with your look, in your session; Escape closes it
hecate-greetd users | sessions   what the login screen offers, as JSON
```

## Development

`cargo test` for the Rust side. `nix build .#hecate-greetd --override-input hecate
path:../wl-hex` builds against a local hecate checkout, and `hecate-greetd preview` (from a
hecate session with the shell) shows the result without logging out.

License: GPL-3.0-or-later, like hecate and the shell it runs.
