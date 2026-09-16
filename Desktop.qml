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
// off the UI thread; a non-zero exit leaves that part blank. Each call has a
// deadline and an output cap (see Fetch), what it returns is validated and
// capped before it becomes the model, and every value from the API is
// rendered as plain text.
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
    var n = Math.min(arr.length, 500)
    var ok = function (x) { return x && typeof x === "object" }
    if (root.cfgSite) {
      for (var i = 0; i < n; i++)
        if (ok(arr[i]) && (root.domainOf(arr[i].name) === root.cfgSite || String(arr[i].site_id) === root.cfgSite)) return arr[i]
    }
    for (var j = 0; j < n; j++) if (ok(arr[j]) && arr[j].default) return arr[j]
    return ok(arr[0]) ? arr[0] : null
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

  // Bounds on what a CLI call may hand back. The CLI prints a few hundred
  // bytes and exits; a call that runs past the deadline or past the output
  // cap is killed and its output dropped, so a stalled or runaway response
  // can neither keep a process alive nor grow inside the shell. The series
  // is a day by the hour, so 48 points is already twice what it can hold.
  readonly property int fetchDeadlineMs: 15000
  readonly property int fetchCapChars: 65536
  readonly property int maxPoints: 48
  readonly property int maxNameChars: 96

  function withSite(base) { return root.siteArg === "" ? base : base.concat(["--site", root.siteArg]) }
  function fetchSite() { sitesF.start() }
  function poll() { nowF.start(); serF.start() }
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

  // One `statable` call, bounded: a deadline, a cap on stdout while it
  // streams, and SIGKILL when either trips. `done` reports ok only for a
  // clean exit within both bounds, and the text is empty otherwise. A call
  // already running is not started again.
  component Fetch: Item {
    id: fetch
    property var command: []
    property string buf: ""
    property bool tripped: false
    signal done(bool ok, string text)
    function start() { if (!proc.running) proc.running = true }
    function trip() { fetch.tripped = true; proc.signal(9) }
    Process {
      id: proc
      command: fetch.command
      stdout: SplitParser {
        splitMarker: ""   // every chunk as it arrives, not whole lines
        onRead: function (data) {
          if (fetch.tripped) return
          fetch.buf += data
          if (fetch.buf.length > root.fetchCapChars) fetch.trip()
        }
      }
      onStarted: { fetch.buf = ""; fetch.tripped = false; deadline.restart() }
      onExited: function (code) {
        deadline.stop()
        var ok = code === 0 && !fetch.tripped
        var text = fetch.buf
        fetch.buf = ""
        fetch.done(ok, ok ? text : "")
      }
    }
    Timer { id: deadline; interval: root.fetchDeadlineMs; onTriggered: fetch.trip() }
  }

  // ---- what comes back is checked before it is shown ----
  function asCount(s) {                       // digits only, else "no data"
    var t = String(s || "").trim()
    return /^\d{1,12}$/.test(t) ? t : ""
  }
  function asNum(v) {                         // finite, non-negative, or null
    var n = Number(v)
    return (isFinite(n) && n >= 0 && n <= 1e12) ? n : null
  }
  function asText(v, max) {
    return String(v === undefined || v === null ? "" : v).slice(0, max)
  }

  Fetch {
    id: sitesF
    command: ["statable", "sites", "--format", "json"]
    onDone: function (ok, text) {
      var s = null
      try { if (ok) s = root.pickSite(JSON.parse(text)) } catch (e) { s = null }
      if (s && typeof s === "object") {
        root.siteName = root.asText(root.domainOf(s.name), root.maxNameChars)
        // The dashboard link is assembled here, never taken from the
        // response: only a share hash of the expected shape reaches xdg-open.
        var h = String(s.hash === undefined || s.hash === null ? "" : s.hash)
        root.dashUrl = /^[A-Za-z0-9_-]{1,64}$/.test(h) ? ("https://statable.com/share/" + h) : "https://statable.com"
        var id = String(s.site_id === undefined || s.site_id === null ? "" : s.site_id)
        root.siteArg = (root.cfgSite && /^[A-Za-z0-9_.-]{1,64}$/.test(id)) ? id : ""
      }
      root.poll()
    }
  }
  Fetch {
    id: nowF
    command: root.withSite(["statable", "now"])
    onDone: function (ok, text) { root.nowCount = ok ? root.asCount(text) : "" }
  }
  Fetch {
    id: serF
    command: root.withSite(["statable", "series", "--by", "hour", "--range", "1d", "--compare", "previous_period", "--format", "json"])
    onDone: function (ok, text) {
      var a = []
      try { if (ok) a = JSON.parse(text) } catch (e) { a = [] }
      if (!Array.isArray(a)) a = []
      var out = []
      for (var i = 0; i < a.length && out.length < root.maxPoints; i++) {
        var p = a[i]
        if (!p || typeof p !== "object") continue
        out.push({
          time: root.asText(p.time, 32),
          visitors: root.asNum(p.visitors) || 0,
          visitors_previous: root.asNum(p.visitors_previous) || 0
        })
      }
      root.hourly = out
    }
  }
  Process { id: opener; command: ["xdg-open", root.dashUrl] }
  // Settings live on the card, not in an external editor: the machine's
  // default editor is the only handler for the file and may be mid-setup.
  property bool settingsOpen: false
  property string cfgPath: Quickshell.env("HOME") + "/.local/state/omarchy/settings/statable-desktop.json"
  Process { id: writer }
  function saveCorner(corner) {
    var obj = { corner: corner, monitor: root.cfgMonitor || "", margin: root.cfgMargin, site: root.cfgSite || "" }
    // JSON and path are separate argv, so nothing needs escaping.
    writer.command = ["sh", "-c", "mkdir -p \"$(dirname \"$2\")\"; printf '%s\\n' \"$1\" > \"$2\"",
      "_", JSON.stringify(obj, null, 2), root.cfgPath]
    writer.running = true
  }

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

      // Hover detector only — the card body is not a click target; the logo
      // opens the site, the gear opens the settings.
      MouseArea {
        id: hoverMA
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
      }
      readonly property bool cardHovered: hoverMA.containsMouse || chartHover.containsMouse || gearMA.containsMouse || logoMA.containsMouse

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
            textFormat: Text.PlainText
            color: Qt.rgba(1, 1, 1, 0.6)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            width: parent.width - Style.space(48)
          }
          Row {
            anchors.verticalCenter: parent.verticalCenter
            anchors.right: parent.right
            spacing: Style.space(8)
            // settings gear — appears on hover, opens the config file
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "\uf013"
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              color: Qt.rgba(1, 1, 1, (gearMA.containsMouse || root.settingsOpen) ? 0.95 : 0.6)
              opacity: (card.cardHovered || root.settingsOpen) ? 1 : 0
              Behavior on opacity { NumberAnimation { duration: 120 } }
              MouseArea {
                id: gearMA
                anchors.fill: parent; anchors.margins: -6
                hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                onClicked: root.settingsOpen = !root.settingsOpen
              }
            }
            // logo — the one click target for the site
            Image {
              anchors.verticalCenter: parent.verticalCenter
              source: Qt.resolvedUrl("logo.png")
              sourceSize.width: Style.space(18); sourceSize.height: Style.space(18)
              width: Style.space(18); height: Style.space(18)
              smooth: true; fillMode: Image.PreserveAspectFit
              opacity: logoMA.containsMouse ? 1 : 0.9
              MouseArea {
                id: logoMA
                anchors.fill: parent; anchors.margins: -6
                hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                onClicked: opener.running = true
              }
            }
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
            id: chartHover
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.NoButton
            onPositionChanged: function (m) {
              var n = root.hourly.length
              if (n < 2) { root.hoverIndex = -1; return }
              root.hoverIndex = Math.max(0, Math.min(n - 1, Math.round(m.x / width * (n - 1))))
            }
            onExited: root.hoverIndex = -1
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
              Text { text: root.hoverIndex >= 0 ? root.hourLabel(root.hourly[root.hoverIndex].time) : ""; textFormat: Text.PlainText; color: "#fff"; font.family: Style.font.family; font.pixelSize: Style.font.caption; font.bold: true }
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

      // ---- on-card settings ----
      Rectangle {
        anchors.fill: parent
        radius: card.radius
        visible: root.settingsOpen
        color: Qt.rgba(0.055, 0.05, 0.075, 1.0)
        border.color: Qt.rgba(1, 1, 1, 0.12); border.width: 1
        MouseArea { anchors.fill: parent; hoverEnabled: true }   // swallow hover/clicks

        Column {
          anchors { left: parent.left; right: parent.right; top: parent.top; margins: Style.space(16) }
          spacing: Style.space(12)

          Row {
            width: parent.width
            Text { text: "Settings"; color: "#fff"; font.family: Style.font.family; font.pixelSize: Style.font.body; font.bold: true }
            Item { width: parent.width - 2 * Style.space(50); height: 1 }
            Text {
              text: "\uf00d"   // close
              color: Qt.rgba(1, 1, 1, closeMA.containsMouse ? 0.95 : 0.6)
              font.family: Style.font.family; font.pixelSize: Style.font.body
              MouseArea { id: closeMA; anchors.fill: parent; anchors.margins: -6; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.settingsOpen = false }
            }
          }

          Text { text: "CORNER"; color: Qt.rgba(1, 1, 1, 0.45); font.family: Style.font.family; font.pixelSize: Style.font.caption }
          Grid {
            id: cornerGrid
            width: parent.width
            columns: 2; rowSpacing: Style.space(8); columnSpacing: Style.space(8)
            readonly property real cellW: (width - Style.space(8)) / 2
            Repeater {
              model: [
                { id: "top-left", g: "\uf0d8\uf0d9" },
                { id: "top-right", g: "" },
                { id: "bottom-left", g: "" },
                { id: "bottom-right", g: "" }
              ]
              delegate: Rectangle {
                width: cornerGrid.cellW
                height: Style.space(34)
                radius: Style.space(8)
                readonly property bool active: root.cfgCorner === modelData.id
                color: active ? Qt.rgba(0.184, 0.482, 1.0, 0.22) : Qt.rgba(1, 1, 1, cellMA.containsMouse ? 0.10 : 0.05)
                border.color: active ? root.brand : Qt.rgba(1, 1, 1, 0.12); border.width: 1
                Text {
                  anchors.centerIn: parent
                  text: modelData.id.replace("-", " ")
                  color: active ? "#fff" : Qt.rgba(1, 1, 1, 0.7)
                  font.family: Style.font.family; font.pixelSize: Style.font.caption
                }
                MouseArea { id: cellMA; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.saveCorner(modelData.id) }
              }
            }
          }

          Text {
            width: parent.width
            text: "Site follows the CLI: statable sites use <domain>. Monitor and margin are in the config file."
            color: Qt.rgba(1, 1, 1, 0.45); font.family: Style.font.family; font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
          Text {
            text: "A position change applies on the next shell reload."
            color: Qt.rgba(1, 1, 1, 0.4); font.family: Style.font.family; font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
