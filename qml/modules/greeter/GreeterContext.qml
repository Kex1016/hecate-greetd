pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Services.Greetd

/**
 * greetd's PAM conversation for the selected user.
 *
 * A greetd session is opened for the user as soon as the screen shows, so prompts that come
 * first (a fingerprint reader, a notice) appear without typing anything. What the user types
 * answers the next secret prompt, which for most logins is the password.
 *
 * Two things greetd's protocol leaves to the greeter:
 *
 * - Its answers carry no word on which request they answer. A session opened right after
 *   another was cancelled would take the cancel's "success" for its own, a login that never
 *   happened. So a new session waits out `settle` after every cancel.
 * - An account that needs no password is "ready" the moment its session opens. Nobody is
 *   logged in for having been selected: without a prompt answered or a notice shown (a
 *   fingerprint reader's), the login waits for Enter.
 */
Scope {
    id: root

    signal shouldReFocus()
    // greetd is ready to start a session for the user, and the user asked for it.
    signal authenticated()
    signal failed()

    // Who logs in, and whether greetd is there at all (it isn't in `hecate-greetd preview`).
    property string user: ""
    property bool preview: false
    readonly property bool live: !root.preview && Greetd.available

    property string currentText: ""
    // An answer is with greetd, or the login went through.
    property bool busy: false
    property bool showFailure: false

    // What the prompt asks for when it isn't the usual password ("Verification code"), a
    // notice that needs no answer ("Place your finger on the reader"), and why a login failed.
    property string promptText: ""
    property string noticeText: ""
    property string failureText: ""
    property bool secretPrompt: true
    // greetd asks nothing of this user: Enter logs in.
    property bool ready: false

    property bool awaitingResponse: false
    property bool submitPending: false
    property bool started: false
    // A session is to be opened once the last cancel has settled.
    property bool wanted: false
    // In this conversation: the user pressed Enter, greetd said something.
    property bool submitted: false
    property bool heard: false

    function clearText() {
        root.currentText = "";
    }
    function resetClearTimer() {
        clearTimer.restart();
    }

    // What was typed and left alone doesn't stay.
    Timer {
        id: clearTimer
        interval: 10000
        onTriggered: {
            root.clearText();
            if (!root.submitPending) root.busy = false;
        }
    }

    onCurrentTextChanged: {
        if (currentText.length > 0) showFailure = false;
        clearTimer.restart();
    }

    // Another user: a new conversation, nothing of the last one left.
    onUserChanged: {
        if (!root.started) return;
        root.clearText();
        root.busy = false;
        root.showFailure = false;
        root.failureText = "";
        root.begin();
    }

    function forget() {
        root.awaitingResponse = false;
        root.submitPending = false;
        root.submitted = false;
        root.heard = false;
        root.ready = false;
        root.secretPrompt = true;
        root.promptText = "";
        root.noticeText = "";
    }

    function cancel() {
        if (!root.live || Greetd.state === GreetdState.Inactive) return;
        Greetd.cancelSession();
        settleTimer.restart();
    }

    // A new conversation with greetd for the user, in place of any that is open.
    function begin() {
        root.started = true;
        root.forget();
        if (!root.live || root.user === "") return;
        root.cancel();
        root.wanted = true;
        if (!settleTimer.running) root.open();
    }

    function open() {
        if (!root.wanted) return;
        root.wanted = false;
        Greetd.createSession(root.user);
    }

    function end() {
        root.wanted = false;
        root.cancel();
    }

    // greetd has answered the last cancel by now (it does within a few milliseconds).
    Timer {
        id: settleTimer
        interval: 300
        onTriggered: root.open()
    }

    function submit() {
        root.failureText = "";
        root.showFailure = false;
        root.busy = true;
        if (!root.live) {
            // Preview: any answer "logs in", to show the way out.
            root.authenticated();
            return;
        }
        root.submitted = true;
        if (root.ready) {
            root.authenticated();
        } else if (root.awaitingResponse) {
            root.respond();
        } else {
            root.submitPending = true;
            if (Greetd.state === GreetdState.Inactive && !root.wanted) {
                root.begin();
                root.submitted = true;
                root.submitPending = true;
            }
        }
    }

    function respond() {
        root.awaitingResponse = false;
        root.submitPending = false;
        root.busy = true;
        Greetd.respond(root.currentText);
    }

    function fail(message) {
        root.clearText();
        root.busy = false;
        root.forget();
        root.failureText = message ?? "";
        root.showFailure = true;
        root.failed();
    }

    // The conversation is over on greetd's side (it closes a failed one itself): the next one.
    function retry() {
        root.wanted = true;
        settleTimer.restart();
    }

    function isPasswordPrompt(message) {
        return /^\s*(password|passwort|mot de passe|contraseña|senha|parola|jelszó|hasło|пароль)\b.*:?\s*$/i.test(message);
    }

    Connections {
        target: Greetd
        enabled: root.live

        function onAuthMessage(message, error, responseRequired, echoResponse) {
            if (root.ready) {
                // "Ready" was not about this session after all: start over, cleanly.
                root.begin();
                return;
            }
            root.heard = true;
            if (responseRequired) {
                root.secretPrompt = !echoResponse;
                root.promptText = root.isPasswordPrompt(message) ? "" : message.trim();
                root.awaitingResponse = true;
                if (root.submitPending && !echoResponse) {
                    // Answer with what was typed before the prompt came.
                    root.respond();
                } else {
                    if (root.submitPending) root.clearText();
                    root.submitPending = false;
                    root.busy = false;
                    root.shouldReFocus();
                }
            } else if (error) {
                root.failureText = message.trim();
                root.showFailure = true;
            } else {
                root.noticeText = message.trim();
            }
        }

        function onAuthFailure(message) {
            root.fail("");
            root.retry();
        }

        function onReadyToLaunch() {
            root.awaitingResponse = false;
            if (root.submitted || root.heard) {
                root.busy = true;
                root.authenticated();
            } else {
                root.ready = true;
                root.busy = false;
                root.shouldReFocus();
            }
        }

        function onError(error) {
            console.warn("[hecate-greetd] greetd:", error);
            root.fail(error);
            root.retry();
        }
    }
}
