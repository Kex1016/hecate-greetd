pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Greetd
import qs
import qs.services
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.panels.lock
import qs.modules.ii.background

/**
 * The login screen: the shell's lock screen, locked from the start, for one user at a time.
 *
 * `hecate-greetd ui` starts this with HOME pointing at a copy of the selected user's export, so
 * Config, the colours and the wallpaper layer are theirs, and hecate already has their monitor
 * layout. Picking another user exits with code 10 and the supervisor starts a fresh instance
 * for them; logging in plays the unlock animation, fades into the user's desktop as hecate
 * last saved it (its login splash, which the session shows until its shell is up), then hands
 * the session to greetd. Once greetd has it, this instance tells hecate to exit while the
 * desktop picture is still up, so that is the frame hecate leaves on screen for the session
 * (exiting first would leave hecate's bare background there).
 */
Scope {
    id: root

    readonly property string runtimeDir: Quickshell.env("HECATE_GREETD_RUNTIME") ?? ""
    readonly property bool preview: (Quickshell.env("HECATE_GREETD_PREVIEW") ?? "") === "1"
    readonly property string user: Quickshell.env("HECATE_GREETD_USER") ?? ""
    // Running inside the greeter's own hecate (not a preview in a session).
    readonly property bool inCompositor: !root.preview && (Quickshell.env("HECATE_SOCKET") ?? "") !== ""
    readonly property string hecateBin: Quickshell.env("HECATE_GREETD_HECATE") ?? "hecate"

    property var users: []
    property var sessions: []
    property string session: ""
    readonly property var currentUser: root.users.find(u => u.name === root.user) ?? null
    readonly property var currentSession: root.sessions.find(s => s.id === root.session) ?? null

    // The shell's config is loaded and the greeter's own options applied.
    property bool ready: false
    // Toolbars and password field shown; false while appearing, logging in or switching.
    property bool shown: false
    // Shown once: what can wait for the first frame loads after it.
    property bool revealed: false
    // The monitor whose surface takes the keyboard.
    readonly property string keyboardScreen: Quickshell.screens[0]?.name ?? ""
    // Fading to black before another user's instance takes over.
    property bool leaving: false
    // Logged in: fading into the desktop picture before the session starts.
    property bool launching: false

    Component.onCompleted: {
        GlobalStates.greeterMode = true;
        GlobalStates.screenLocked = true;
        // A private copy, but nothing here should change the user's settings anyway.
        Config.blockWrites = true;
        if (Config.ready) root.applyOptions();
    }

    Connections {
        target: Config
        function onReadyChanged() {
            if (Config.ready) root.applyOptions();
        }
    }

    // The greeter's settings (Settings → hecate-greetd) on top of the lock screen's.
    function applyOptions() {
        if (root.ready) return;
        const g = Config.options.greeter;
        const bg = Config.options.background;
        const lock = Config.options.lock;
        if (g.style === "centered") {
            bg.centeredWallpaper = true;
        } else if (g.style === "blurred") {
            bg.centeredWallpaper = false;
            lock.blur.enable = true;
        }
        if (g.wallpaper !== "") bg.lockWall = g.wallpaper;
        lock.showLockedText = g.showStatusText;
        lock.showToolbars = g.showToolbars;
        GlobalStates.lockStatusText = g.statusText;
        MaterialThemeLoader.reapplyTheme();
        root.ready = true;
        // Let the wallpaper layer settle on the new options, then fade everything in.
        revealTimer.start();
    }

    Timer {
        id: revealTimer
        interval: 50
        onTriggered: {
            GlobalStates.startupLockPending = false;
            root.shown = true;
            root.revealed = true;
            greeterContext.begin();
        }
    }

    // ------------------------------------------------------------------ choices from the supervisor

    FileView {
        path: `${root.runtimeDir}/users.json`
        printErrors: false
        onLoaded: {
            try { root.users = JSON.parse(text()); } catch (e) { root.users = []; }
        }
    }
    FileView {
        path: `${root.runtimeDir}/sessions.json`
        printErrors: false
        onLoaded: {
            try { root.sessions = JSON.parse(text()); } catch (e) { root.sessions = []; }
        }
    }
    FileView {
        path: `${root.runtimeDir}/selection.json`
        printErrors: false
        onLoaded: {
            try {
                const sel = JSON.parse(text());
                if (root.session === "") root.session = sel.session ?? "";
            } catch (e) {}
        }
    }
    FileView {
        id: requestFile
        path: `${root.runtimeDir}/request.json`
        preload: false
        printErrors: false
        onSaved: switchTimer.start()
        onSaveFailed: switchTimer.start()
    }
    FileView {
        id: resultFile
        path: `${root.runtimeDir}/result.json`
        preload: false
        printErrors: false
    }
    // greetd has the session: the supervisor takes this instance going down as the login.
    FileView {
        id: launchedFile
        path: `${root.runtimeDir}/launched.json`
        preload: false
        printErrors: false
        onSaved: root.handOver()
        onSaveFailed: root.handOver()
    }

    // ------------------------------------------------------------------ actions

    function switchUser(name) {
        if (name === root.user || root.leaving || root.preview) return;
        greeterContext.end();
        root.shown = false;
        root.leaving = true;
        requestFile.setText(JSON.stringify({ user: name }));
    }

    Timer {
        id: switchTimer
        // The fade to black
        interval: 320
        onTriggered: Qt.exit(10)
    }

    function login() {
        if (!root.preview && Greetd.available && !root.currentSession) {
            greeterContext.fail(Translation.tr("No session to start"));
            greeterContext.end();
            greeterContext.begin();
            return;
        }
        resultFile.setText(JSON.stringify({ user: root.user, session: root.session }));
        // The lock screen's unlock: toolbars fade, the wallpaper comes out of its shape or blur.
        root.shown = false;
        GlobalStates.screenLocked = false;
        launchTimer.start();
    }

    Timer {
        id: launchTimer
        // As long as the centered wallpaper's grow (800 ms), which outlasts the blur's zoom.
        interval: 850
        onTriggered: {
            root.launching = true;
            handoffTimer.start();
        }
    }

    Timer {
        id: handoffTimer
        // The desktop picture's fade (GreeterSurface).
        interval: 320
        onTriggered: {
            if (root.preview || !Greetd.available) {
                Qt.exit(0);
                return;
            }
            const s = root.currentSession;
            const env = [`XDG_SESSION_TYPE=wayland`, `XDG_SESSION_DESKTOP=${s.id}`];
            if (s.desktopNames.length > 0) env.push(`XDG_CURRENT_DESKTOP=${s.desktopNames.join(":")}`);
            // Not quitting on launch: hecate goes first (handOver), with the picture still up.
            Greetd.launch(s.exec, env, false);
        }
    }

    // greetd accepted the session and waits for the greeter to exit. hecate exits on request
    // and leaves its last frame, the desktop picture, on screen; this instance goes with it.
    function handOver() {
        if (!root.inCompositor) {
            Qt.exit(0);
            return;
        }
        Quickshell.execDetached([root.hecateBin, "msg", "exit"]);
        exitTimer.start();
    }

    Timer {
        id: exitTimer
        // hecate didn't take the request: exit as before, and the supervisor tells it.
        interval: 2000
        onTriggered: Qt.exit(0)
    }

    GreeterContext {
        id: greeterContext
        user: root.user
        preview: root.preview

        onUnlocked: targetAction => {
            if (targetAction === LockContext.ActionEnum.Poweroff) {
                Session.poweroff();
            } else if (targetAction === LockContext.ActionEnum.Reboot) {
                Session.reboot();
            } else {
                root.login();
            }
        }
    }

    Connections {
        target: Greetd
        enabled: !root.preview && Greetd.available
        function onLaunched() {
            launchedFile.setText(JSON.stringify({ user: root.user, session: root.session }));
        }
        function onError(error) {
            // A launch greetd refused: come back so the user can try again.
            if (launchTimer.running || handoffTimer.running || !GlobalStates.screenLocked) {
                launchTimer.stop();
                handoffTimer.stop();
                root.launching = false;
                GlobalStates.screenLocked = true;
                root.shown = true;
            }
        }
    }

    // ------------------------------------------------------------------ surfaces

    LazyLoader {
        active: root.ready
        component: Background {}
    }

    Variants {
        model: Quickshell.screens
        delegate: GreeterSurface {
            context: greeterContext
            greeter: root
        }
    }
}
