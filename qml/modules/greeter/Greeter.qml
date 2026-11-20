pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Greetd
import qs
import qs.modules.common
import qs.modules.common.widgets.haiiro as H

/**
 * The login screen.
 *
 * It draws no background. hecate's blobs run behind it for every user, under the checker
 * veil, and the rest is the haiiro kit: the host, the clock, one login window and a strip
 * along the bottom. `hecate-greetd ui` starts it and hands it who can log in and into what;
 * picking another user writes `request.json`, and the supervisor gives hecate that user's
 * keyboard and monitor layout while this keeps running.
 *
 * Logging in pixelates everything away and lifts the veil, so the blobs alone are left, then
 * hands the session to greetd. Once greetd has it the supervisor tells hecate to exit: hecate
 * leaves that frame on screen and writes down where its blobs were, and the session's hecate
 * carries on from there with its first frame.
 */
Scope {
    id: root

    readonly property string runtimeDir: Quickshell.env("HECATE_GREETD_RUNTIME") ?? ""
    readonly property bool preview: (Quickshell.env("HECATE_GREETD_PREVIEW") ?? "") === "1"
    // Running inside the greeter's own hecate (not a preview in a session).
    readonly property bool inCompositor: !root.preview && (Quickshell.env("HECATE_SOCKET") ?? "") !== ""

    property var users: []
    property var sessions: []
    property string user: Quickshell.env("HECATE_GREETD_USER") ?? ""
    property string session: ""
    // The session each user logged into last.
    property var lastSessions: ({})
    readonly property var currentUser: root.users.find(u => u.name === root.user) ?? null
    readonly property var currentSession: root.sessions.find(s => s.id === root.session) ?? null

    // The system's name as os-release has it ("CakeOS"), without the version.
    property string distro: ""

    // The shell's config is loaded: the clock has its format.
    property bool ready: false
    // The parts are on screen; false while appearing and once a login goes through.
    property bool shown: false
    // The checker over the blobs. Lifted before the session starts, so the last frame is
    // the blobs alone.
    property bool veiled: false
    // Logged in: on the way out.
    property bool launching: false
    // The monitor whose surface takes the keyboard.
    readonly property string keyboardScreen: Quickshell.screens[0]?.name ?? ""
    // Host, clock, window, strip: each pixelates one stagger after the one before.
    readonly property int parts: 4
    readonly property int leaveMs: H.HTokens.cut ? 0 : H.HTokens.pixelateDuration + (root.parts - 1) * H.HTokens.pixelateStagger

    Component.onCompleted: {
        GlobalStates.greeterMode = true;
        // Nothing here should write a setting.
        Config.blockWrites = true;
        if (Config.ready) root.reveal();
    }

    Connections {
        target: Config
        function onReadyChanged() {
            if (Config.ready) root.reveal();
        }
    }

    // A config that never loads doesn't keep anyone out.
    Timer {
        interval: 3000
        running: !root.ready
        onTriggered: root.reveal()
    }

    function reveal() {
        if (root.ready) return;
        root.ready = true;
        root.veiled = true;
        root.shown = true;
        greeterContext.begin();
    }

    // ------------------------------------------------------------------ choices from the supervisor

    FileView {
        path: "/etc/os-release"
        printErrors: false
        onLoaded: {
            const name = text().match(/^NAME=(.*)$/m);
            root.distro = name ? name[1].trim().replace(/^["']|["']$/g, "") : "";
        }
    }
    FileView {
        path: `${root.runtimeDir}/users.json`
        printErrors: false
        onLoaded: {
            try { root.users = JSON.parse(text()); } catch (e) { root.users = []; }
            if (root.user === "" && root.users.length > 0) root.user = root.users[0].name;
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
                root.lastSessions = sel.sessions ?? {};
                if (root.session === "") root.session = sel.session ?? "";
            } catch (e) {}
        }
    }
    FileView {
        id: requestFile
        path: `${root.runtimeDir}/request.json`
        preload: false
        printErrors: false
    }
    FileView {
        id: resultFile
        path: `${root.runtimeDir}/result.json`
        preload: false
        printErrors: false
    }
    // greetd has the session: the supervisor sees this file, remembers the login and tells
    // hecate to exit with the blobs alone on screen; this instance goes down with it.
    FileView {
        id: launchedFile
        path: `${root.runtimeDir}/launched.json`
        preload: false
        printErrors: false
        onSaved: root.handOver()
        onSaveFailed: root.handOver()
    }

    // ------------------------------------------------------------------ actions

    property int requests: 0

    function switchUser(name) {
        if (name === root.user || root.launching || root.preview) return;
        if (!root.users.some(u => u.name === name)) return;
        root.user = name;
        const last = root.lastSessions[name] ?? "";
        if (root.sessions.some(s => s.id === last)) root.session = last;
        // The supervisor gives hecate this user's keyboard and monitors.
        root.requests += 1;
        requestFile.setText(JSON.stringify({ user: name, seq: root.requests }));
    }

    function cycleUser(step) {
        const n = root.users.length;
        if (n < 2) return;
        const i = Math.max(0, root.users.findIndex(u => u.name === root.user));
        root.switchUser(root.users[(i + step + n) % n].name);
    }

    function cycleSession(step) {
        const n = root.sessions.length;
        if (n < 2 || root.launching) return;
        const i = Math.max(0, root.sessions.findIndex(s => s.id === root.session));
        root.session = root.sessions[(i + step + n) % n].id;
    }

    function login() {
        if (greeterContext.live && !root.currentSession) {
            greeterContext.fail("There is no session to start.");
            greeterContext.begin();
            return;
        }
        resultFile.setText(JSON.stringify({ user: root.user, session: root.session }));
        root.launching = true;
        root.shown = false;
        leaveTimer.start();
    }

    Timer {
        id: leaveTimer
        // Every part has pixelated out.
        interval: root.leaveMs
        onTriggered: {
            root.veiled = false;
            launchTimer.start();
        }
    }

    Timer {
        id: launchTimer
        // A few frames of the blobs alone, so that is what hecate has on screen when it goes.
        interval: 100
        onTriggered: {
            if (!greeterContext.live) {
                Qt.exit(0);
                return;
            }
            const s = root.currentSession;
            const env = [`XDG_SESSION_TYPE=wayland`, `XDG_SESSION_DESKTOP=${s.id}`];
            if (s.desktopNames.length > 0) env.push(`XDG_CURRENT_DESKTOP=${s.desktopNames.join(":")}`);
            // Not quitting on launch: hecate goes first (handOver), this goes with it.
            Greetd.launch(s.exec, env, false);
        }
    }

    // greetd accepted the session and waits for the greeter to exit. The supervisor asks
    // hecate to, and this instance goes with it. Outside hecate, or when nothing asked it
    // within a moment, exit as any greeter would.
    function handOver() {
        if (!root.inCompositor) {
            Qt.exit(0);
            return;
        }
        exitTimer.start();
    }

    Timer {
        id: exitTimer
        interval: 2000
        onTriggered: Qt.exit(0)
    }

    GreeterContext {
        id: greeterContext
        user: root.user
        preview: root.preview
        onAuthenticated: root.login()
    }

    Connections {
        target: Greetd
        enabled: greeterContext.live
        function onLaunched() {
            launchedFile.setText(JSON.stringify({ user: root.user, session: root.session }));
        }
        function onError(error) {
            // A launch greetd refused: come back so the user can try again.
            if (!root.launching) return;
            leaveTimer.stop();
            launchTimer.stop();
            root.launching = false;
            root.veiled = true;
            root.shown = true;
        }
    }

    // ------------------------------------------------------------------ surfaces

    Variants {
        model: Quickshell.screens
        delegate: GreeterSurface {
            context: greeterContext
            greeter: root
        }
    }
}
