//@ pragma UseQApplication
//@ pragma ShellId hecate-greetd
//@ pragma Env QS_NO_RELOAD_POPUP=1
//@ pragma Env QT_QUICK_CONTROLS_STYLE=Basic
//@ pragma Env QT_QUICK_FLICKABLE_WHEEL_DECELERATION=10000
//@ pragma Env QT_LOGGING_RULES=qt.text.font.db.info=false

// hecate-greetd's login screen. Installed next to the shell's shell.qml, so it is built
// from the shell's own parts: the haiiro kit, its tokens and its services.
import "modules/common"
import "modules/greeter"
import QtQuick
import Quickshell

ShellRoot {
    Greeter {}
}
