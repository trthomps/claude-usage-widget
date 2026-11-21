import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM

KCM.SimpleKCM {
    id: page

    property string cfg_style
    property string cfg_metrics
    property bool cfg_showLabels
    property bool cfg_showPace
    property string cfg_colorMode
    property int cfg_refreshInterval

    readonly property var metricList: cfg_metrics.split(",").map(s => s.trim()).filter(s => s.length > 0)

    function setMetric(id, on) {
        let list = metricList.filter(m => m !== id)
        if (on) list.push(id)
        const order = ["session", "weekly_all", "weekly:*"]
        list.sort((a, b) => order.indexOf(a) - order.indexOf(b))
        cfg_metrics = list.join(",")
    }

    Kirigami.FormLayout {
        QQC2.ComboBox {
            id: styleBox
            Kirigami.FormData.label: i18n("Panel style:")
            textRole: "text"
            valueRole: "value"
            model: [
                { value: "pills", text: i18n("Pills — a bar behind each percentage") },
                { value: "stacked", text: i18n("Stacked — two mini bars, the narrowest") },
                { value: "focus", text: i18n("Focus — only the limit closest to running out") },
                { value: "text", text: i18n("Text — just the numbers") }
            ]
            Component.onCompleted: currentIndex = indexOfValue(page.cfg_style)
            onActivated: page.cfg_style = currentValue
        }

        QQC2.CheckBox {
            Kirigami.FormData.label: i18n("Show in panel:")
            text: i18n("Current session (5h)")
            checked: page.metricList.indexOf("session") >= 0
            onToggled: page.setMetric("session", checked)
        }
        QQC2.CheckBox {
            text: i18n("Current week, all models (7d)")
            checked: page.metricList.indexOf("weekly_all") >= 0
            onToggled: page.setMetric("weekly_all", checked)
        }
        QQC2.CheckBox {
            text: i18n("Per-model weekly limits")
            checked: page.metricList.indexOf("weekly:*") >= 0
            onToggled: page.setMetric("weekly:*", checked)
        }

        QQC2.CheckBox {
            Kirigami.FormData.label: i18n("Labels:")
            text: i18n("Show short labels (5h, 7d)")
            checked: page.cfg_showLabels
            onToggled: page.cfg_showLabels = checked
        }
        QQC2.CheckBox {
            Kirigami.FormData.label: i18n("Pace marker:")
            text: i18n("Show how much of each window has passed")
            checked: page.cfg_showPace
            onToggled: page.cfg_showPace = checked
        }

        QQC2.ComboBox {
            Kirigami.FormData.label: i18n("Color:")
            textRole: "text"
            valueRole: "value"
            model: [
                { value: "warnings", text: i18n("Warnings — plain until 75% (orange) or 90% (red)") },
                { value: "claude", text: i18n("Claude — clay, red past 90%") },
                { value: "monochrome", text: i18n("Mono — never colored") }
            ]
            Component.onCompleted: currentIndex = indexOfValue(page.cfg_colorMode)
            onActivated: page.cfg_colorMode = currentValue
        }

        QQC2.ComboBox {
            Kirigami.FormData.label: i18n("Refresh every:")
            textRole: "text"
            valueRole: "value"
            model: [
                { value: 60, text: i18n("1 minute") },
                { value: 120, text: i18n("2 minutes") },
                { value: 300, text: i18n("5 minutes") },
                { value: 600, text: i18n("10 minutes") },
                { value: 900, text: i18n("15 minutes") }
            ]
            Component.onCompleted: {
                const i = indexOfValue(page.cfg_refreshInterval)
                currentIndex = i >= 0 ? i : 1
            }
            onActivated: page.cfg_refreshInterval = currentValue
        }

        Kirigami.Separator { Kirigami.FormData.isSection: true }

        QQC2.Label {
            Layout.maximumWidth: Kirigami.Units.gridUnit * 22
            wrapMode: Text.WordWrap
            opacity: 0.7
            text: i18n("Reads Claude Code's login from ~/.claude/.credentials.json (never writes or refreshes it). Data comes from the same endpoint as /usage in Claude Code. Middle-click the panel item to refresh.")
        }
    }
}
