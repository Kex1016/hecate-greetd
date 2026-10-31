pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Qt5Compat.GraphicalEffects
import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions

/**
 * Who logs in and into what, in the lock screen's left toolbar where the shell shows the
 * username or the playing song: the avatar where the cover art goes, the session above the
 * name like the artist above the title. Clicking opens a menu of accounts and sessions.
 */
Item {
    id: picker

    required property var greeter
    property bool menuOpen: false
    readonly property var user: picker.greeter.currentUser
    readonly property bool canSwitch: picker.greeter.users.length > 1
    readonly property bool canChooseSession: picker.greeter.sessions.length > 1

    implicitWidth: chip.implicitWidth
    implicitHeight: chip.implicitHeight

    component Avatar: Rectangle {
        id: avatar
        property string source: ""
        property real size: 40
        implicitWidth: size
        implicitHeight: size
        radius: Appearance.rounding.full
        color: Appearance.colors.colPrimaryContainer
        clip: true
        layer.enabled: true
        layer.effect: OpacityMask {
            maskSource: Rectangle {
                width: avatar.width
                height: avatar.height
                radius: avatar.radius
            }
        }
        StyledImage {
            anchors.fill: parent
            source: avatar.source !== "" ? `file://${avatar.source}` : ""
            fillMode: Image.PreserveAspectCrop
            sourceSize.width: avatar.size * 2
            sourceSize.height: avatar.size * 2
            visible: avatar.source !== "" && status === Image.Ready
        }
        MaterialSymbol {
            anchors.centerIn: parent
            fill: 1
            text: "person"
            iconSize: avatar.size * 0.55
            color: Appearance.colors.colOnPrimaryContainer
            visible: avatar.source === ""
        }
    }

    RippleButton {
        id: chip
        implicitHeight: 40
        implicitWidth: chipRow.implicitWidth + 8
        // Not the Basic style's 6 px all round: the avatar is as tall as the chip, so any
        // top padding pushes the row (and the text with it) down.
        padding: 0
        leftPadding: 4
        rightPadding: 4
        buttonRadius: Appearance.rounding.full
        enabled: picker.canSwitch || picker.canChooseSession
        toggled: picker.menuOpen
        colBackgroundToggled: Appearance.colors.colSecondaryContainer
        colBackgroundToggledHover: Appearance.colors.colSecondaryContainerHover
        colRippleToggled: Appearance.colors.colSecondaryContainerActive
        onClicked: picker.menuOpen = !picker.menuOpen

        contentItem: RowLayout {
            id: chipRow
            spacing: 8
            Avatar {
                source: picker.user?.avatar ?? ""
            }
            Column {
                Layout.alignment: Qt.AlignVCenter
                spacing: -2
                StyledText {
                    width: Math.min(implicitWidth, 180)
                    elide: Text.ElideRight
                    color: Appearance.colors.colOnSurfaceVariant
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    text: picker.greeter.currentSession?.name ?? (picker.greeter.preview ? Translation.tr("Preview") : SystemInfo.hostname)
                }
                StyledText {
                    width: Math.min(implicitWidth, 180)
                    elide: Text.ElideRight
                    color: Appearance.colors.colOnSurfaceVariant
                    font.weight: Font.Medium
                    font.pixelSize: Appearance.font.pixelSize.small
                    text: picker.user?.displayName ?? (picker.greeter.user || Translation.tr("No users"))
                }
            }
            MaterialSymbol {
                Layout.alignment: Qt.AlignVCenter
                Layout.rightMargin: 4
                visible: chip.enabled
                text: "expand_less"
                iconSize: Appearance.font.pixelSize.larger
                color: Appearance.colors.colOnSurfaceVariant
                rotation: picker.menuOpen ? 180 : 0
                Behavior on rotation {
                    animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                }
            }
        }
    }

    // ------------------------------------------------------------------ the menu, above the toolbar

    Item {
        id: menu
        anchors {
            left: chip.left
            leftMargin: -10
            bottom: chip.top
            bottomMargin: 18
        }
        width: Math.max(260, menuColumn.implicitWidth + 16)
        height: menuColumn.implicitHeight + 16
        visible: opacity > 0
        opacity: picker.menuOpen ? 1 : 0
        scale: picker.menuOpen ? 1 : 0.9
        transformOrigin: Item.BottomLeft
        Behavior on opacity {
            animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
        }
        Behavior on scale {
            NumberAnimation {
                duration: Appearance.animation.elementMove.duration
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Appearance.animationCurves.expressiveFastSpatial
            }
        }

        StyledRectangularShadow {
            target: menuBackground
        }
        Rectangle {
            id: menuBackground
            anchors.fill: parent
            radius: Appearance.rounding.large
            color: Appearance.m3colors.m3surfaceContainer
        }

        ColumnLayout {
            id: menuColumn
            anchors {
                fill: parent
                margins: 8
            }
            spacing: 2

            MenuHeader {
                visible: picker.canSwitch
                text: Translation.tr("Accounts")
            }
            Repeater {
                model: picker.canSwitch ? picker.greeter.users : []
                delegate: MenuEntry {
                    required property var modelData
                    entryAvatar: modelData.avatar ?? ""
                    entryLabel: modelData.displayName
                    entrySublabel: modelData.displayName !== modelData.name ? modelData.name : ""
                    entrySelected: modelData.name === picker.greeter.user
                    onClicked: {
                        picker.menuOpen = false;
                        picker.greeter.switchUser(modelData.name);
                    }
                }
            }

            MenuHeader {
                visible: picker.canChooseSession
                Layout.topMargin: picker.canSwitch ? 6 : 0
                text: Translation.tr("Session")
            }
            Repeater {
                model: picker.canChooseSession ? picker.greeter.sessions : []
                delegate: MenuEntry {
                    required property var modelData
                    entrySymbol: "desktop_windows"
                    entryLabel: modelData.name
                    entrySublabel: modelData.comment
                    entrySelected: modelData.id === picker.greeter.session
                    onClicked: {
                        picker.menuOpen = false;
                        picker.greeter.session = modelData.id;
                    }
                }
            }
        }
    }

    // Close the menu when the password field takes over (typing, Enter).
    Connections {
        target: GlobalStates
        function onScreenLockContainsCharactersChanged() {
            if (GlobalStates.screenLockContainsCharacters) picker.menuOpen = false;
        }
    }

    component MenuHeader: StyledText {
        Layout.leftMargin: 10
        Layout.bottomMargin: 2
        color: Appearance.colors.colSubtext
        font.pixelSize: Appearance.font.pixelSize.smaller
    }

    component MenuEntry: RippleButton {
        id: entry
        property string entryAvatar: ""
        property string entrySymbol: ""
        property string entryLabel: ""
        property string entrySublabel: ""
        property bool entrySelected: false
        Layout.fillWidth: true
        implicitHeight: 48
        buttonRadius: Appearance.rounding.normal
        toggled: entry.entrySelected
        colBackgroundToggled: Appearance.colors.colSecondaryContainer
        colBackgroundToggledHover: Appearance.colors.colSecondaryContainerHover
        colRippleToggled: Appearance.colors.colSecondaryContainerActive

        topPadding: 0
        bottomPadding: 0
        leftPadding: 8
        rightPadding: 10
        contentItem: RowLayout {
            spacing: 10
            Avatar {
                visible: entry.entrySymbol === ""
                size: 32
                source: entry.entryAvatar
            }
            MaterialSymbol {
                visible: entry.entrySymbol !== ""
                Layout.leftMargin: 4
                Layout.rightMargin: 4
                text: entry.entrySymbol
                iconSize: Appearance.font.pixelSize.huge
                color: entry.entrySelected ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colOnSurfaceVariant
            }
            Column {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                spacing: -2
                StyledText {
                    width: parent.width
                    elide: Text.ElideRight
                    text: entry.entryLabel
                    font.weight: Font.Medium
                    color: entry.entrySelected ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colOnSurface
                }
                StyledText {
                    width: parent.width
                    visible: entry.entrySublabel !== ""
                    elide: Text.ElideRight
                    text: entry.entrySublabel
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: Appearance.colors.colSubtext
                }
            }
            MaterialSymbol {
                visible: entry.entrySelected
                text: "check"
                iconSize: Appearance.font.pixelSize.larger
                color: Appearance.colors.colOnSecondaryContainer
            }
        }
    }
}
