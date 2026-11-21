import QtQuick
import QtQuick.Shapes
import org.kde.kirigami as Kirigami

import "../code/usage.js" as U

// A small rounded bar with the percentage printed on it, like a battery glyph.
// The fill knocks the digits out of itself, so the number reads wherever the fill edge lands.
Item {
    id: pill

    property var limit
    property real now
    property bool showPace: true
    property color fillColor: Kirigami.Theme.textColor
    property color knockoutColor: Kirigami.Theme.backgroundColor
    property color trackTextColor: Kirigami.Theme.textColor
    property real pillHeight: Math.round(Kirigami.Units.gridUnit * 0.9)

    readonly property bool blocked: limit.percent >= 100
    // At 100% the percentage says nothing; show the time until reset instead.
    readonly property string label: blocked && limit.resetsAt !== null
        ? U.duration(limit.resetsAt - now, "compact") : U.percentText(limit.percent)
    readonly property real fraction: Math.min(Math.max(limit.percent / 100, 0), 1)
    readonly property var pace: showPace && !blocked ? U.elapsedFraction(limit, now) : null

    // Sized for "88%" so 19% → 20% never shifts neighbours.
    TextMetrics { id: widest; font: digits.font; text: "88%" }

    implicitWidth: Math.ceil(Math.max(widest.width, digits.implicitWidth)) + Math.round(pillHeight * 0.9)
    implicitHeight: pillHeight + caret.height + 2

    Item {
        id: body
        width: parent.width
        height: pill.pillHeight
        anchors.verticalCenter: parent.verticalCenter
        anchors.verticalCenterOffset: -(caret.height + 2) / 2 + 1

        Rectangle {
            anchors.fill: parent
            radius: height / 2
            color: "transparent"
            border.width: 1
            border.color: Qt.rgba(pill.fillColor.r, pill.fillColor.g, pill.fillColor.b, 0.55)
        }

        Text {
            id: digits
            anchors.centerIn: parent
            text: pill.label
            color: pill.trackTextColor
            font.pixelSize: Math.round(pill.pillHeight * 0.72)
            font.weight: Font.DemiBold
            font.features: { "tnum": 1 }
        }

        Item {
            width: Math.round(parent.width * pill.fraction)
            height: parent.height
            clip: true

            Rectangle {
                width: body.width
                height: body.height
                radius: height / 2
                color: pill.fillColor
            }
            Text {
                x: digits.x
                y: digits.y
                text: digits.text
                font: digits.font
                color: pill.knockoutColor
            }
        }
    }

    // Pace caret: where usage would be if spread evenly. Fill past it → on track to run out.
    Shape {
        id: caret
        visible: pill.pace !== null && pill.pace > 0.01 && pill.pace < 0.99
        width: Math.max(5, Math.round(pill.pillHeight * 0.4))
        height: Math.round(width * 0.7)
        x: Math.round(body.width * (pill.pace || 0) - width / 2)
        anchors.top: body.bottom
        anchors.topMargin: 1
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            strokeWidth: -1
            fillColor: pill.trackTextColor
            startX: caret.width / 2; startY: 0
            PathLine { x: caret.width; y: caret.height }
            PathLine { x: 0; y: caret.height }
            PathLine { x: caret.width / 2; y: 0 }
        }
    }
}
