import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// The Statable desktop card: a glass tile pinned to the top-left of the
// wallpaper, on the Bottom layer (above the wallpaper, below windows), always
// visible. It shows the site, the visitors active right now inside a ring that
// reads today against yesterday, and today's traffic by the hour — a solid
// area for today, a dotted line for the same hours yesterday.
//
// Data is the statable CLI on a one-minute timer; each command prints and
// exits, off the UI thread. A non-zero exit leaves that part blank rather than
// a wrong figure. Clicking the card opens the dashboard.
Item {
  id: root

  property string site: "example.com"
  property string dashUrl: "https://statable.com/share/03D3Cfb9eA"

  property string nowCount: ""
  property var hourly: []          // [{time, visitors, visitors_previous}]

  // Statable brand blue, lifted a touch for legibility on dark glass.
  readonly property color brand: "#2f7bff"

  readonly property real todaySum: {
    var s = 0; for (var i = 0; i < hourly.length; i++) s += Number(hourly[i].visitors) || 0; return s
  }
  readonly property real yestSum: {
    var s = 0; for (var i = 0; i < hourly.length; i++) s += Number(hourly[i].visitors_previous) || 0; return s
  }
  readonly property real dayRatio: yestSum > 0 ? todaySum / yestSum : (todaySum > 0 ? 1.4 : 0)
  readonly property bool ahead: todaySum >= yestSum && yestSum > 0

  function poll() {
    if (!nowP.running) nowP.running = true
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
    id: serP
    command: ["statable", "series", "--by", "hour", "--range", "1d", "--compare", "previous_period", "--format", "json"]
    stdout: StdioCollector { id: serO; waitForEnd: true }
    onExited: function (c) {
      try { var a = c === 0 ? JSON.parse(serO.text) : []; root.hourly = Array.isArray(a) ? a : [] }
      catch (e) { root.hourly = [] }
    }
  }
  Process { id: opener; command: ["xdg-open", root.dashUrl] }

  function fmtInt(n) { return String(Math.round(n)).replace(/\B(?=(\d{3})+(?!\d))/g, " ") }

  onHourlyChanged: { chart.requestPaint(); ring.requestPaint() }

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
      width: Style.space(276)
      height: content.implicitHeight + Style.space(36)
      radius: Style.space(20)
      color: Qt.rgba(0.055, 0.043, 0.078, 0.44)
      // G4: a Statable-blue edge with a faint glow ring.
      border.color: Qt.rgba(0.184, 0.482, 1.0, 0.42)
      border.width: 1

      Rectangle {
        anchors.fill: parent
        anchors.margins: -1
        radius: parent.radius + 1
        color: "transparent"
        border.color: Qt.rgba(0.184, 0.482, 1.0, 0.12)
        border.width: 1
      }

      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: opener.running = true
      }

      Column {
        id: content
        anchors { left: parent.left; right: parent.right; top: parent.top; margins: Style.space(18) }
        spacing: Style.space(12)

        // header: site + real logo (I1)
        Item {
          width: parent.width
          height: Math.max(logo.height, siteText.height)
          Text {
            id: siteText
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            text: root.site
            color: Qt.rgba(1, 1, 1, 0.62)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
          Image {
            id: logo
            anchors.verticalCenter: parent.verticalCenter
            anchors.right: parent.right
            source: Qt.resolvedUrl("logo.png")
            sourceSize.width: Style.space(22)
            sourceSize.height: Style.space(22)
            width: Style.space(22); height: Style.space(22)
            smooth: true
            fillMode: Image.PreserveAspectFit
          }
        }

        // ring + big number (N10)
        Row {
          spacing: Style.space(14)
          Item {
            width: Style.space(58); height: Style.space(58)
            Canvas {
              id: ring
              anchors.fill: parent
              onPaint: {
                var ctx = getContext("2d")
                var w = width, h = height
                ctx.reset()
                var cx = w / 2, cy = h / 2, r = w / 2 - 3
                // track
                ctx.beginPath(); ctx.arc(cx, cy, r, 0, Math.PI * 2)
                ctx.strokeStyle = "rgba(255,255,255,0.13)"; ctx.lineWidth = 4; ctx.stroke()
                // fill arc = today vs yesterday, clamped
                var frac = Math.max(0.04, Math.min(1, root.dayRatio))
                ctx.beginPath()
                ctx.arc(cx, cy, r, -Math.PI / 2, -Math.PI / 2 + frac * Math.PI * 2)
                ctx.strokeStyle = root.brand; ctx.lineWidth = 4; ctx.lineCap = "round"; ctx.stroke()
              }
            }
            Text {
              anchors.centerIn: parent
              text: root.nowCount === "" ? "—" : root.nowCount
              color: "#ffffff"
              font.family: Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
            }
          }
          Column {
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)
            Text {
              text: "active now"
              color: "#ffffff"
              font.family: Style.font.family
              font.pixelSize: Style.font.subtitle
            }
            Text {
              text: root.yestSum > 0
                    ? (root.ahead ? "▲ " : "▼ ") + Math.round(Math.abs(root.dayRatio - 1) * 100) + "% vs yesterday"
                    : "today"
              color: Qt.rgba(1, 1, 1, 0.5)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }

        // chart: today hourly area (solid) + yesterday dotted (C4, today+prev)
        Canvas {
          id: chart
          width: parent.width
          height: Style.space(52)
          onPaint: {
            var ctx = getContext("2d")
            var w = width, h = height
            ctx.reset()
            var data = root.hourly
            var n = data.length
            if (n < 2) return
            var maxv = 1
            for (var i = 0; i < n; i++) {
              maxv = Math.max(maxv, Number(data[i].visitors) || 0, Number(data[i].visitors_previous) || 0)
            }
            var padTop = 4, padBot = 2
            function X(i) { return (w) * i / (n - 1) }
            function Y(v) { return padTop + (h - padTop - padBot) * (1 - (v / maxv)) }

            // yesterday: dotted line
            ctx.beginPath()
            for (var j = 0; j < n; j++) {
              var yp = Y(Number(data[j].visitors_previous) || 0)
              if (j === 0) ctx.moveTo(X(j), yp); else ctx.lineTo(X(j), yp)
            }
            ctx.setLineDash([2, 3])
            ctx.strokeStyle = "rgba(255,255,255,0.5)"; ctx.lineWidth = 1.4; ctx.stroke()
            ctx.setLineDash([])

            // today: filled area + solid stroke
            ctx.beginPath()
            ctx.moveTo(X(0), Y(Number(data[0].visitors) || 0))
            for (var k = 1; k < n; k++) ctx.lineTo(X(k), Y(Number(data[k].visitors) || 0))
            var grad = ctx.createLinearGradient(0, 0, 0, h)
            grad.addColorStop(0, "rgba(47,123,255,0.5)")
            grad.addColorStop(1, "rgba(47,123,255,0.0)")
            ctx.lineTo(X(n - 1), h); ctx.lineTo(X(0), h); ctx.closePath()
            ctx.fillStyle = grad; ctx.fill()

            ctx.beginPath()
            ctx.moveTo(X(0), Y(Number(data[0].visitors) || 0))
            for (var m = 1; m < n; m++) ctx.lineTo(X(m), Y(Number(data[m].visitors) || 0))
            ctx.strokeStyle = root.brand; ctx.lineWidth = 1.8; ctx.lineJoin = "round"; ctx.stroke()
            // endpoint dot
            var ex = X(n - 1), ey = Y(Number(data[n - 1].visitors) || 0)
            ctx.beginPath(); ctx.arc(ex, ey, 2.6, 0, Math.PI * 2); ctx.fillStyle = root.brand; ctx.fill()
          }
        }

        // quiet footer: today vs yesterday totals, and legend
        Item {
          width: parent.width
          height: footLeft.height
          Text {
            id: footLeft
            anchors.left: parent.left
            text: "today " + root.fmtInt(root.todaySum)
            color: Qt.rgba(1, 1, 1, 0.58)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
          Text {
            anchors.right: parent.right
            anchors.verticalCenter: footLeft.verticalCenter
            text: "┄┄ yesterday"
            color: Qt.rgba(1, 1, 1, 0.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
