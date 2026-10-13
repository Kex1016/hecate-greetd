//@ pragma ShellId hecate-greetd-fallback
//@ pragma Env QT_QUICK_CONTROLS_STYLE=Basic

// Used by `hecate-greetd ui` only when the real login screen keeps failing to start (a broken
// shell config, a missing Qt module): no shell code, just a way in.
import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Greetd

ShellRoot {
    id: root

    readonly property string runtimeDir: Quickshell.env("HECATE_GREETD_RUNTIME") ?? ""
    property var users: []
    property var sessions: []
    property int userIndex: 0
    property int sessionIndex: 0
    property string message: ""
    property bool busy: false
    property string pending: ""
    readonly property var user: users[userIndex] ?? null
    readonly property var session: sessions[sessionIndex] ?? null

    FileView {
        path: `${root.runtimeDir}/users.json`
        onLoaded: {
            try { root.users = JSON.parse(text()); } catch (e) {}
            const i = root.users.findIndex(u => u.name === Quickshell.env("HECATE_GREETD_USER"));
            root.userIndex = Math.max(0, i);
        }
    }
    FileView {
        path: `${root.runtimeDir}/sessions.json`
        onLoaded: {
            try { root.sessions = JSON.parse(text()); } catch (e) {}
            const i = root.sessions.findIndex(s => s.id === "hecate");
            root.sessionIndex = Math.max(0, i);
        }
    }
    FileView {
        id: resultFile
        path: `${root.runtimeDir}/result.json`
        preload: false
    }

    function submit(text) {
        if (!root.user || !Greetd.available) return;
        root.busy = true;
        root.message = "";
        root.pending = text;
        if (Greetd.state !== GreetdState.Inactive) Greetd.cancelSession();
        Greetd.createSession(root.user.name);
    }

    Connections {
        target: Greetd
        function onAuthMessage(message, error, responseRequired, echoResponse) {
            if (responseRequired) {
                Greetd.respond(root.pending);
                root.pending = "";
            } else {
                root.message = message;
            }
        }
        function onAuthFailure(message) {
            root.busy = false;
            root.message = "Login failed";
        }
        function onError(error) {
            root.busy = false;
            root.message = error;
        }
        function onReadyToLaunch() {
            resultFile.setText(JSON.stringify({ user: root.user.name, session: root.session?.id ?? "" }));
            const env = ["XDG_SESSION_TYPE=wayland", `XDG_SESSION_DESKTOP=${root.session.id}`];
            Greetd.launch(root.session.exec, env, true);
        }
    }

    Variants {
        model: Quickshell.screens
        delegate: PanelWindow {
            required property var modelData
            screen: modelData
            color: "#1b1b1f"
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.namespace: "hecate-greetd"
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
            anchors { top: true; bottom: true; left: true; right: true }

            Column {
                anchors.centerIn: parent
                spacing: 16
                width: 320

                Text {
                    id: clock
                    anchors.horizontalCenter: parent.horizontalCenter
                    color: "#e4e1e6"
                    font.pixelSize: 72
                    text: Qt.formatTime(new Date(), "hh:mm")
                    Timer {
                        interval: 1000; running: true; repeat: true
                        onTriggered: clock.text = Qt.formatTime(new Date(), "hh:mm")
                    }
                }
                ComboBox {
                    width: parent.width
                    model: root.users.map(u => u.displayName)
                    currentIndex: root.userIndex
                    onActivated: i => root.userIndex = i
                }
                ComboBox {
                    width: parent.width
                    model: root.sessions.map(s => s.name)
                    currentIndex: root.sessionIndex
                    onActivated: i => root.sessionIndex = i
                }
                TextField {
                    id: field
                    width: parent.width
                    focus: true
                    enabled: !root.busy
                    echoMode: TextInput.Password
                    placeholderText: "Password"
                    onAccepted: { root.submit(text); text = ""; }
                    Component.onCompleted: forceActiveFocus()
                }
                Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.Wrap
                    color: "#ffb4ab"
                    text: root.message
                }
                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 8
                    Button { text: "Sleep"; onClicked: Quickshell.execDetached(["systemctl", "suspend"]) }
                    Button { text: "Restart"; onClicked: Quickshell.execDetached(["systemctl", "reboot"]) }
                    Button { text: "Power off"; onClicked: Quickshell.execDetached(["systemctl", "poweroff"]) }
                }
            }
        }
    }
}
