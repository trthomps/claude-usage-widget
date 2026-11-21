import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami

import "../code/usage.js" as U

// The desktop widget (DesktopWidget.swift): a ring per limit.
Item {
    id: desk

    readonly property real pad: Kirigami.Units.largeSpacing

    Layout.minimumWidth: column.implicitWidth + pad * 2
    Layout.minimumHeight: column.implicitHeight + pad * 2
    Layout.preferredWidth: Layout.minimumWidth
    Layout.preferredHeight: Layout.minimumHeight

    ColumnLayout {
        id: column
        anchors.centerIn: parent
        spacing: Kirigami.Units.largeSpacing

        RowLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing
            PlasmaComponents.Label {
                text: "Claude"
                font.weight: Font.DemiBold
            }
            PlasmaComponents.Label {
                visible: root.plan !== ""
                text: root.plan
                font: Kirigami.Theme.smallFont
                opacity: 0.7
            }
            Item { Layout.fillWidth: true; Layout.minimumWidth: Kirigami.Units.largeSpacing }
            Kirigami.Icon {
                visible: root.error !== null
                source: "dialog-warning"
                color: Kirigami.Theme.neutralTextColor
                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                Layout.preferredHeight: Kirigami.Units.iconSizes.small
                HoverHandler { id: warnHover }
                PlasmaComponents.ToolTip {
                    visible: warnHover.hovered
                    text: root.error ? root.error.title + ": " + root.error.message : ""
                }
            }
            PlasmaComponents.Label {
                visible: root.error === null && root.snapshot !== null
                text: root.snapshot ? U.ago(root.snapshot.fetchedAt, root.now) : ""
                font: Kirigami.Theme.smallFont
                opacity: 0.5
            }
        }

        PlasmaComponents.Label {
            visible: root.limits.length === 0
            text: root.error ? root.error.title : i18n("Loading…")
            opacity: 0.7
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            Layout.preferredWidth: Kirigami.Units.gridUnit * 9
            Layout.preferredHeight: Kirigami.Units.gridUnit * 5
        }

        RowLayout {
            visible: root.limits.length > 0
            spacing: Kirigami.Units.smallSpacing * 2
            opacity: root.stale ? 0.55 : 1
            Repeater {
                model: root.limits
                RingGauge {
                    Layout.alignment: Qt.AlignTop
                    limit: modelData
                    showPace: Plasmoid.configuration.showPace
                }
            }
        }
    }
}
