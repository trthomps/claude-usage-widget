import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami

import "../code/usage.js" as U

ColumnLayout {
    id: gauge

    property var limit
    property bool showPace: true
    property real size: Kirigami.Units.gridUnit * 3.6

    readonly property real lineWidth: Math.round(size * 0.11)
    readonly property int sev: U.severity(limit)
    readonly property color ringColor: root.uiColor(sev)
    readonly property real fraction: Math.min(Math.max(limit.percent / 100, 0), 1)
    readonly property var pace: showPace && limit.percent < 100 ? U.elapsedFraction(limit, root.now) : null
    readonly property color textColor: Kirigami.Theme.textColor

    spacing: 3
    Layout.preferredWidth: size + Kirigami.Units.gridUnit * 0.6

    Item {
        Layout.alignment: Qt.AlignHCenter
        Layout.preferredWidth: gauge.size
        Layout.preferredHeight: gauge.size

        Shape {
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer

            ShapePath {
                strokeColor: Qt.rgba(gauge.textColor.r, gauge.textColor.g, gauge.textColor.b, 0.12)
                strokeWidth: gauge.lineWidth
                fillColor: "transparent"
                PathAngleArc {
                    centerX: gauge.size / 2; centerY: gauge.size / 2
                    radiusX: (gauge.size - gauge.lineWidth) / 2; radiusY: radiusX
                    startAngle: 0; sweepAngle: 360
                }
            }
            ShapePath {
                strokeColor: gauge.fraction > 0 ? gauge.ringColor : "transparent"
                strokeWidth: gauge.lineWidth
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                PathAngleArc {
                    centerX: gauge.size / 2; centerY: gauge.size / 2
                    radiusX: (gauge.size - gauge.lineWidth) / 2; radiusY: radiusX
                    startAngle: -90; sweepAngle: 360 * gauge.fraction
                }
            }
        }

        // Pace tick: rotate a full-size item so the tick sits on the ring.
        Item {
            anchors.fill: parent
            visible: gauge.pace !== null && gauge.pace > 0.01 && gauge.pace < 0.99
            rotation: (gauge.pace || 0) * 360
            Rectangle {
                width: 2.5
                height: gauge.lineWidth + 5
                radius: width / 2
                x: (parent.width - width) / 2
                y: gauge.lineWidth / 2 - height / 2
                color: Qt.rgba(gauge.textColor.r, gauge.textColor.g, gauge.textColor.b, 0.7)
            }
        }

        PlasmaComponents.Label {
            anchors.centerIn: parent
            text: U.percentText(gauge.limit.percent)
            font.pixelSize: Math.round(gauge.size * 0.25)
            font.weight: Font.DemiBold
            font.features: { "tnum": 1 }
            color: gauge.sev >= U.Severity.critical ? gauge.ringColor : gauge.textColor
        }
    }

    PlasmaComponents.Label {
        Layout.alignment: Qt.AlignHCenter
        Layout.maximumWidth: gauge.Layout.preferredWidth
        text: gauge.limit.widgetTitle
        font.weight: Font.Medium
        elide: Text.ElideRight
    }

    RowLayout {
        Layout.alignment: Qt.AlignHCenter
        spacing: 2
        opacity: 0.7
        Kirigami.Icon {
            source: "view-refresh"
            Layout.preferredWidth: Math.round(Kirigami.Units.iconSizes.small * 0.7)
            Layout.preferredHeight: Layout.preferredWidth
        }
        PlasmaComponents.Label {
            text: gauge.limit.resetsAt !== null ? U.duration(gauge.limit.resetsAt - root.now) : "—"
            font: Kirigami.Theme.smallFont
        }
    }

    HoverHandler { id: hover }
    PlasmaComponents.ToolTip {
        visible: hover.hovered
        text: gauge.limit.title + " · " + root.resetPhrase(gauge.limit)
    }
}
