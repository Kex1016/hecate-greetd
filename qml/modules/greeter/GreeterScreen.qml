pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.services
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets.haiiro as H

// The login screen on one monitor: the host top left, the clock top right, one login
// window and a strip along the bottom. Nothing is drawn behind them but the checker veil,
// so hecate's blobs show through. Every part pixelates in and out; the veil is a cut.
MouseArea {
    id: root

    required property var context
    required property var greeter

    readonly property bool shown: root.greeter.shown
    readonly property string host: SystemInfo.hostname.length > 0 ? SystemInfo.hostname : "cakeos"
    readonly property string distro: greeter.distro
    readonly property string hecateBin: Quickshell.env("HECATE_GREETD_HECATE") ?? "hecate"
    readonly property bool secretPrompt: root.context.secretPrompt
    readonly property string promptLabel: {
        // an account greetd asks nothing of
        if (root.context.ready) return "press enter";
        const asked = root.context.promptText;
        return asked === "" ? "password:" : asked.endsWith(":") ? asked : asked + ":";
    }
    readonly property string narrator: root.context.noticeText !== "" ? root.context.noticeText
        : root.greeter.users.length === 0 ? "The computer hums. Nobody here can log in."
        : "The computer hums. Who is there?"

    function forceFieldFocus() {
        passwordBox.forceActiveFocus();
    }
    Connections {
        target: root.context
        function onShouldReFocus() {
            root.forceFieldFocus();
        }
    }
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton
    onPressed: root.forceFieldFocus()
    onPositionChanged: root.forceFieldFocus()
    Component.onCompleted: root.forceFieldFocus()

    H.Veil {
        anchors.fill: parent
        visible: root.greeter.veiled
        blocking: false
    }

    // Host
    H.PixelTransition {
        x: H.HTokens.space20
        y: H.HTokens.space20
        shown: root.shown
        index: 0

        Row {
            spacing: H.HTokens.space4

            // the haiiro mark, at its own size: never smoothed
            Image {
                width: 128
                height: 128
                source: Qt.resolvedUrl("assets/haiiro-128.png")
                smooth: false
                mipmap: false
            }
            Column {
                anchors.verticalCenter: parent.verticalCenter
                H.HText {
                    role: "nav"
                    ink: "c5"
                    text: root.host
                }
                H.HText {
                    ink: "c1"
                    text: (root.distro.length > 0 ? root.distro + " · " : "") + "hecate"
                }
            }
        }
    }

    // Clock
    H.PixelTransition {
        anchors {
            right: parent.right
            rightMargin: H.HTokens.space20
        }
        y: H.HTokens.space20
        shown: root.shown
        index: 1

        Column {
            Item {
                anchors.right: parent.right
                width: clockText.implicitWidth
                height: clockText.implicitHeight

                // the hard offset under a display title: drawn outside the box, as a shadow is
                H.HText {
                    id: clockShadow
                    x: Appearance.haiiro.shadow.title.x
                    y: Appearance.haiiro.shadow.title.y
                    role: "display"
                    font.pixelSize: clockText.font.pixelSize
                    lineHeight: clockText.lineHeight
                    text: clockText.text
                    color: Appearance.haiiro.shadow.title.color
                }
                H.HText {
                    id: clockText
                    role: "display"
                    font.pixelSize: 120
                    // a display line is as tall as its type
                    lineHeight: 120
                    text: DateTime.time
                }
            }
            H.HText {
                anchors.right: parent.right
                ink: "c1"
                text: Qt.locale().toString(DateTime.clock.date, "ddd d MMM").toLowerCase()
            }
        }
    }

    // Login window
    H.PixelTransition {
        id: loginTransition
        anchors.horizontalCenter: parent.horizontalCenter
        y: Math.round(root.height * 380 / 900)
        shown: root.shown
        index: 2

        H.HWindow {
            id: loginWindow
            width: Math.min(600, root.width - 2 * H.HTokens.space6)
            label: "login: " + root.host
            body.spacing: 14
            hints: {
                const keys = [];
                if (root.greeter.users.length > 1) keys.push({ key: "tab", text: "user" });
                if (root.greeter.sessions.length > 1) keys.push({ key: "ctrl s", text: "session" });
                keys.push({ key: "enter", text: "log in" });
                return keys;
            }

            H.HText {
                Layout.fillWidth: true
                ink: "c4"
                wrapMode: Text.Wrap
                text: root.narrator
            }

            // who can log in
            Flow {
                Layout.fillWidth: true
                spacing: H.HTokens.space3
                visible: root.greeter.users.length > 0

                Repeater {
                    model: root.greeter.users
                    UserChip {}
                }
            }

            // the prompt line: @ user » password: ********█
            Item {
                id: promptLine
                Layout.fillWidth: true
                implicitHeight: H.HTokens.lineBox(H.HTokens.fontBody)
                readonly property string typed: root.context.currentText
                readonly property string shown: root.secretPrompt ? "*".repeat(typed.length) : typed
                readonly property int gap: H.HTokens.ch()

                Row {
                    id: promptHead
                    spacing: promptLine.gap
                    H.HText { text: "@"; ink: "c2" }
                    H.HText { text: root.greeter.user; ink: "c6" }
                    H.HText { text: "»"; ink: "c4" }
                    H.HText { text: root.promptLabel; ink: "c3" }
                }
                H.HText {
                    id: typedText
                    x: promptHead.width + promptLine.gap
                    width: Math.max(0, parent.width - x - cursor.width)
                    ink: "c7"
                    text: promptLine.shown
                    elide: Text.ElideLeft
                    font.letterSpacing: root.secretPrompt ? 2 : 0
                }
                Rectangle {
                    id: cursor
                    x: Math.min(promptHead.width + promptLine.gap + typedText.contentWidth, promptLine.width - width)
                    anchors.verticalCenter: parent.verticalCenter
                    width: H.HTokens.ch()
                    height: H.HTokens.fontBody
                    color: H.HTokens.text
                    // a steady block, it never blinks; gone while greetd checks the answer
                    visible: !root.context.busy
                }

                // the real field: invisible, it only takes the keys
                TextInput {
                    id: passwordBox
                    width: 1
                    height: 1
                    opacity: 0
                    enabled: !root.context.busy
                    echoMode: root.secretPrompt ? TextInput.Password : TextInput.Normal
                    inputMethodHints: root.secretPrompt ? Qt.ImhSensitiveData : Qt.ImhNone
                    onTextChanged: root.context.currentText = text
                    onAccepted: if (!root.greeter.launching) root.context.submit()
                    onEnabledChanged: if (enabled) root.forceFieldFocus()
                    Connections {
                        target: root.context
                        function onCurrentTextChanged() {
                            passwordBox.text = root.context.currentText;
                        }
                    }
                    Keys.onPressed: event => {
                        root.context.resetClearTimer();
                        const ctrl = event.modifiers & Qt.ControlModifier;
                        if (event.key === Qt.Key_Tab) {
                            root.greeter.cycleUser(1);
                        } else if (event.key === Qt.Key_Backtab) {
                            root.greeter.cycleUser(-1);
                        } else if (ctrl && event.key === Qt.Key_S) {
                            root.greeter.cycleSession(event.modifiers & Qt.ShiftModifier ? -1 : 1);
                        } else if (event.key === Qt.Key_Escape) {
                            root.context.clearText();
                        } else {
                            return;
                        }
                        event.accepted = true;
                    }
                }
            }

            // what to log into
            Flow {
                Layout.fillWidth: true
                spacing: H.HTokens.space2
                visible: root.greeter.sessions.length > 0

                H.HLabel {
                    height: sessionProbe.implicitHeight
                    rightPadding: H.HTokens.space2
                    text: "session"
                }
                Repeater {
                    model: root.greeter.sessions
                    H.Chip {
                        required property var modelData
                        text: modelData.name.toLowerCase()
                        on: modelData.id === root.greeter.session
                        interactive: true
                        activeFocusOnTab: false
                        onClicked: root.greeter.session = modelData.id
                    }
                }
                // a chip's height, for the label to centre on
                H.Chip {
                    id: sessionProbe
                    visible: false
                    text: "x"
                }
            }
        }
    }

    // Wrong password
    H.PixelTransition {
        anchors.horizontalCenter: parent.horizontalCenter
        y: loginTransition.y + loginWindow.height + 20
        shown: root.shown && root.context.showFailure
        animateOnLoad: false

        H.HWindow {
            width: loginWindow.width
            variant: "love"
            label: loginWindow.label

            RowLayout {
                Layout.fillWidth: true
                spacing: H.HTokens.ch()
                H.HText { text: "@"; ink: "c2" }
                H.HText { text: root.greeter.user; ink: "c6" }
                H.HText { text: "»"; ink: "c4" }
                H.HText {
                    Layout.fillWidth: root.context.failureText !== ""
                    ink: "c2"
                    elide: Text.ElideRight
                    text: root.context.failureText !== "" ? root.context.failureText : "That's not it."
                }
                H.HText {
                    ink: "c1"
                    text: "Try again."
                    visible: root.context.failureText === ""
                }
                Item {
                    Layout.fillWidth: true
                    visible: root.context.failureText === ""
                }
            }
        }
    }

    // Bottom strip
    H.PixelTransition {
        anchors {
            left: parent.left
            right: parent.right
            bottom: parent.bottom
            leftMargin: H.HTokens.space6
            rightMargin: H.HTokens.space6
            bottomMargin: 20
        }
        height: strip.implicitHeight
        shown: root.shown
        index: 3

        RowLayout {
            id: strip
            width: parent.width
            spacing: H.HTokens.space4

            readonly property string layout: (WM.niriLike ? NiriXkb.currentLayoutCode : HyprlandXkb.currentLayoutCode) ?? ""
            readonly property bool wifiUp: Network.wifiEnabled && Network.wifiStatus === "connected"
            readonly property bool netUp: Network.ethernet || strip.wifiUp

            // keyboard layout; a click takes the next one
            H.HText {
                visible: text.length > 0
                text: strip.layout.toLowerCase()
                MouseArea {
                    anchors.fill: parent
                    enabled: root.greeter.inCompositor
                    cursorShape: Qt.PointingHandCursor
                    onClicked: Quickshell.execDetached([root.hecateBin, "msg", "keyboard-layout", "next"])
                }
            }
            // network: "wlan 72", "eth up", "net off"
            Row {
                spacing: H.HTokens.ch()
                H.HText {
                    text: Network.ethernet ? "eth" : strip.wifiUp || Network.wifiStatus === "connecting" ? "wlan" : "net"
                }
                H.HText {
                    ink: strip.netUp ? "c6" : "c1"
                    text: Network.ethernet ? "up"
                        : strip.wifiUp ? String(Network.active?.strength ?? Network.networkStrength ?? 0)
                        : Network.wifiStatus === "connecting" ? "…"
                        : Network.wifiStatus === "disabled" ? "off" : "—"
                }
            }
            // battery
            Row {
                visible: Battery.available
                spacing: H.HTokens.ch()
                H.HText { text: Battery.isCharging ? "chg" : "bat" }
                H.HText {
                    text: Math.round(Battery.percentage * 100) + "%"
                    ink: Battery.isLow && !Battery.isCharging ? "c2" : "c6"
                }
            }

            Item { Layout.fillWidth: true }

            // nobody is logged in: these need no password
            H.InkButton {
                ink: "c1"
                text: "sleep"
                activeFocusOnTab: false
                onClicked: Session.suspend()
            }
            H.InkButton {
                ink: "c3"
                text: "reboot"
                activeFocusOnTab: false
                enabled: !root.greeter.preview
                onClicked: Session.reboot()
            }
            H.InkButton {
                ink: "c2"
                text: "shutdown"
                activeFocusOnTab: false
                enabled: !root.greeter.preview
                onClicked: Session.poweroff()
            }
        }
    }

    // One account: the selected one on overlay with the narrator's mark, the others in a
    // dashed frame. A click picks it.
    component UserChip: Item {
        id: chip

        required property var modelData
        readonly property bool current: chip.modelData.name === root.greeter.user
        readonly property string avatar: chip.modelData.avatar ?? ""

        implicitWidth: chipRow.implicitWidth + 20
        implicitHeight: chipRow.implicitHeight + 12

        Rectangle {
            anchors.fill: parent
            visible: chip.current
            color: H.HTokens.overlay
        }
        H.HDashFrame {
            anchors.fill: parent
            visible: !chip.current
            dashed: true
            color: H.HTokens.inkHairline
        }

        Row {
            id: chipRow
            x: 10
            y: 6
            spacing: H.HTokens.space2

            H.HText {
                anchors.verticalCenter: parent.verticalCenter
                visible: chip.current
                text: "»"
                ink: "c4"
            }
            H.Dither {
                width: 32
                height: 32
                tone: chip.current ? "pine" : "lo"

                Image {
                    anchors.fill: parent
                    visible: status === Image.Ready
                    source: chip.avatar !== "" ? `file://${chip.avatar}` : ""
                    sourceSize: Qt.size(32, 32)
                    fillMode: Image.PreserveAspectCrop
                    smooth: false
                    asynchronous: true
                }
            }
            H.HText {
                anchors.verticalCenter: parent.verticalCenter
                text: chip.modelData.name
                ink: chip.current ? "c5" : "c1"
            }
        }

        MouseArea {
            anchors.fill: parent
            enabled: !chip.current
            cursorShape: Qt.PointingHandCursor
            onClicked: root.greeter.switchUser(chip.modelData.name)
        }
    }
}
