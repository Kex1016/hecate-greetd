pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland

/**
 * One monitor's login screen: a clear overlay layer. What shows behind it is hecate's own
 * background, the blobs.
 */
PanelWindow {
    id: surface

    required property var modelData
    required property var context
    required property var greeter

    screen: modelData
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "hecate-greetd"
    // One surface takes the keyboard, as one session-lock surface would: hecate gives an
    // exclusive layer surface the keyboard on every commit, so two of them (one per monitor)
    // would pass it back and forth with each frame and lose keystrokes in between. What is
    // typed shows on every monitor through the shared context.
    WlrLayershell.keyboardFocus: surface.greeter.keyboardScreen === surface.modelData.name ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }

    Loader {
        anchors.fill: parent
        active: surface.greeter.ready
        sourceComponent: GreeterScreen {
            context: surface.context
            greeter: surface.greeter
        }
    }

    // `hecate-greetd preview` runs in your session: Escape closes it.
    Shortcut {
        enabled: surface.greeter.preview
        sequence: "Escape"
        onActivated: Qt.exit(0)
    }
}
