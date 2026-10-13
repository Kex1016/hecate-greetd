pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Services.Greetd
import qs
import qs.modules.common
import qs.modules.common.panels.lock

/**
 * The lock screen's LockContext, for greetd: the same properties and signals, so the shell's
 * LockSurface runs on it unchanged, with greetd's PAM conversation in place of the shell's.
 *
 * A greetd session is opened for the selected user as soon as the screen shows, so prompts
 * that come first (a fingerprint reader, a notice) appear without typing anything. What the
 * user types answers the next secret prompt, which for most logins is the password.
 */
Scope {
    id: root

    signal shouldReFocus()
    signal unlocked(targetAction: var)
    signal failed()

    readonly property bool greeter: true
    // Who logs in, and whether greetd is there at all (it isn't in `hecate-greetd preview`).
    property string user: ""
    property bool preview: false
    readonly property bool live: !root.preview && Greetd.available

    property string currentText: ""
    property bool unlockInProgress: false
    property bool showFailure: false
    property bool fingerprintsConfigured: false
    property var targetAction: LockContext.ActionEnum.Unlock
    property bool alsoInhibitIdle: false

    // Shown as the field's placeholder: a prompt that isn't the usual password one ("Verification
    // code:", "Place your finger on the reader"), and the reason a login failed.
    property string promptText: ""
    property string failureText: ""
    property bool secretPrompt: true

    property bool awaitingResponse: false
    property bool submitPending: false

    function resetTargetAction() {
        root.targetAction = LockContext.ActionEnum.Unlock;
    }
    function clearText() {
        root.currentText = "";
    }
    function resetClearTimer() {
        passwordClearTimer.restart();
    }
    function reset() {
        root.resetTargetAction();
        root.clearText();
        if (!root.submitPending) root.unlockInProgress = false;
    }
    function tryFingerUnlock() {}
    function stopFingerPam() {}

    Timer {
        id: passwordClearTimer
        interval: 10000
        onTriggered: root.reset()
    }

    onCurrentTextChanged: {
        if (currentText.length > 0) {
            showFailure = false;
            GlobalStates.screenUnlockFailed = false;
        }
        GlobalStates.screenLockContainsCharacters = currentText.length > 0;
        passwordClearTimer.restart();
    }

    // Open a greetd session for the user (again, after a failure).
    function begin() {
        if (!root.live || root.user === "") return;
        root.awaitingResponse = false;
        if (Greetd.state !== GreetdState.Inactive) Greetd.cancelSession();
        Greetd.createSession(root.user);
    }

    function end() {
        if (root.live && Greetd.state !== GreetdState.Inactive) Greetd.cancelSession();
    }

    function tryUnlock(alsoInhibitIdle = false) {
        root.failureText = "";
        if (!root.live) {
            // Preview: any answer "logs in", to show the transition.
            root.unlockInProgress = true;
            root.unlocked(LockContext.ActionEnum.Unlock);
            return;
        }
        root.unlockInProgress = true;
        if (root.awaitingResponse) {
            root.respond();
        } else {
            root.submitPending = true;
            if (Greetd.state === GreetdState.Inactive) root.begin();
        }
    }

    function respond() {
        root.awaitingResponse = false;
        root.submitPending = false;
        root.unlockInProgress = true;
        Greetd.respond(root.currentText);
    }

    function fail(message) {
        root.clearText();
        root.unlockInProgress = false;
        root.awaitingResponse = false;
        root.submitPending = false;
        root.secretPrompt = true;
        root.promptText = "";
        if (message) root.failureText = message;
        root.showFailure = true;
        // Changing it is what makes the field shake.
        GlobalStates.screenUnlockFailed = false;
        GlobalStates.screenUnlockFailed = true;
        root.failed();
    }

    function isPasswordPrompt(message) {
        return /^\s*(password|passwort|mot de passe|contraseña|senha|parola|jelszó|hasło|пароль)\b.*:?\s*$/i.test(message);
    }

    Connections {
        target: Greetd
        enabled: root.live

        function onAuthMessage(message, error, responseRequired, echoResponse) {
            if (responseRequired) {
                root.secretPrompt = !echoResponse;
                root.promptText = root.isPasswordPrompt(message) ? "" : message.trim().replace(/:$/, "");
                root.awaitingResponse = true;
                if (root.submitPending && !echoResponse) {
                    // Answer with what was typed before the prompt came.
                    root.respond();
                } else {
                    if (root.submitPending) root.clearText();
                    root.submitPending = false;
                    root.unlockInProgress = false;
                    root.shouldReFocus();
                }
            } else if (error) {
                root.failureText = message.trim();
                GlobalStates.screenUnlockFailed = true;
                root.showFailure = true;
            } else {
                root.promptText = message.trim();
            }
        }

        function onAuthFailure(message) {
            root.fail("");
            restartTimer.restart();
        }

        function onReadyToLaunch() {
            root.awaitingResponse = false;
            root.unlockInProgress = true;
            root.unlocked(LockContext.ActionEnum.Unlock);
        }

        function onError(error) {
            console.warn("[hecate-greetd] greetd:", error);
            root.fail(error);
            restartTimer.restart();
        }
    }

    // A new conversation for the next try, once greetd has closed the failed one.
    Timer {
        id: restartTimer
        interval: 300
        onTriggered: root.begin()
    }
}
