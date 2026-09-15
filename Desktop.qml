import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// The Statable desktop card: a glass tile on the wallpaper (Bottom layer,
// above the wallpaper, below windows), always visible.
//
// It is configured from ~/.local/state/omarchy/settings/statable-desktop.json
// (the Omarchy plugin-settings convention). All keys are optional:
//   corner   "top-left" | "top-right" | "bottom-left" | "bottom-right"
//   monitor  output name (e.g. "DP-1"); empty = wherever the shell puts it
//   margin   gap from the screen edge, px
//   site     domain or id to show; empty = the statable CLI's default site
//
// The site, its dashboard link and the numbers all follow the CLI's default
// site unless `site` overrides it, so `statable sites use <domain>` moves the
// whole card to another site. The ring is a countdown to the next refresh;
// the chart is today by the hour against yesterday. Data is the statable CLI,
// off the UI thread; a non-zero exit leaves that part blank.
Item {
  id: root

  // ---- config (read from the settings file) ----
  property string cfgCorner: "top-left"
  property string cfgMonitor: ""
  property int cfgMargin: 28
  property string cfgSite: ""

  FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/settings/statable-desktop.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.applyConfig(text())
    onLoadFailed: root.applyConfig("")
  }
  function applyConfig(txt) {
    var c = {}
    try { if (txt) c = JSON.parse(txt) } catch (e) { c = {} }
    root.cfgCorner = c.corner || "top-left"
    root.cfgMonitor = c.monitor || ""
    root.cfgMargin = (c.margin === undefined || c.margin === null) ? 28 : c.margin
    root.cfgSite = c.site || ""
    root.fetchSite()
  }

  // ---- resolved site ----
  property string siteName: ""                                   // domain shown
  property string dashUrl: "https://statable.com"                // dashboard link
  property string siteArg: ""                                    // --site value, or ""

  function domainOf(u) { return String(u || "").replace(/^https?:\/\//, "").replace(/\/+$/, "") }
  function pickSite(arr) {
    if (!Array.isArray(arr) || arr.length === 0) return null
    if (root.cfgSite) {
      for (var i = 0; i < arr.length; i++)
        if (root.domainOf(arr[i].name) === root.cfgSite || String(arr[i].site_id) === root.cfgSite) return arr[i]
    }
    for (var j = 0; j < arr.length; j++) if (arr[j].default) return arr[j]
    return arr[0]
  }

  property string nowCount: ""
  property var hourly: []
  property real refreshProgress: 0
  property int hoverIndex: -1

  readonly property color brand: "#3f86ff"
  readonly property string fontFamily: Style.font.family

  readonly property real todaySum: { var s = 0; for (var i = 0; i < hourly.length; i++) s += Number(hourly[i].visitors) || 0; return s }
  readonly property real yestSum: { var s = 0; for (var i = 0; i < hourly.length; i++) s += Number(hourly[i].visitors_previous) || 0; return s }

  readonly property int refreshMs: 60000

  function withSite(base) { return root.siteArg === "" ? base : base.concat(["--site", root.siteArg]) }
  function fetchSite() { if (!sitesP.running) sitesP.running = true }
  function poll() {
    if (!nowP.running) nowP.running = true
    if (!serP.running) serP.running = true
  }
  Component.onCompleted: { fetchSite(); poll(); ringAnim.restart() }

  Timer {
    interval: root.refreshMs; running: true; repeat: true
    onTriggered: { root.poll(); ringAnim.restart() }
  }
  NumberAnimation { id: ringAnim; target: root; property: "refreshProgress"; from: 0; to: 1; duration: root.refreshMs; running: true }
  onRefreshProgressChanged: ring.requestPaint()
  onNowCountChanged: ring.requestPaint()
  onHourlyChanged: chart.requestPaint()
  onHoverIndexChanged: chart.requestPaint()

  Process {
    id: sitesP
    command: ["statable", "sites", "--format", "json"]
    stdout: StdioCollector { id: sitesO; waitForEnd: true }
    onExited: function (c) {
      var s = null
      try { if (c === 0) s = root.pickSite(JSON.parse(sitesO.text)) } catch (e) { s = null }
      if (s) {
        root.siteName = root.domainOf(s.name)
        root.dashUrl = s.hash ? ("https://statable.com/share/" + s.hash) : "https://statable.com"
        root.siteArg = root.cfgSite ? String(s.site_id) : ""
      }
      root.poll()
    }
  }
  Process {
    id: nowP
    command: root.withSite(["statable", "now"])
    stdout: StdioCollector { id: nowO; waitForEnd: true }
    onExited: function (c) { root.nowCount = c === 0 ? String(nowO.text || "").trim() : "" }
  }
  Process {
    id: serP
    command: root.withSite(["statable", "series", "--by", "hour", "--range", "1d", "--compare", "previous_period", "--format", "json"])
    stdout: StdioCollector { id: serO; waitForEnd: true }
    onExited: function (c) {
      try { var a = c === 0 ? JSON.parse(serO.text) : []; root.hourly = Array.isArray(a) ? a : [] }
      catch (e) { root.hourly = [] }
    }
  }
  Process { id: opener; command: ["xdg-open", root.dashUrl] }

  function fmtInt(n) { return String(Math.round(n)).replace(/\B(?=(\d{3})+(?!\d))/g, " ") }
  function nowSize() {
    var L = root.nowCount.length
    if (L <= 1) return Style.space(25)
    if (L === 2) return Style.space(20)
    if (L === 3) return Style.space(16)
    if (L === 4) return Style.space(13)
    return Style.space(11)
  }
  function hourLabel(t) { var s = String(t || ""); var p = s.split(" "); return p.length > 1 ? p[1] : s }

  function screenFor(name) {
    if (!name) return null
    var ss = Quickshell.screens
    for (var i = 0; i < ss.length; i++) if (ss[i].name === name) return ss[i]
    return null
  }
  readonly property bool anchorTop: root.cfgCorner.indexOf("bottom") < 0
  readonly property bool anchorLeft: root.cfgCorner.indexOf("right") < 0

  PanelWindow {
    id: win
    visible: true
    color: "transparent"
    screen: root.screenFor(root.cfgMonitor)
    WlrLayershell.namespace: "omarchy-statable-desktop"
    WlrLayershell.layer: WlrLayer.Bottom
    exclusiveZone: 0
    anchors {
      top: root.anchorTop
      bottom: !root.anchorTop
      left: root.anchorLeft
      right: !root.anchorLeft
    }
    margins.top: root.anchorTop ? Style.space(root.cfgMargin) : 0
    margins.bottom: root.anchorTop ? 0 : Style.space(root.cfgMargin)
    margins.left: root.anchorLeft ? Style.space(root.cfgMargin) : 0
    margins.right: root.anchorLeft ? 0 : Style.space(root.cfgMargin)
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

        Item {
          width: parent.width
          height: Style.space(20)
          Text {
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            text: root.siteName || root.cfgSite || "…"
            color: Qt.rgba(1, 1, 1, 0.6)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            width: parent.width - Style.space(26)
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

        Row {
          spacing: Style.space(11)
          Canvas {
            id: ring
            width: Style.space(46); height: Style.space(46)
            onPaint: {
              var ctx = getContext("2d"); ctx.reset()
              var cx = width / 2, cy = height / 2, r = width / 2 - 3
              ctx.beginPath(); ctx.arc(cx, cy, r, 0, Math.PI * 2)
              ctx.strokeStyle = "rgba(255,255,255,0.12)"; ctx.lineWidth = 3; ctx.stroke()
              var a0 = -Math.PI / 2
              ctx.beginPath(); ctx.arc(cx, cy, r, a0, a0 + root.refreshProgress * Math.PI * 2)
              ctx.strokeStyle = root.brand; ctx.lineWidth = 3; ctx.lineCap = "round"; ctx.stroke()

              var txt = root.nowCount === "" ? "—" : root.nowCount
              var small = txt.length <= 1
              ctx.textAlign = "center"; ctx.textBaseline = "middle"
              var ny = cy + root.nowSize() * 0.16
              ctx.font = (small ? "800 " : "700 ") + root.nowSize() + "px " + root.fontFamily
              ctx.shadowColor = small ? "rgba(80,150,255,0.95)" : "rgba(255,255,255,0.35)"
              ctx.shadowBlur = small ? 14 : 6
              ctx.fillStyle = "#ffffff"
              ctx.fillText(txt, cx, ny)
              ctx.fillText(txt, cx, ny)
              ctx.shadowBlur = 0
              ctx.fillText(txt, cx, ny)
            }
          }
          Column {
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(1)
            Text { text: "active now"; color: "#ffffff"; font.family: Style.font.family; font.pixelSize: Style.font.body }
            Text { text: "refreshes each minute"; color: Qt.rgba(1, 1, 1, 0.42); font.family: Style.font.family; font.pixelSize: Style.font.caption }
          }
        }

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

              ctx.beginPath()
              for (var j = 0; j < n; j++) { var yp = yAt(Number(data[j].visitors_previous) || 0, maxv); if (j === 0) ctx.moveTo(xAt(j, n), yp); else ctx.lineTo(xAt(j, n), yp) }
              ctx.setLineDash([2, 3]); ctx.strokeStyle = "rgba(255,255,255,0.42)"; ctx.lineWidth = 1.3; ctx.stroke(); ctx.setLineDash([])

              ctx.beginPath(); ctx.moveTo(xAt(0, n), yAt(Number(data[0].visitors) || 0, maxv))
              for (var k = 1; k < n; k++) ctx.lineTo(xAt(k, n), yAt(Number(data[k].visitors) || 0, maxv))
              var g = ctx.createLinearGradient(0, 0, 0, height)
              g.addColorStop(0, "rgba(255,255,255,0.22)"); g.addColorStop(1, "rgba(255,255,255,0.0)")
              ctx.lineTo(xAt(n - 1, n), height); ctx.lineTo(xAt(0, n), height); ctx.closePath(); ctx.fillStyle = g; ctx.fill()

              ctx.beginPath(); ctx.moveTo(xAt(0, n), yAt(Number(data[0].visitors) || 0, maxv))
              for (var m = 1; m < n; m++) ctx.lineTo(xAt(m, n), yAt(Number(data[m].visitors) || 0, maxv))
              ctx.strokeStyle = "rgba(255,255,255,0.92)"; ctx.lineWidth = 1.6; ctx.lineJoin = "round"; ctx.stroke()

              var hi = root.hoverIndex
              if (hi >= 0 && hi < n) {
                var hx = xAt(hi, n)
                ctx.beginPath(); ctx.moveTo(hx, 0); ctx.lineTo(hx, height); ctx.strokeStyle = "rgba(255,255,255,0.25)"; ctx.lineWidth = 1; ctx.stroke()
                var ty = yAt(Number(data[hi].visitors) || 0, maxv)
                ctx.beginPath(); ctx.arc(hx, ty, 3, 0, Math.PI * 2); ctx.fillStyle = "#ffffff"; ctx.fill()
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
              root.hoverIndex = Math.max(0, Math.min(n - 1, Math.round(m.x / width * (n - 1))))
            }
            onExited: root.hoverIndex = -1
            onClicked: opener.running = true
          }
          Rectangle {
            visible: root.hoverIndex >= 0 && root.hoverIndex < root.hourly.length
            radius: Style.space(7)
            color: Qt.rgba(0.22, 0.20, 0.30, 0.82)
            border.color: Qt.rgba(1, 1, 1, 0.18); border.width: 1
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
              Text { text: root.hoverIndex >= 0 ? root.hourLabel(root.hourly[root.hoverIndex].time) : ""; color: "#fff"; font.family: Style.font.family; font.pixelSize: Style.font.caption; font.bold: true }
              Text { text: root.hoverIndex >= 0 ? ("today " + root.fmtInt(root.hourly[root.hoverIndex].visitors || 0)) : ""; color: Qt.rgba(1, 1, 1, 0.85); font.family: Style.font.family; font.pixelSize: Style.font.caption }
              Text { text: root.hoverIndex >= 0 ? ("yesterday " + root.fmtInt(root.hourly[root.hoverIndex].visitors_previous || 0)) : ""; color: Qt.rgba(1, 1, 1, 0.55); font.family: Style.font.family; font.pixelSize: Style.font.caption }
            }
          }
        }

        Item {
          width: parent.width
          height: Style.space(14)
          Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)
            Canvas {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(16); height: Style.space(9)
              onPaint: { var ctx = getContext("2d"); ctx.reset(); ctx.beginPath(); ctx.moveTo(0, 7); ctx.lineTo(width * 0.33, 2); ctx.lineTo(width * 0.66, 7); ctx.lineTo(width, 2); ctx.strokeStyle = "rgba(255,255,255,0.92)"; ctx.lineWidth = 1.5; ctx.lineJoin = "round"; ctx.stroke() }
            }
            Text { text: "today " + root.fmtInt(root.todaySum); color: Qt.rgba(1, 1, 1, 0.72); font.family: Style.font.family; font.pixelSize: Style.font.caption }
          }
          Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)
            Canvas {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(16); height: Style.space(9)
              onPaint: { var ctx = getContext("2d"); ctx.reset(); ctx.setLineDash([2, 2]); ctx.beginPath(); ctx.moveTo(0, 7); ctx.lineTo(width * 0.33, 2); ctx.lineTo(width * 0.66, 7); ctx.lineTo(width, 2); ctx.strokeStyle = "rgba(255,255,255,0.5)"; ctx.lineWidth = 1.5; ctx.lineJoin = "round"; ctx.stroke() }
            }
            Text { text: "yesterday " + root.fmtInt(root.yestSum); color: Qt.rgba(1, 1, 1, 0.5); font.family: Style.font.family; font.pixelSize: Style.font.caption }
          }
        }
      }
    }
  }
}
