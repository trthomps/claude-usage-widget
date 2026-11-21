import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.kirigami as Kirigami

import "../code/usage.js" as U

// The panel item (MenuBarRenderer.swift): pills, stacked bars, focus or plain text.
MouseArea {
    id: compact

    readonly property bool vertical: Plasmoid.formFactor === PlasmaCore.Types.Vertical
    readonly property string style: Plasmoid.configuration.style
    readonly property bool showLabels: Plasmoid.configuration.showLabels
    readonly property bool showPace: Plasmoid.configuration.showPace
    readonly property var shown: style === "focus"
        ? (root.limits.length ? [U.mostPressing(root.panelLimits)] : []) : root.panelLimits

    Layout.minimumWidth: vertical ? -1 : content.implicitWidth + Kirigami.Units.smallSpacing * 2
    Layout.preferredWidth: Layout.minimumWidth
    Layout.minimumHeight: vertical ? content.implicitHeight + Kirigami.Units.smallSpacing * 2 : -1
    Layout.preferredHeight: Layout.minimumHeight

    acceptedButtons: Qt.LeftButton | Qt.MiddleButton
    hoverEnabled: true
    // The popup closes itself on press (it loses focus), so decide from the state before the press.
    property bool wasExpanded: false
    onPressed: wasExpanded = root.expanded
    onClicked: mouse => {
        if (mouse.button === Qt.MiddleButton) root.refresh(true)
        else root.expanded = !wasExpanded
    }

    Item {
        id: content
        anchors.centerIn: parent
        implicitWidth: loader.item ? loader.item.implicitWidth : 0
        implicitHeight: loader.item ? loader.item.implicitHeight : 0
        width: implicitWidth
        height: implicitHeight
        // Stale data fades instead of showing numbers you shouldn't trust.
        opacity: root.stale ? 0.45 : 1

        Loader {
            id: loader
            anchors.centerIn: parent
            sourceComponent: root.limits.length === 0 ? placeholder
                : compact.style === "stacked" ? stacked
                : compact.style === "text" ? textStyle
                : pills
        }
    }

    Component {
        id: placeholder
        Kirigami.Icon {
            implicitWidth: Kirigami.Units.iconSizes.smallMedium
            implicitHeight: implicitWidth
            source: root.error ? root.error.icon : Plasmoid.icon
            opacity: 0.7
        }
    }

    Component {
        id: pills
        GridLayout {
            flow: compact.vertical ? GridLayout.TopToBottom : GridLayout.LeftToRight
            rowSpacing: Kirigami.Units.smallSpacing
            columnSpacing: Kirigami.Units.smallSpacing * 2
            Repeater {
                model: compact.shown
                RowLayout {
                    spacing: 3
                    Layout.alignment: Qt.AlignCenter
                    Text {
                        visible: compact.showLabels || compact.style === "focus"
                        text: modelData.shortLabel
                        color: Kirigami.Theme.textColor
                        opacity: 0.8
                        font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.62)
                        font.weight: Font.Medium
                        Layout.alignment: Qt.AlignVCenter
                        Layout.topMargin: -3
                    }
                    Pill {
                        limit: modelData
                        now: root.now
                        showPace: compact.showPace
                        fillColor: root.panelColor(U.severity(modelData))
                        knockoutColor: Kirigami.Theme.backgroundColor
                    }
                }
            }
        }
    }

    Component {
        id: stacked
        // Two mini bars on top of each other with the numbers to the right. The narrowest style.
        RowLayout {
            spacing: 4
            ColumnLayout {
                visible: compact.showLabels
                spacing: -2
                Repeater {
                    model: compact.shown.slice(0, 2)
                    Text {
                        text: modelData.shortLabel
                        color: Kirigami.Theme.textColor
                        opacity: 0.8
                        font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.55)
                        font.weight: Font.Medium
                    }
                }
            }
            ColumnLayout {
                spacing: 3
                Repeater {
                    model: compact.shown.slice(0, 2)
                    UsageBar {
                        Layout.preferredWidth: Math.round(Kirigami.Units.gridUnit * 1.3)
                        Layout.preferredHeight: 4
                        fraction: modelData.percent / 100
                        pace: compact.showPace && modelData.percent < 100 ? U.elapsedFraction(modelData, root.now) : null
                        color: root.panelColor(U.severity(modelData))
                        trackOpacity: 0.25
                        paceOvershoot: 2
                    }
                }
            }
            ColumnLayout {
                spacing: -2
                Repeater {
                    model: compact.shown.slice(0, 2)
                    Text {
                        text: modelData.percent >= 100 && modelData.resetsAt !== null
                            ? U.duration(modelData.resetsAt - root.now, "tiny") : U.percentText(modelData.percent)
                        color: U.severity(modelData) >= U.Severity.warning ? root.panelColor(U.severity(modelData))
                                                                            : Kirigami.Theme.textColor
                        font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.55)
                        font.weight: Font.DemiBold
                        font.features: { "tnum": 1 }
                        Layout.alignment: Qt.AlignRight
                    }
                }
            }
        }
    }

    Component {
        id: textStyle
        GridLayout {
            flow: compact.vertical ? GridLayout.TopToBottom : GridLayout.LeftToRight
            columnSpacing: Kirigami.Units.smallSpacing * 2
            rowSpacing: 0
            Repeater {
                model: compact.shown
                Text {
                    readonly property int sev: U.severity(modelData)
                    text: (compact.showLabels ? modelData.shortLabel + " " : "")
                        + (modelData.percent >= 100 && modelData.resetsAt !== null
                           ? U.duration(modelData.resetsAt - root.now, "compact") : U.percentText(modelData.percent))
                    color: root.panelColor(sev)
                    font.weight: Font.DemiBold
                    font.features: { "tnum": 1 }
                    Layout.alignment: Qt.AlignCenter
                }
            }
        }
    }
}
