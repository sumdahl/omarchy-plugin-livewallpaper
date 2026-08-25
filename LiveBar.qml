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

  // The effective switch, not the session half. `available` is what the renderer
  // gates on; `enabled` is only the session switch and is kept for older
  // services, so reading it alone let this tooltip say "paused" over a running
  // wallpaper (and the reverse) — the same incoherence the menu tick had.
  readonly property bool liveOn: !status ? false
    : (status.available !== undefined ? status.available === true : status.enabled === true)
  readonly property bool liveAvailable: status ? status.available === true : false
  readonly property string themeName: status ? String(status.theme || "") : ""
  readonly property string quality: status ? String(status.quality || "off") : "off"

  readonly property string barTooltip: {
    if (updateAvailable) return "Live wallpaper " + updateVersion + " available — click to review"
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
    // Deadlined as well as bounded: this runs on every popup open, and an IPC
    // call that never answers would hold the reader and leave the popup showing
    // a stale reading with no way to refresh it.
    command: ["timeout", "-s", "KILL", "5",
              "sh", "-c", "omarchy-shell livewallpaper status | head -c 65536"]
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

  // Update checking -----------------------------------------------------
  //
  // Detects, never applies. The check transfers git refs and a tag object and
  // nothing else — no code from the remote is run here, and nothing is written
  // to the checkout. Applying is handed to Omarchy's own `omarchy plugin
  // update` in a terminal the user can see, which prints the full diff and asks
  // before touching anything. An updater that installed silently would be a
  // remote-code-execution channel into a process that lives for the whole
  // session, so the visible diff and the explicit yes are the point, not
  // friction to be optimised away.
  property bool updateAvailable: false
  property string updateVersion: ""

  function checkForUpdates() {
    if (!updateProc.running) updateProc.running = true
  }

  function runUpdate() {
    if (!root.bar) return
    root.bar.run("omarchy-launch-floating-terminal-with-presentation "
                 + "omarchy plugin update io.github.sumdahl.livewallpaper")
  }

  Process {
    id: updateProc
    command: [Qt.resolvedUrl("bin/omarchy-live-update-check").toString().replace("file://", "")]
    property string collected: ""
    stdout: StdioCollector { onStreamFinished: updateProc.collected = String(text || "").trim() }
    onExited: function(exitCode) {
      // 0 and only 0 means "a signed release newer than this one exists".
      // Exit 2 is a refusal the script has already explained on stderr; exit 1
      // is the quiet nothing-to-do case, including being offline.
      root.updateAvailable = exitCode === 0 && updateProc.collected.length > 0
      root.updateVersion = root.updateAvailable ? updateProc.collected : ""
      updateProc.collected = ""
    }
  }

  Timer {
    // Six hours, matching the stock system-update widget. Fires on start so a
    // fresh session learns immediately rather than after the first interval.
    interval: 21600000
    running: true
    repeat: true
    triggeredOnStart: true
    // Each instance runs its own timer, so this stays a direct call — going
    // through broadcast here would run the check once per screen per tick.
    onTriggered: root.checkForUpdates()
  }

  // A bar surface exists per monitor, so every screen instantiates this widget
  // and each one registers this target — only the first wins, and Quickshell
  // logs a warning for the rest. That is the same shape as the stock
  // system-update widget and is expected rather than a fault; `broadcast` is
  // what makes the winning instance relay to its peers, so a check refreshes
  // the badge on every screen instead of just one.
  IpcHandler {
    target: "livewallpaper-update"

    function check(): void { root.broadcast("checkForUpdates") }

    function available(): string {
      return root.updateAvailable ? root.updateVersion : ""
    }
  }

  implicitWidth: iconButton.implicitWidth
  implicitHeight: iconButton.implicitHeight

  BarIconButton {
    id: iconButton
    anchors.fill: parent
    bar: root.bar
    text: "\u{F0674}"
    active: root.opened || (root.liveOn && root.quality !== "off")
    tooltipText: root.barTooltip

    onPressed: function (b) {
      // Middle click is the quick pause, so the effect can be dropped without
      // opening anything — the same gesture the battery notification offers.
      if (b === Qt.MiddleButton) root.run(["omarchy-live", "toggle"])
      else root.toggle()
    }

    // A dot rather than a second bar item: the icon is already here, so an
    // update needs to be noticeable without taking more of the bar.
    Rectangle {
      visible: root.updateAvailable
      width: Style.space(6)
      height: width
      radius: width / 2
      color: Color.bar.active
      anchors.top: parent.top
      anchors.right: parent.right
      anchors.topMargin: Style.space(4)
      anchors.rightMargin: Style.space(4)
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

      // Only present when there is genuinely something to do — an always-there
      // "check for updates" row is clutter that trains people to ignore it.
      PanelSeparator {
        width: parent.width
        visible: root.updateAvailable
      }

      Column {
        width: parent.width
        spacing: Style.space(6)
        visible: root.updateAvailable

        Text {
          width: parent.width
          text: "Version " + root.updateVersion + " is available"
          color: Color.popups.text
          font.pixelSize: Style.font.body
          // The version comes from a git tag, so it is remote input, and this
          // is a Text the plugin owns. Pinned like every other one here.
          textFormat: Text.PlainText
          elide: Text.ElideRight
        }

        Button {
          width: parent.width
          // "Review", not "Update": the click opens a terminal showing the diff
          // and waits for a yes. Naming it Update would promise something this
          // button deliberately does not do.
          text: "Review and update"
          bordered: true
          onClicked: {
            root.close()
            root.runUpdate()
          }
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
        value: root.num("motion", "period", 36)
        onCommit: function (v) { root.tune("motion.period", v) }
      }

      LiveSlider {
        width: parent.width
        bar: root.bar
        // Composes with the loop length above rather than duplicating it: the
        // period is what the theme asked for, the speed is what you want on top
        // of it, so a preference for livelier motion survives a theme switch.
        label: "Speed"
        suffix: "x"
        minimum: 0.25
        maximum: 3.0
        step: 0.05
        value: root.num("motion", "speed", 1.0)
        onCommit: function (v) { root.tune("motion.speed", v) }
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
