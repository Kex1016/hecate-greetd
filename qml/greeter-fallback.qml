//@ pragma ShellId hecate-greetd-fallback

// Used by `hecate-greetd ui` only when the real login screen keeps failing to start (a broken
// shell config, a missing Qt module): no shell code, just a way in. One haiiro window over
// hecate's blobs, with the tokens written out.
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Greetd

ShellRoot {
    id: root

    readonly property color surface: "#1f1d2e"
    readonly property color muted: "#6e6a86"
    readonly property color ink: "#e0def4"
    readonly property color love: "#eb6f92"
    readonly property color gold: "#f6c177"
    readonly property color rose: "#ebbcba"
    readonly property color pine: "#31748f"
    readonly property color foam: "#9ccfd8"
    readonly property color iris: "#c4a7e7"

    readonly property string runtimeDir: Quickshell.env("HECATE_GREETD_RUNTIME") ?? ""
    property var users: []
    property var sessions: []
    property int userIndex: 0
    property int sessionIndex: 0
    property string typed: ""
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
    // Tells the supervisor who is selected, so hecate gets their keyboard and monitors.
    FileView {
        id: requestFile
        path: `${root.runtimeDir}/request.json`
        preload: false
    }
    property int requests: 0

    function nextUser() {
        if (root.users.length < 2) return;
        root.userIndex = (root.userIndex + 1) % root.users.length;
        root.requests += 1;
        requestFile.setText(JSON.stringify({ user: root.user.name, seq: root.requests }));
    }

    function submit() {
        if (!root.user || !Greetd.available || root.busy) return;
        root.busy = true;
        root.message = "";
        root.pending = root.typed;
        root.typed = "";
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
            root.message = "That's not it. Try again.";
        }
        function onError(error) {
            root.busy = false;
            root.message = error;
        }
        function onReadyToLaunch() {
            if (!root.session) {
                root.busy = false;
                root.message = "There is no session to start.";
                return;
            }
            resultFile.setText(JSON.stringify({ user: root.user.name, session: root.session.id }));
            const env = ["XDG_SESSION_TYPE=wayland", `XDG_SESSION_DESKTOP=${root.session.id}`];
            Greetd.launch(root.session.exec, env, true);
        }
    }

    component Line: Text {
        color: root.ink
        font.family: "IBM VGA 8x16"
        font.pixelSize: 16
        renderType: Text.NativeRendering
        textFormat: Text.PlainText
    }
    component Action: Rectangle {
        id: action
        property alias text: caption.text
        signal clicked()
        implicitWidth: caption.implicitWidth + 16
        implicitHeight: caption.implicitHeight
        Line {
            id: caption
            x: 8
            color: root.surface
        }
        MouseArea {
            anchors.fill: parent
            onClicked: action.clicked()
        }
    }

    Variants {
        model: Quickshell.screens
        delegate: PanelWindow {
            id: surface
            required property var modelData
            screen: modelData
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.namespace: "hecate-greetd"
            WlrLayershell.keyboardFocus: Quickshell.screens[0]?.name === surface.modelData.name ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
            anchors { top: true; bottom: true; left: true; right: true }

            Rectangle {
                id: pane
                anchors.centerIn: parent
                width: Math.min(600, parent.width - 48)
                height: lines.implicitHeight + 40
                color: root.surface

                // the double frame: two 2px rings, 1px apart
                Repeater {
                    model: [0, 3]
                    Rectangle {
                        required property int modelData
                        x: modelData
                        y: modelData
                        width: pane.width - 2 * modelData
                        height: pane.height - 2 * modelData
                        color: "transparent"
                        border.width: 2
                        border.color: root.pine
                    }
                }
                Rectangle {
                    x: 20
                    y: -4
                    width: label.implicitWidth + 16
                    height: label.implicitHeight
                    color: root.surface
                    Line {
                        id: label
                        x: 8
                        text: "login"
                    }
                }

                Column {
                    id: lines
                    x: 20
                    y: 20
                    width: pane.width - 40
                    spacing: 14

                    Line {
                        width: parent.width
                        wrapMode: Text.Wrap
                        color: root.rose
                        text: "The usual login screen did not start. This one will do."
                    }
                    Row {
                        spacing: 8
                        Line { text: "@"; color: root.love }
                        Line { text: root.user?.name ?? "nobody"; color: root.foam }
                        Line { text: "»"; color: root.rose }
                        Line { text: "password:"; color: root.gold }
                        Line { text: "*".repeat(root.typed.length); color: root.iris }
                        Rectangle {
                            width: 8
                            height: 16
                            color: root.ink
                            visible: !root.busy
                        }
                    }
                    Row {
                        spacing: 8
                        Line { text: "session"; color: root.muted }
                        Line { text: (root.session?.name ?? "none").toLowerCase() }
                    }
                    Line {
                        width: parent.width
                        wrapMode: Text.Wrap
                        visible: text.length > 0
                        color: root.love
                        text: root.message
                    }
                    Line {
                        color: root.muted
                        text: "tab user · ctrl s session · enter log in"
                    }
                    Item {
                        width: parent.width
                        height: 16
                        Row {
                            anchors.right: parent.right
                            spacing: 16
                            Action { text: "sleep"; color: root.muted; onClicked: Quickshell.execDetached(["systemctl", "suspend"]) }
                            Action { text: "reboot"; color: root.gold; onClicked: Quickshell.execDetached(["systemctl", "reboot"]) }
                            Action { text: "shutdown"; color: root.love; onClicked: Quickshell.execDetached(["systemctl", "poweroff"]) }
                        }
                    }
                }

                // the real field: invisible, it only takes the keys
                TextInput {
                    id: field
                    width: 1
                    height: 1
                    opacity: 0
                    focus: true
                    enabled: !root.busy
                    echoMode: TextInput.Password
                    onTextChanged: root.typed = text
                    onAccepted: root.submit()
                    onEnabledChanged: if (enabled) forceActiveFocus()
                    Component.onCompleted: forceActiveFocus()
                    Connections {
                        target: root
                        function onTypedChanged() {
                            field.text = root.typed;
                        }
                    }
                    Keys.onPressed: event => {
                        if (event.key === Qt.Key_Tab) {
                            root.nextUser();
                        } else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_S && root.sessions.length > 0) {
                            root.sessionIndex = (root.sessionIndex + 1) % root.sessions.length;
                        } else {
                            return;
                        }
                        event.accepted = true;
                    }
                }
            }
        }
    }
}
