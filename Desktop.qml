import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// The Statable desktop card: a compact glass tile pinned to the top-left of
// the wallpaper, on the Bottom layer (above the wallpaper, below windows).
//
// The ring around the live count is a countdown to the next refresh: it fills
// over a minute, and when it completes the data reloads and it starts again.
// The chart is today's traffic by the hour (solid) against the same hours
// yesterday (dotted); hover it to read a single hour. Clicking opens the
// dashboard. Data is the statable CLI, off the UI thread; a non-zero exit
// leaves that part blank rather than a wrong figure.
Item {
  id: root

  property string site: "example.com"
  property string dashUrl: "https://statable.com/share/03D3Cfb9eA"
  readonly property int refreshMs: 60000

  property string nowCount: ""
  property var hourly: []               // [{time, visitors, visitors_previous}]
  property real refreshProgress: 0      // 0..1, drives the ring countdown
  property int hoverIndex: -1

  // Neutral glass; blue is used only where it means Statable — the logo, the
  // countdown ring, the endpoint — so the card sits calmly on any wallpaper.
  readonly property color brand: "#3f86ff"

  readonly property real todaySum: {
    var s = 0; for (var i = 0; i < hourly.length; i++) s += Number(hourly[i].visitors) || 0; return s
  }
  readonly property real yestSum: {
    var s = 0; for (var i = 0; i < hourly.length; i++) s += Number(hourly[i].visitors_previous) || 0; return s
  }

  function poll() {
    if (!nowP.running) nowP.running = true
    if (!serP.running) serP.running = true
  }
  Component.onCompleted: { poll(); ringAnim.restart() }

  Timer {
    interval: root.refreshMs; running: true; repeat: true
    onTriggered: { root.poll(); ringAnim.restart() }
  }
  NumberAnimation {
    id: ringAnim; target: root; property: "refreshProgress"
    from: 0; to: 1; duration: root.refreshMs; running: true
  }
  onRefreshProgressChanged: ring.requestPaint()

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
  // Fit the live number to the ring: fewer digits, bigger.
  function nowSize() {
    var L = root.nowCount.length
    if (L <= 1) return Style.space(24)
    if (L === 2) return Style.space(20)
    if (L === 3) return Style.space(16)
    if (L === 4) return Style.space(13)
    return Style.space(11)
  }
  function hourLabel(t) { var s = String(t || ""); var p = s.split(" "); return p.length > 1 ? p[1] : s }

  onHourlyChanged: chart.requestPaint()
  onHoverIndexChanged: chart.requestPaint()

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
      width: Style.space(232)
      height: content.implicitHeight + Style.space(28)
      radius: Style.space(18)
      color: Qt.rgba(0.04, 0.04, 0.055, 0.52)
      border.color: Qt.rgba(1, 1, 1, 0.11)
      border.width: 1

      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: opener.running = true
      }

      Column {
        id: content
        anchors { left: parent.left; right: parent.right; top: parent.top; margins: Style.space(14) }
        spacing: Style.space(11)

        // header: site + real logo (I1)
        Item {
          width: parent.width
          height: Style.space(20)
          Text {
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            text: root.site
            color: Qt.rgba(1, 1, 1, 0.6)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
          Image {
            anchors.verticalCenter: parent.verticalCenter
            anchors.right: parent.right
            source: Qt.resolvedUrl("logo.png")
            sourceSize.width: Style.space(18); sourceSize.height: Style.space(18)
            width: Style.space(18); height: Style.space(18)
            smooth: true; fillMode: Image.PreserveAspectFit
          }
        }

        // ring countdown + auto-fit number + label
        Row {
          spacing: Style.space(11)
          Item {
            width: Style.space(46); height: Style.space(46)
            Canvas {
              id: ring
              anchors.fill: parent
              onPaint: {
                var ctx = getContext("2d"); ctx.reset()
                var cx = width / 2, cy = height / 2, r = width / 2 - 3
                ctx.beginPath(); ctx.arc(cx, cy, r, 0, Math.PI * 2)
                ctx.strokeStyle = "rgba(255,255,255,0.12)"; ctx.lineWidth = 3; ctx.stroke()
                var a0 = -Math.PI / 2
                ctx.beginPath(); ctx.arc(cx, cy, r, a0, a0 + root.refreshProgress * Math.PI * 2)
                ctx.strokeStyle = root.brand; ctx.lineWidth = 3; ctx.lineCap = "round"; ctx.stroke()
              }
            }
            Text {
              anchors.centerIn: parent
              text: root.nowCount === "" ? "—" : root.nowCount
              color: "#ffffff"
              font.family: Style.font.family
              font.pixelSize: root.nowSize()
              font.bold: true
            }
          }
          Column {
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(1)
            Text {
              text: "active now"
              color: "#ffffff"
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }
            Text {
              text: "refreshes each minute"
              color: Qt.rgba(1, 1, 1, 0.42)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }

        // chart: today hourly (solid) vs yesterday (dotted), hover to read an hour
        Item {
          width: parent.width
          height: Style.space(46)

          Canvas {
            id: chart
            anchors.fill: parent
            property real padTop: 4
            property real padBot: 2
            function xAt(i, n) { return width * i / Math.max(1, n - 1) }
            function yAt(v, maxv) { return padTop + (height - padTop - padBot) * (1 - (v / maxv)) }
            onPaint: {
              var ctx = getContext("2d"); ctx.reset()
              var data = root.hourly, n = data.length
              if (n < 2) return
              var maxv = 1
              for (var i = 0; i < n; i++) maxv = Math.max(maxv, Number(data[i].visitors) || 0, Number(data[i].visitors_previous) || 0)

              // yesterday: dotted
              ctx.beginPath()
              for (var j = 0; j < n; j++) {
                var yp = yAt(Number(data[j].visitors_previous) || 0, maxv)
                if (j === 0) ctx.moveTo(xAt(j, n), yp); else ctx.lineTo(xAt(j, n), yp)
              }
              ctx.setLineDash([2, 3]); ctx.strokeStyle = "rgba(255,255,255,0.42)"; ctx.lineWidth = 1.3; ctx.stroke(); ctx.setLineDash([])

              // today: area + solid white line
              ctx.beginPath(); ctx.moveTo(xAt(0, n), yAt(Number(data[0].visitors) || 0, maxv))
              for (var k = 1; k < n; k++) ctx.lineTo(xAt(k, n), yAt(Number(data[k].visitors) || 0, maxv))
              var g = ctx.createLinearGradient(0, 0, 0, height)
              g.addColorStop(0, "rgba(255,255,255,0.22)"); g.addColorStop(1, "rgba(255,255,255,0.0)")
              ctx.lineTo(xAt(n - 1, n), height); ctx.lineTo(xAt(0, n), height); ctx.closePath(); ctx.fillStyle = g; ctx.fill()

              ctx.beginPath(); ctx.moveTo(xAt(0, n), yAt(Number(data[0].visitors) || 0, maxv))
              for (var m = 1; m < n; m++) ctx.lineTo(xAt(m, n), yAt(Number(data[m].visitors) || 0, maxv))
              ctx.strokeStyle = "rgba(255,255,255,0.92)"; ctx.lineWidth = 1.6; ctx.lineJoin = "round"; ctx.stroke()

              // hover guide + points
              var hi = root.hoverIndex
              if (hi >= 0 && hi < n) {
                var hx = xAt(hi, n)
                ctx.beginPath(); ctx.moveTo(hx, 0); ctx.lineTo(hx, height)
                ctx.strokeStyle = "rgba(255,255,255,0.25)"; ctx.lineWidth = 1; ctx.stroke()
                var ty = yAt(Number(data[hi].visitors) || 0, maxv)
                ctx.beginPath(); ctx.arc(hx, ty, 3, 0, Math.PI * 2); ctx.fillStyle = root.brand; ctx.fill()
              } else {
                // endpoint dot when not hovering
                var ex = xAt(n - 1, n), ey = yAt(Number(data[n - 1].visitors) || 0, maxv)
                ctx.beginPath(); ctx.arc(ex, ey, 2.4, 0, Math.PI * 2); ctx.fillStyle = root.brand; ctx.fill()
              }
            }
          }

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onPositionChanged: function (m) {
              var n = root.hourly.length
              if (n < 2) { root.hoverIndex = -1; return }
              var idx = Math.round(m.x / width * (n - 1))
              root.hoverIndex = Math.max(0, Math.min(n - 1, idx))
            }
            onExited: root.hoverIndex = -1
            onClicked: opener.running = true
          }

          // hover tooltip
          Rectangle {
            visible: root.hoverIndex >= 0 && root.hoverIndex < root.hourly.length
            radius: Style.space(6)
            color: Qt.rgba(0, 0, 0, 0.82)
            border.color: Qt.rgba(1, 1, 1, 0.12); border.width: 1
            width: tip.implicitWidth + Style.space(14)
            height: tip.implicitHeight + Style.space(10)
            x: {
              if (root.hoverIndex < 0) return 0
              var n = Math.max(1, root.hourly.length - 1)
              var hx = chart.width * root.hoverIndex / n
              return Math.max(0, Math.min(parent.width - width, hx - width / 2))
            }
            y: -height - Style.space(4)
            Column {
              id: tip
              anchors.centerIn: parent
              spacing: Style.space(1)
              Text {
                text: root.hoverIndex >= 0 ? root.hourLabel(root.hourly[root.hoverIndex].time) : ""
                color: "#fff"; font.family: Style.font.family; font.pixelSize: Style.font.caption; font.bold: true
              }
              Text {
                text: root.hoverIndex >= 0 ? ("today " + root.fmtInt(root.hourly[root.hoverIndex].visitors || 0)) : ""
                color: Qt.rgba(1, 1, 1, 0.85); font.family: Style.font.family; font.pixelSize: Style.font.caption
              }
              Text {
                text: root.hoverIndex >= 0 ? ("yest  " + root.fmtInt(root.hourly[root.hoverIndex].visitors_previous || 0)) : ""
                color: Qt.rgba(1, 1, 1, 0.55); font.family: Style.font.family; font.pixelSize: Style.font.caption
              }
            }
          }
        }

        // footer: both real totals, each with its line marker
        Item {
          width: parent.width
          height: Style.space(14)
          Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)
            Rectangle { anchors.verticalCenter: parent.verticalCenter; width: Style.space(10); height: 2; color: Qt.rgba(1,1,1,0.92) }
            Text { text: "today " + root.fmtInt(root.todaySum); color: Qt.rgba(1, 1, 1, 0.72); font.family: Style.font.family; font.pixelSize: Style.font.caption }
          }
          Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)
            Rectangle { anchors.verticalCenter: parent.verticalCenter; width: Style.space(10); height: 2; color: Qt.rgba(1,1,1,0.4); opacity: 0.9 }
            Text { text: "yest " + root.fmtInt(root.yestSum); color: Qt.rgba(1, 1, 1, 0.5); font.family: Style.font.family; font.pixelSize: Style.font.caption }
          }
        }
      }
    }
  }
}
