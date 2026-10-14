pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland
import qs
import qs.modules.common
import qs.modules.ii.lock

/**
 * One monitor's password surface: the shell's LockSurface on an overlay layer, where the shell
 * would put it in a session-lock surface. The wallpaper layer (Background) is underneath, as it
 * is under the shell's lock on hecate.
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
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }

    // Like the lock's Loader: created when it shows (so the toolbars pop in), faded in and out.
    Loader {
        id: lockLoader
        anchors.fill: parent
        active: surface.greeter.ready
        // Not `visible: opacity > 0`: hidden items can't take keyboard focus.
        opacity: surface.greeter.shown ? 1 : 0
        Behavior on opacity {
            animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
        }
        sourceComponent: LockSurface {
            context: surface.context
            userComponent: GreeterUserPicker {
                greeter: surface.greeter
            }
        }
    }

    // The user's desktop as hecate last saved it (copied in by the supervisor), faded in once
    // the unlock has brought the wallpaper to full screen: the session shows the same picture
    // from its first frame until its shell is up. None saved yet: the plain unlock.
    Image {
        anchors.fill: parent
        source: `file://${Quickshell.env("XDG_STATE_HOME")}/hecate/snapshots/${surface.modelData.name}.png`
        asynchronous: true
        cache: false
        opacity: surface.greeter.launching && status === Image.Ready ? 1 : 0
        visible: opacity > 0
        Behavior on opacity {
            NumberAnimation {
                duration: 300
                easing.type: Easing.OutCubic
            }
        }
    }

    // Between two users' instances.
    Rectangle {
        anchors.fill: parent
        color: "black"
        opacity: surface.greeter.leaving ? 1 : 0
        visible: opacity > 0
        Behavior on opacity {
            NumberAnimation {
                duration: 300
                easing.type: Easing.OutCubic
            }
        }
    }

    // `hecate-greetd preview` runs in your session: Escape closes it.
    Shortcut {
        enabled: surface.greeter.preview
        sequence: "Escape"
        onActivated: Qt.exit(0)
    }
}
