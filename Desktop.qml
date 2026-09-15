import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// A Statable desktop card, macOS-widget style: a rounded tile pinned to the
// top-left of the wallpaper, always visible, showing visitors now and a
// seven-day sparkline. It sits on the Bottom layer, above the wallpaper and
// below windows, so a window covers it — as every desktop widget is covered.
//
// Data comes from the `statable` CLI on a timer; each command prints and
// exits. A non-zero exit leaves that part blank rather than showing a wrong
// figure, and the processes run off the UI thread.
Item {
  id: root

  property string site: "example.com"
  property string nowCount: ""
  property var stats: null
  property var series: []

  function poll() {
    if (!nowP.running) nowP.running = true
    if (!statsP.running) statsP.running = true
    if (!serP.running) serP.running = true
  }
  Component.onCompleted: poll()
  Timer { interval: 60000; running: true; repeat: true; onTriggered: root.poll() }

  Process {
    id: nowP
    command: ["statable", "now"]
    stdout: StdioCollector { id: nowO; waitForEnd: true }
    onExited: function (c) { root.nowCount = c === 0 ? String(nowO.text || "").trim() : "" }
  }
  Process {
    id: statsP
    command: ["statable", "stats", "--range", "7d", "--compare", "previous", "--format", "json"]
    stdout: StdioCollector { id: statsO; waitForEnd: true }
    onExited: function (c) { try { root.stats = c === 0 ? JSON.parse(statsO.text) : null } catch (e) { root.stats = null } }
  }
  Process {
    id: serP
    command: ["statable", "series", "--by", "day", "--range", "7d", "--format", "json"]
    stdout: StdioCollector { id: serO; waitForEnd: true }
    onExited: function (c) {
      try { var a = c === 0 ? JSON.parse(serO.text) : []; root.series = Array.isArray(a) ? a : [] }
      catch (e) { root.series = [] }
    }
  }

  readonly property real maxV: {
    var m = 1
    for (var i = 0; i < series.length; i++) m = Math.max(m, Number(series[i].visitors) || 0)
    return m
  }

  function fmtInt(n) { return String(Math.round(n)).replace(/\B(?=(\d{3})+(?!\d))/g, " ") }

  readonly property color ink: "#ffffff"

  PanelWindow {
    id: win
    visible: true
    color: "transparent"
    WlrLayershell.namespace: "omarchy-statable-desktop"
    WlrLayershell.layer: WlrLayer.Bottom
    exclusiveZone: 0
    anchors { top: true; left: true }
    margins.top: Style.space(28)
    margins.left: Style.space(28)
    implicitWidth: card.width
    implicitHeight: card.height

    Rectangle {
      id: card
      width: Style.space(272)
      height: content.implicitHeight + Style.space(36)
      radius: Style.space(20)
      color: Qt.rgba(0, 0, 0, 0.42)
      border.color: Qt.rgba(1, 1, 1, 0.10)
      border.width: 1

      Column {
        id: content
        anchors { left: parent.left; right: parent.right; top: parent.top; margins: Style.space(18) }
        spacing: Style.space(6)

        Text {
          text: root.site
          color: Qt.rgba(1, 1, 1, 0.55)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
        Text {
          text: root.nowCount === "" ? "—" : root.nowCount
          color: root.ink
          font.family: Style.font.family
          font.pixelSize: Style.font.displayLarge
          font.bold: true
        }
        Text {
          text: "active now"
          color: Qt.rgba(1, 1, 1, 0.45)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        Item { width: 1; height: Style.space(6) }

        // 7-day sparkline
        Item {
          width: parent.width
          height: Style.space(38)
          Repeater {
            model: root.series
            delegate: Rectangle {
              readonly property int n: root.series.length
              readonly property real gap: Style.space(4)
              width: (content.width - (n - 1) * gap) / Math.max(1, n)
              x: index * (width + gap)
              height: Math.max(Style.space(3), (parent.height) * (Number(modelData.visitors) || 0) / root.maxV)
              y: parent.height - height
              radius: 2
              color: Qt.rgba(1, 1, 1, index === n - 1 ? 0.85 : 0.5)
            }
          }
        }

        Text {
          visible: root.stats !== null
          text: root.stats ? (root.fmtInt(root.stats.visitors) + " visitors · last 7 days") : ""
          color: Qt.rgba(1, 1, 1, 0.55)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
