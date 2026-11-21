import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami

import "../code/usage.js" as U

ColumnLayout {
    id: row

    property var limit
    property bool showPace: true

    readonly property int sev: U.severity(limit)
    readonly property color barColor: root.uiColor(sev)
    readonly property var fc: U.forecast(limit, root.now)

    spacing: Kirigami.Units.smallSpacing

    RowLayout {
        Layout.fillWidth: true
        PlasmaComponents.Label {
            text: row.limit.title
            font.weight: Font.Medium
            elide: Text.ElideRight
            Layout.fillWidth: true
        }
        PlasmaComponents.Label {
            text: U.percentText(row.limit.percent)
            font.weight: Font.DemiBold
            font.features: { "tnum": 1 }
            color: row.sev >= U.Severity.warning ? row.barColor : Kirigami.Theme.textColor
        }
    }

    UsageBar {
        Layout.fillWidth: true
        Layout.preferredHeight: 8
        Layout.topMargin: 2
        Layout.bottomMargin: 2
        fraction: row.limit.percent / 100
        pace: row.showPace && row.limit.percent < 100 ? U.elapsedFraction(row.limit, root.now) : null
        color: row.barColor

        HoverHandler { id: barHover }
        PlasmaComponents.ToolTip {
            visible: barHover.hovered && parent.pace !== null
            text: i18n("Even pace: how much of this window has passed. Past this line, you'll run out before it resets.")
        }
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: Kirigami.Units.smallSpacing
        PlasmaComponents.Label {
            text: root.resetPhrase(row.limit)
            font: Kirigami.Theme.smallFont
            opacity: 0.7
            elide: Text.ElideRight
            Layout.fillWidth: true
        }
        Kirigami.Icon {
            visible: row.fc !== null && row.fc.runsOutIn !== undefined
            source: "dialog-warning"
            color: Kirigami.Theme.neutralTextColor
            Layout.preferredWidth: Kirigami.Units.iconSizes.small * 0.75
            Layout.preferredHeight: Layout.preferredWidth
        }
        PlasmaComponents.Label {
            visible: row.fc !== null
            font: Kirigami.Theme.smallFont
            text: row.fc === null ? ""
                : row.fc.runsOutIn !== undefined ? i18n("Limit in ~%1", U.duration(row.fc.runsOutIn))
                : i18n("~%1% at reset", Math.round(row.fc.endsAt))
            color: row.fc !== null && row.fc.runsOutIn !== undefined ? Kirigami.Theme.neutralTextColor : Kirigami.Theme.textColor
            opacity: row.fc !== null && row.fc.runsOutIn !== undefined ? 1 : 0.5
        }
    }
}
