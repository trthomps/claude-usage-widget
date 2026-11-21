import QtQuick
import org.kde.kirigami as Kirigami

// Horizontal bar with an optional pace tick.
Item {
    id: bar

    property real fraction: 0
    property var pace: null
    property color color: Kirigami.Theme.highlightColor
    property real trackOpacity: 0.12
    property real paceOvershoot: 3

    readonly property real clamped: Math.min(Math.max(fraction, 0), 1)

    implicitHeight: 8

    Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, bar.trackOpacity)
    }

    Rectangle {
        height: parent.height
        width: bar.clamped > 0 ? Math.max(height, parent.width * bar.clamped) : 0
        radius: height / 2
        color: bar.color
    }

    Rectangle {
        visible: bar.pace !== null && bar.pace > 0.01 && bar.pace < 0.99
        width: 2
        height: parent.height + bar.paceOvershoot * 2
        y: -bar.paceOvershoot
        x: Math.min(Math.max(parent.width * (bar.pace || 0) - 1, 0), parent.width - 2)
        radius: 1
        color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.6)
    }
}
