import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar presence for the live wallpaper: an icon that shows whether the
// treatment is running, and a panel that tunes it.
//
// Every write goes out through `omarchy-live tune`, never by writing JSON from
// here. The rule for *where* an edit lands — the theme's own spec when it owns
// one and is writable, a per-theme override otherwise — lives in that script,
// and duplicating it in QML would be the first thing to drift.
//
// Every read comes from the resolved spec the service publishes, so the panel
// shows the merged result of all four layers rather than whichever single file
// happens to exist, and follows along when the menu, a terminal or a theme
// switch changes something underneath it.
Panel {
  id: root
  moduleName: "io.github.sumdahl.livewallpaper"
  manageIpc: false

  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || ("/run/user/" + Quickshell.env("UID"))
  readonly property string resolvedPath: runtimeDir + "/omarchy-live/resolved.json"

  property var spec: null
  property var status: null

  readonly property bool liveOn: status ? status.enabled === true : false
  readonly property bool liveAvailable: status ? status.available === true : false
  readonly property string themeName: status ? String(status.theme || "") : ""
  readonly property string quality: status ? String(status.quality || "off") : "off"

  readonly property string barTooltip: {
    if (!themeName) return "Live wallpaper"
    if (!liveOn) return "Live wallpaper — paused (" + themeName + ")"
    if (quality === "off") return "Live wallpaper — parked (" + themeName + ")"
    if (quality === "low") return "Live wallpaper — reduced on battery (" + themeName + ")"
    return "Live wallpaper — " + themeName
  }

  function num(section, key, fallback) {
    if (!spec) return fallback
    var s = spec[section]
    if (!s || typeof s !== "object") return fallback
    var v = s[key]
    return (v === undefined || v === null) ? fallback : Number(v)
  }

  function flag(section, key, fallback) {
    if (!spec) return fallback
    var s = spec[section]
    if (!s || typeof s !== "object") return fallback
    var v = s[key]
    return (v === undefined || v === null) ? fallback : v !== false
  }

  // One process per write. Queued rather than fired concurrently so two quick
  // slider releases cannot race each other into the same file.
  property var pending: []

  function tune(key, value) {
    root.pending = root.pending.concat([["omarchy-live", "tune", key, String(value)]])
    root.drain()
  }

  function run(args) {
    root.pending = root.pending.concat([args])
    root.drain()
  }

  function drain() {
    if (writer.running || root.pending.length === 0) return
    var next = root.pending[0]
    root.pending = root.pending.slice(1)
    writer.command = next
    writer.running = true
  }

  Process {
    id: writer
    onExited: {
      root.refreshStatus()
      // Re-read rather than waiting for the watcher: the service rewrites the
      // resolved spec asynchronously after the reload, and a write that
      // replaced the file would have taken the watch with it.
      resolvedRefresh.restart()
      root.drain()
    }
  }

  Timer {
    id: resolvedRefresh
    interval: 250
    repeat: false
    onTriggered: resolvedFile.reload()
  }

  Process {
    id: statusProc
    // The status response is a small JSON object, but it arrives over an IPC
    // socket from a process that could be anything, and StdioCollector will
    // buffer whatever it is handed. `head -c` bounds it at the source so a
    // wedged or hostile responder cannot grow the bar's memory.
    command: ["sh", "-c", "omarchy-shell livewallpaper status | head -c 65536"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var parsed = JSON.parse(String(text || ""))
          root.status = (parsed && typeof parsed === "object") ? parsed : null
        } catch (e) {
          root.status = null
        }
      }
    }
  }

  function refreshStatus() {
    if (!statusProc.running) statusProc.running = true
  }

  Component.onCompleted: root.refreshStatus()

  // The service rewrites this whenever any layer changes, so watching it keeps
  // the sliders honest without polling.
  GuardedFile {
    id: resolvedFile
    path: root.resolvedPath
    onLoaded: function(text) {
      try {
        var parsed = JSON.parse(String(text || ""))
        root.spec = (parsed && typeof parsed === "object") ? parsed : null
      } catch (e) {
        root.spec = null
      }
      root.refreshStatus()
    }
    onLoadFailed: root.spec = null
  }

  // Status has no file to watch, and a theme switch changes it without
  // touching the spec, so it gets a slow poll while the panel is open.
  Timer {
    interval: 2000
    repeat: true
    running: root.opened
    onTriggered: {
      root.refreshStatus()
      resolvedFile.reload()
    }
  }

  implicitWidth: iconButton.implicitWidth
  implicitHeight: iconButton.implicitHeight

  BarIconButton {
    id: iconButton
    anchors.fill: parent
    bar: root.bar
    text: "\u{F1104}"
    active: root.opened || (root.liveOn && root.quality !== "off")
    tooltipText: root.barTooltip

    onPressed: function (b) {
      // Middle click is the quick pause, so the effect can be dropped without
      // opening anything — the same gesture the battery notification offers.
      if (b === Qt.MiddleButton) root.run(["omarchy-live", "toggle"])
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: iconButton
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onDeleteRequested: root.close()
    }

    Column {
      id: column
      width: parent.width
      spacing: Style.space(10)

      PanelSectionHeader {
        width: parent.width
        text: root.themeName ? root.themeName : "Live wallpaper"
      }

      Row {
        width: parent.width
        spacing: Style.space(10)

        Text {
          width: parent.width - toggle.width - Style.space(10)
          anchors.verticalCenter: parent.verticalCenter
          text: root.liveOn ? (root.quality === "low" ? "On — reduced on battery"
                                                      : (root.quality === "off" ? "On — parked" : "On"))
                            : "Paused"
          color: Color.popups.text
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        ToggleSwitch {
          id: toggle
          anchors.verticalCenter: parent.verticalCenter
          checked: root.liveOn
          onToggled: root.run(["omarchy-live", "toggle"])
        }
      }

      PanelSeparator { width: parent.width }

      PanelSectionHeader {
        width: parent.width
        text: "Motion"
      }

      LiveSlider {
        width: parent.width
        bar: root.bar
        label: "Loop length"
        suffix: "s"
        integer: true
        minimum: 20
        maximum: 120
        step: 2
        value: root.num("motion", "period", 60)
        onCommit: function (v) { root.tune("motion.period", v) }
      }

      LiveSlider {
        width: parent.width
        bar: root.bar
        label: "Zoom"
        minimum: 0
        maximum: 0.16
        step: 0.005
        decimals: 3
        value: root.num("motion", "zoom", 0.05)
        onCommit: function (v) { root.tune("motion.zoom", v) }
      }

      PanelSeparator { width: parent.width }

      PanelSectionHeader {
        width: parent.width
        text: "Print"
      }

      LiveSlider {
        width: parent.width
        bar: root.bar
        label: "Halftone"
        minimum: 0
        maximum: 0.7
        step: 0.02
        decimals: 2
        value: root.num("print", "halftone", 0)
        onCommit: function (v) { root.tune("print.halftone", v) }
      }

      LiveSlider {
        width: parent.width
        bar: root.bar
        label: "Grain"
        minimum: 0
        maximum: 0.09
        step: 0.002
        decimals: 3
        value: root.num("print", "grain", 0.022)
        onCommit: function (v) { root.tune("print.grain", v) }
      }

      LiveSlider {
        width: parent.width
        bar: root.bar
        label: "Vignette"
        minimum: 0
        maximum: 0.7
        step: 0.02
        decimals: 2
        value: root.num("print", "vignette", 0.30)
        onCommit: function (v) { root.tune("print.vignette", v) }
      }

      LiveSlider {
        width: parent.width
        bar: root.bar
        label: "Bloom"
        minimum: 0
        maximum: 0.35
        step: 0.01
        decimals: 2
        value: root.num("print", "bloom", 0.08)
        onCommit: function (v) { root.tune("print.bloom", v) }
      }

      PanelSeparator { width: parent.width }

      PanelSectionHeader {
        width: parent.width
        text: "Particles"
      }

      LiveSlider {
        width: parent.width
        bar: root.bar
        label: "Motes"
        integer: true
        minimum: 0
        maximum: 60
        step: 2
        value: root.num("motes", "rate", 14)
        onCommit: function (v) { root.tune("motes.rate", v) }
      }

      LiveSlider {
        width: parent.width
        bar: root.bar
        label: "Glints"
        integer: true
        minimum: 0
        maximum: 8
        step: 1
        value: root.num("glints", "count", 2)
        onCommit: function (v) { root.tune("glints.count", v) }
      }

      PanelSeparator { width: parent.width }

      Row {
        width: parent.width
        spacing: Style.space(10)

        Text {
          width: parent.width - batteryToggle.width - Style.space(10)
          anchors.verticalCenter: parent.verticalCenter
          text: "Notify on battery"
          color: Color.popups.text
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        ToggleSwitch {
          id: batteryToggle
          anchors.verticalCenter: parent.verticalCenter
          checked: root.flag("power", "notifyOnBattery", true)
          onToggled: root.tune("power.notifyOnBattery", batteryToggle.checked ? "false" : "true")
        }
      }

      // PanelActionButton is icon-only; a labelled full-width action is Button.
      Button {
        width: parent.width
        text: "Reset to theme default"
        bordered: true
        onClicked: root.run(["omarchy-live", "reset"])
      }
    }
  }
}
