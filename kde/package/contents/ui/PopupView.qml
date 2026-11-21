import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.extras as PlasmaExtras
import org.kde.kirigami as Kirigami

import "../code/usage.js" as U

// The click-through detail view (PopoverView.swift): what /usage shows, plus pace and forecast.
PlasmaExtras.Representation {
    id: popup

    readonly property bool showPace: Plasmoid.configuration.showPace

    Layout.minimumWidth: Kirigami.Units.gridUnit * 19
    Layout.preferredWidth: Kirigami.Units.gridUnit * 20
    Layout.minimumHeight: column.implicitHeight + Kirigami.Units.largeSpacing * 2
    Layout.preferredHeight: Layout.minimumHeight
    collapseMarginsHint: true

    header: PlasmaExtras.PlasmoidHeading {
        RowLayout {
            anchors.fill: parent
            spacing: Kirigami.Units.smallSpacing
            Kirigami.Heading {
                level: 4
                text: i18n("Claude Usage")
                Layout.leftMargin: Kirigami.Units.smallSpacing
            }
            Rectangle {
                visible: root.plan !== ""
                radius: height / 2
                color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.08)
                implicitWidth: planLabel.implicitWidth + Kirigami.Units.smallSpacing * 3
                implicitHeight: planLabel.implicitHeight + 4
                PlasmaComponents.Label {
                    id: planLabel
                    anchors.centerIn: parent
                    text: root.plan
                    font: Kirigami.Theme.smallFont
                    opacity: 0.8
                }
            }
            Item { Layout.fillWidth: true }
            PlasmaComponents.BusyIndicator {
                visible: root.refreshing
                running: visible
                Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
                Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
            }
            PlasmaComponents.ToolButton {
                visible: !root.refreshing
                icon.name: "view-refresh"
                onClicked: root.refresh(true)
                PlasmaComponents.ToolTip { text: i18n("Refresh now") }
            }
            PlasmaComponents.ToolButton {
                icon.name: "configure"
                onClicked: Plasmoid.internalAction("configure").trigger()
                PlasmaComponents.ToolTip { text: i18n("Settings") }
            }
        }
    }

    ColumnLayout {
        id: column
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: Kirigami.Units.largeSpacing
        spacing: Kirigami.Units.largeSpacing

        PlasmaExtras.PlaceholderMessage {
            visible: root.limits.length === 0
            Layout.fillWidth: true
            Layout.margins: Kirigami.Units.largeSpacing
            iconName: root.error ? root.error.icon : "view-refresh"
            text: root.error ? root.error.title : i18n("Loading usage…")
            explanation: root.error ? root.error.message : ""
            helpfulAction: root.error ? retryAction : null
            QQC2.Action {
                id: retryAction
                text: i18n("Try Again")
                icon.name: "view-refresh"
                onTriggered: root.refresh(true)
            }
        }

        ColumnLayout {
            visible: root.limits.length > 0
            Layout.fillWidth: true
            spacing: Kirigami.Units.largeSpacing * 1.5
            opacity: root.stale ? 0.55 : 1

            Repeater {
                model: root.limits
                LimitRow {
                    Layout.fillWidth: true
                    limit: modelData
                    showPace: popup.showPace
                }
            }

            // Pay-as-you-go credits used after hitting plan limits.
            ColumnLayout {
                id: extraBox
                readonly property var extra: root.snapshot ? root.snapshot.extra : null
                visible: extra !== null && extra.enabled
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing
                RowLayout {
                    Layout.fillWidth: true
                    PlasmaComponents.Label {
                        text: i18n("Extra usage")
                        font.weight: Font.Medium
                        Layout.fillWidth: true
                    }
                    PlasmaComponents.Label {
                        readonly property var extra: extraBox.extra
                        text: !extra ? "" : extra.limit !== null
                            ? i18n("%1 of %2", U.moneyText(extra.used, extra.currency), U.moneyText(extra.limit, extra.currency))
                            : U.moneyText(extra.used, extra.currency)
                        font.features: { "tnum": 1 }
                    }
                }
                UsageBar {
                    readonly property var extra: extraBox.extra
                    visible: !!extra && extra.limit !== null && extra.limit > 0
                    Layout.fillWidth: true
                    Layout.preferredHeight: 5
                    fraction: visible ? extra.used / extra.limit : 0
                    color: root.uiColor(U.severityForPercent(fraction * 100))
                }
            }
        }

        Kirigami.Separator { Layout.fillWidth: true; visible: root.snapshot !== null }

        RowLayout {
            visible: root.snapshot !== null
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing
            Kirigami.Icon {
                visible: root.error !== null
                source: "dialog-warning"
                color: Kirigami.Theme.neutralTextColor
                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                Layout.preferredHeight: Kirigami.Units.iconSizes.small
            }
            PlasmaComponents.Label {
                Layout.fillWidth: true
                elide: Text.ElideRight
                font: Kirigami.Theme.smallFont
                opacity: 0.7
                text: !root.snapshot ? ""
                    : root.error ? i18n("%1 · data from %2", root.error.title, U.ago(root.snapshot.fetchedAt, root.now))
                    : i18n("Updated %1", U.ago(root.snapshot.fetchedAt, root.now))
                HoverHandler { id: footerHover }
                PlasmaComponents.ToolTip {
                    visible: footerHover.hovered && root.error !== null
                    text: root.error ? root.error.message : ""
                }
            }
        }
    }
}
