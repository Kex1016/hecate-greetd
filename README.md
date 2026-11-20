# hecate-greetd

A [greetd](https://sr.ht/~kennylevinsen/greetd/) greeter for
[hecate](https://github.com/Kex1016/hecate). The login screen is the haiiro greeter, a QuickShell
entry point that runs inside hecate on the same animated blob background as the desktop.

- **Always the blobs.** The greeter draws no wallpaper and no colours of its own. hecate's
  blob background shows for every user, always moving. The NixOS module forces
  `background.blobs` on (and `splash` off), whatever `settings` says.
- **One look for everyone.** The screen is built from the haiiro kit: the logo block with host,
  distro and session, the clock, the `login:` window with the user row, the prompt, session
  chips, key hints, the status line and sleep / reboot / shutdown. Nothing of the selected
  user's look is read: no wallpaper, colours or shell config.
- **The selected user's monitors and input.** Their hecate `outputs` (mode, refresh rate,
  scale, orientation, position, VRR), keyboard, input and cursor settings are merged into the
  greeter's compositor config the moment they are picked. hecate hot-plugs them, so a monitor
  plugged in later gets that user's layout. Picking another user never restarts the UI.
- **Configured from the shell.** Settings → hecate-greetd (next to hecate): sharing on or off,
  the monitor layout and input the login screen takes, and Sync now and Preview.

## How it fits together

```
greetd ── hecate-greetd session            (as the `greeter` user)
            └─ hecate --config $XDG_RUNTIME_DIR/hecate-greetd/config.json
                 include = [ <greeter config from Nix>, "user.json" ]   ← selected user's
                 └─ autostart: hecate-greetd ui                          outputs/keyboard/...
                      └─ qs -p …/shell/greeter.qml
                           another user picked: apply their layout, reload hecate
                           greetd accepted a session: remember the login, then
                           `hecate msg exit` while the blobs are still on screen
```

The greeter can't read home directories, so the user's shell shares what it needs:
`hecate-greetd sync` (run by the shell at startup and after any relevant change) copies the
compositor tables the login screen takes (`outputs`, `keyboard`, `input`, `cursor`) from the
running hecate into `/var/lib/hecate-greetd/users/<user>/`, which the user owns and the
`greeter` group reads. Snapshots are swapped atomically, and old copies of wallpapers, colours
and splash pictures are pruned. Nothing else of the user's leaves their home.

The greeter treats an export as untrusted: it checks the owner, never follows symlinks, caps
sizes, takes only those compositor tables (no autostart, binds or environment), validates them
with `hecate validate`, works on a private copy and kills everything a UI instance started when
it exits.

### The blobs carry over the login

- **Login.** When greetd accepts the session, the UI pixelates out so only the blobs are on
  screen. The greeter's hecate then exits and writes its blob simulations to
  `/run/hecate-greetd/blobs.json` (`background.blobs.save`). The session's hecate resumes from
  that file (`background.blobs.resume`), so its first frame is the next blob frame.
- **Logout.** A session whose hecate saves its blobs to
  `/var/lib/hecate-greetd/users/<user>/blobs.json` leaves them there, and the greeter's hecate
  carries on from them. The greeter reads that file only if a session has run since boot and the
  file is the user's own and looks like hecate's.
- **No splash.** With the blob background on, hecate draws no login splash: no picture is
  decoded or held, and the first frame doesn't wait for the shell.

### The first frame does not go black

The session takes over the monitors with a page flip rather than a modeset: hecate reads what
the CRTC shows when it takes the output over (format, modifier, VRR) and keeps VRR on for its
first commit, so the refresh timing doesn't change at login. Gamma is not reset when no table is
set. The journal says what happened, once per output:

```
first frame on DP-1 committed in 9 ms (flipped onto the mode already on screen, no modeset)
first frame on DP-1 kept what was on screen: AB30 0x…, VRR on
```

Check it after a login with `journalctl -b -t hecate | grep 'first frame'`. If a frame still goes
black, `sudo hecate-handover-capture`, then log out and in: the capture (planes before and
after, both journals, every atomic commit the kernel saw in between) is written to
`/var/log/hecate-handover-capture.log`. It needs a kernel with the DRM debug switch and turns
its output off again after the first frame or five minutes.

Between the login screen and the session the GPU stays open (`hecate-greetd-hold-gpu`), so the
kernel doesn't put the text console back. greetd switches tty1 to text mode before each session,
so `services.hecate-greetd.hideConsole` (on by default) keeps the console off tty1
(`fbcon=vc:2-63`); boot messages and the emergency shell go to tty2 (Ctrl+Alt+F2).

Two behaviours worth knowing:

- An account without a password is not logged in by being selected. greetd reports it ready at
  once, and the greeter waits at `press enter`. A notice from PAM (a fingerprint reader) or an
  answered prompt counts as the user's part.
- After a cancel (switching user) the greeter waits 300 ms before the next session. greetd's
  answers don't say which request they answer, so without the wait a switch could log the new
  user in with no password. QuickShell logs `Received unexpected greetd response success` after
  each cancel; that line is harmless.

If the greeter fails to start three times in a row (a broken config, a missing Qt module), a
minimal fallback greeter with no shell code takes over.

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
| `settings` | `{ }` | hecate config for the greeter's compositor, under each user's outputs, keyboard, input and cursor. The background is not set here: it is always the blobs |
| `shellSettings` | `{ }` | settings of the bundled shell for the login screen, e.g. `{ time.format = "h:mm AP"; }`. Nothing of a user's is read |
| `fonts` | the haiiro set from the hecate flake | installed system-wide with their fontconfig file, so the fallback order holds for every program. IBM VGA 8x16, Jacquard 24, GNU Unifont as fallback |
| `hideConsole` | `true` | keeps the text console off tty1 (see above) |
| `extraPackages` | `[ ]` | packages the login screen needs, installed system-wide. Add the cursor theme your `settings.cursor` names |
| `hecatePackage`, `shellPackage` | `programs.hecate.package`, the flake's shell | |

Give the greeter the haiiro pixel cursor before anyone has synced:

```nix
services.hecate-greetd = {
  extraPackages = [ /* the haiiro cursor package */ ];
  settings.cursor = { theme = "haiiro"; size = 24; };
};
```

`services.displayManager.autoLogin` maps to greetd's `initial_session` (straight into hecate).
The PAM stack is greetd's (the system `login` stack); the gnome-keyring is unlocked with the
login password.

The module also puts `hecate-handover-capture` on the system path (see above) and creates
`/run/hecate-greetd` for the greeter's blob file.

## Commands

```
hecate-greetd session         greetd's default_session command
hecate-greetd ui              the login screen, autostarted by the greeter's hecate
hecate-greetd sync [--json]   share your monitors and input with the login screen (the shell runs it)
hecate-greetd preview         the login screen in your session; Escape closes it
hecate-greetd users | sessions   what the login screen offers, as JSON
```

## Development

`cargo test` for the Rust side. `nix build .#hecate-greetd --override-input hecate
path:../hecate` builds against a local hecate checkout, and `hecate-greetd preview` (from a
hecate session with the shell) shows the greeter without logging out.

License: GPL-3.0-or-later, like hecate and the shell it runs.
