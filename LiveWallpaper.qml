import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import Quickshell.Services.UPower
import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import qs.Commons
import qs.Ui
import "SpecBounds.js" as SpecBounds

// Desktop background layer with a live treatment on top.
//
// This replaces omarchy.background rather than stacking on it, so everything
// the stock plugin owns still has to work exactly as before: the `background`
// IPC target that omarchy-theme-bg-set and omarchy-theme-set call into, the
// masked wipe between wallpapers, and the double-click selectors. All of that
// is preserved verbatim below; the live scene is layered over the settled
// wallpaper and steps aside for the duration of a transition, so theme
// switching still gets the stock wipe instead of a crossfade between two
// animating scenes.
Item {
  id: root

  readonly property string home: Quickshell.env("HOME")
  readonly property string stateHome: home + "/.local/state"
  readonly property string currentBackgroundLink: stateHome + "/omarchy/current/background"
  readonly property string currentThemePath: stateHome + "/omarchy/current/theme"
  readonly property string themeNamePath: stateHome + "/omarchy/current/theme.name"
  // Injected by the shell when this service is mounted (shell.qml:307).
  property var shell: null
  property var pluginRegistry: null

  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || ("/run/user/" + Quickshell.env("UID"))
  readonly property string resolvedSpecPath: runtimeDir + "/omarchy-live/resolved.json"

  property string currentBackground: ""
  property string displayedBackground: ""
  property string incomingBackground: ""
  property string oldBackground: ""
  property bool finishingTransition: false
  property int backgroundVersion: 0
  property int revealStartedVersion: -1
  property int pendingThemeVersion: -1
  property string pendingColorsRaw: ""
  property string pendingShellRaw: ""
  property real revealProgress: 1

  function imageUrl(path) {
    return Util.fileUrl(path)
  }

  // The lock plugin the user is actually running. Stock first; failing that,
  // any mounted service whose id ends in ".lock" — a fork carries a different
  // id, and hardcoding "omarchy.lock" would quietly miss it.
  function resolveLockService() {
    if (!shell || typeof shell.serviceFor !== "function") return null

    var stock = shell.serviceFor("omarchy.lock")
    if (stock && "locked" in stock) return stock

    var installed = pluginRegistry && pluginRegistry.installedPlugins
      ? pluginRegistry.installedPlugins : null
    if (!installed) return null

    for (var id in installed) {
      if (String(id).slice(-5) !== ".lock") continue
      var svc = shell.serviceFor(id)
      if (svc && "locked" in svc) return svc
    }
    return null
  }

  property var lockService: null
  readonly property bool observedLocked: lockService && ("locked" in lockService)
    ? lockService.locked === true
    : false

  // Services mount in an unspecified order, so the lookup is retried until it
  // resolves rather than run once at startup and given up on.
  Timer {
    id: lockProbe
    interval: 1500
    repeat: true
    running: root.lockService === null
    triggeredOnStart: true
    onTriggered: root.lockService = root.resolveLockService()
  }

  function refreshBackground() {
    if (!readlinkProc.running) readlinkProc.running = true
  }

  function setBackground(path, instant) {
    transitionBackground("", path, path, instant, false)
  }

  function transitionBackground(fromPath, path, finalPath, instant, force) {
    path = String(path || "").trim()
    finalPath = String(finalPath || path).trim()
    fromPath = String(fromPath || "").trim()
    if (!path || (!force && finalPath === currentBackground)) return
    currentBackground = finalPath
    backgroundVersion += 1
    revealStartedVersion = -1

    revealAnimation.stop()
    finishingTransition = false

    if (instant || !displayedBackground) {
      oldBackground = ""
      incomingBackground = ""
      displayedBackground = path
      revealProgress = 1
      return
    }

    oldBackground = fromPath || displayedBackground
    incomingBackground = path
    revealProgress = 0
  }

  function setPendingTheme(colorsB64, shellB64) {
    pendingColorsRaw = Util.decodeBase64(colorsB64)
    pendingShellRaw = Util.decodeBase64(shellB64)
    pendingThemeVersion = backgroundVersion
    pendingThemeFallbackTimer.restart()
  }

  function applyPendingTheme() {
    // Background polling can advance backgroundVersion while a theme switch is
    // pending; the latest theme payload should still apply.
    if (pendingThemeVersion < 0) return
    pendingThemeFallbackTimer.stop()
    Color.loadColors(pendingColorsRaw)
    // Color.loadShell also refreshes Style so the type scale flips with the
    // background reveal instead of waiting for a separate reload path.
    Color.loadShell(pendingShellRaw)
    Style.scheduleRefresh()
    pendingThemeVersion = -1
    pendingColorsRaw = ""
    pendingShellRaw = ""
    // The theme directory has been swapped by now, so the live spec that came
    // with it is on disk and ready to read.
    liveSpec.reloadSoon()
  }

  function transitionBackgroundWithTheme(fromPath, path, finalPath, colorsB64, shellB64) {
    transitionBackground(fromPath, path, finalPath, false, true)
    setPendingTheme(colorsB64, shellB64)
    if (!incomingBackground || revealProgress >= 1) applyPendingTheme()
  }

  function startReveal(panel) {
    if (!incomingBackground) return
    panel.maskReady = true
    if (revealStartedVersion === backgroundVersion) return
    revealStartedVersion = backgroundVersion
    applyPendingTheme()
    revealAnimation.restart()
  }

  function openSelector() {
    if (!bgSwitchProc.running) bgSwitchProc.running = true
  }

  function openThemeSwitcher() {
    if (!themeSwitchProc.running) themeSwitchProc.running = true
  }

  Process {
    id: bgSwitchProc
    command: ["bash", "-c", "background=$(omarchy-theme-bg-switcher); [[ -n $background ]] && omarchy-theme-bg-set \"$background\""]
    onExited: root.refreshBackground()
  }

  Process {
    id: themeSwitchProc
    command: ["bash", "-c", "theme=$(omarchy-theme-switcher); [[ -n $theme ]] && omarchy-theme-set \"$theme\" >/dev/null 2>&1 &"]
    onExited: root.refreshBackground()
  }

  Process {
    id: readlinkProc
    // Bounded like every other read in here: a path, not a stream. The link is
    // passed as an argument rather than interpolated into the script.
    command: ["timeout", "-s", "KILL", "5",
              "sh", "-c", "readlink -f -- \"$1\" | head -c 4096", "sh", root.currentBackgroundLink]
    stdout: StdioCollector {
      onStreamFinished: root.setBackground(String(text || "").trim(), false)
    }
  }

  // Only register once nothing else owns the `background` target.
  //
  // Enabling this plugin while the shell is running does not restart it: the
  // registry fires pluginsChanged, and shell.qml's _syncServices() mounts every
  // newly-enabled service *before* it destroys the disabled ones. So this
  // handler would register while stock omarchy.background still holds the
  // target, get refused ("another handler is registered for target
  // background"), and then stock would unregister on its way out — leaving the
  // target owned by nobody. omarchy-theme-set still applies colours through its
  // own path, so the visible symptom is a theme that switches without its
  // wallpaper, and it lasts until the next `omarchy restart shell`.
  //
  // Waiting for the outgoing service to actually be gone is what makes
  // `omarchy plugin add --enable` a single step on someone else's machine.
  readonly property bool stockBackgroundMounted:
    !!(shell && typeof shell.serviceFor === "function"
       && shell.serviceFor("omarchy.background"))
  property bool backgroundHandlerLive: false

  Timer {
    // serviceFor() can report the old service gone a moment before its handler
    // has actually unregistered, so registration is re-asserted a few times
    // rather than attempted once. Toggling `enabled` is what re-runs it.
    id: backgroundClaim
    interval: 400
    repeat: true
    running: !root.stockBackgroundMounted && !root.backgroundHandlerLive
    // Deliberately not triggeredOnStart. serviceFor() reports the outgoing
    // service gone a beat before its handler has finished unregistering, so an
    // immediate first attempt is the one attempt most likely to fail — and each
    // failure is a warning in the user's journal. Waiting one tick makes the
    // common case succeed silently on the first try.
    property int attempts: 0
    onTriggered: {
      backgroundHandler.enabled = false
      backgroundHandler.enabled = true
      attempts += 1
      // ~3s of re-assertion. Re-registering when we already own the target is a
      // no-op, so the only cost of an extra attempt is nothing at all; the cap
      // exists so a genuinely contested target does not spin for the session.
      if (attempts >= 8) {
        root.backgroundHandlerLive = true
        // Whatever happened while the target was contested, the link on disk is
        // the truth — re-read it so the wallpaper is right the moment we own it.
        root.refreshBackground()
      }
    }
  }

  onStockBackgroundMountedChanged: if (stockBackgroundMounted) {
    // Something re-mounted stock; stand down and re-claim when it leaves again.
    root.backgroundHandlerLive = false
    backgroundClaim.attempts = 0
  }

  IpcHandler {
    id: backgroundHandler
    target: "background"
    enabled: false

    function refresh(): void {
      root.refreshBackground()
    }

    function set(path: string): void {
      root.setBackground(path, false)
    }

    function setInstant(path: string): void {
      root.setBackground(path, true)
    }

    function transition(fromPath: string, path: string): void {
      root.transitionBackground(fromPath, path, path, false, false)
    }

    function themeTransition(fromPath: string, path: string, finalPath: string, colorsB64: string, shellB64: string): void {
      root.transitionBackgroundWithTheme(fromPath, path, finalPath, colorsB64, shellB64)
    }
  }

  // Live wallpaper control surface. Separate target from `background` so the
  // stock contract above stays byte-for-byte what Omarchy's scripts expect.
  IpcHandler {
    target: "livewallpaper"

    function enable(): void {
      liveSpec.userEnabled = true
    }

    function disable(): void {
      liveSpec.userEnabled = false
    }

    function toggle(): void {
      liveSpec.userEnabled = !liveSpec.userEnabled
    }

    // Called by the lock surface so the desktop scene parks while the screen
    // is covered instead of animating a wallpaper nobody can see.
    function setLocked(locked: bool): void {
      liveSpec.ipcLocked = locked
    }

    function reload(): void {
      liveSpec.reloadSoon()
    }

    function status(): string {
      return JSON.stringify({
        // Three separate things, named separately. `available` used to be
        // computed here without userEnabled while liveSpec.available computed it
        // with — one word meaning two things, which is what let the menu tick
        // disagree with the screen.
        //
        //   specEnabled  the persistent per-theme switch (spec.enabled)
        //   userEnabled  the session switch (omarchy-live on/off)
        //   available    both of the above, what the renderer actually gates on
        specEnabled: liveSpec.spec !== null && liveSpec.spec.enabled !== false,
        userEnabled: liveSpec.userEnabled,
        available: liveSpec.available,
        powerMode: liveSpec.powerMode,
        // Retained so an older omarchy-live still on PATH keeps working.
        enabled: liveSpec.userEnabled,
        quality: liveSpec.quality,
        theme: liveSpec.themeName,
        layers: liveSpec.layers,
        specPath: liveSpec.specPath,
        userThemePath: liveSpec.userThemePath,
        locked: liveSpec.locked,
        lockedVia: liveSpec.ipcLocked ? "ipc" : (root.observedLocked ? "observed" : "none"),
        lockService: root.lockService ? "resolved" : "none",
        fullscreen: liveSpec.anyFullscreen,
        onBattery: liveSpec.onBattery,
        background: root.displayedBackground,
        settled: liveSpec.settled
      })
    }
  }

  Timer {
    id: pendingThemeFallbackTimer
    interval: 300
    repeat: false
    onTriggered: root.applyPendingTheme()
  }

  NumberAnimation {
    id: revealAnimation
    target: root
    property: "revealProgress"
    from: 0
    to: 1
    duration: 420
    easing.type: Easing.InOutCubic
    onFinished: {
      if (root.incomingBackground) {
        root.displayedBackground = root.currentBackground || root.incomingBackground
        root.finishingTransition = true
      }
      root.revealProgress = 1
    }
  }

  Component.onCompleted: {
    refreshBackground()
    // Seed from UPower's current reading. Not a transition, so batterySeen stays
    // false and a shell restart while unplugged does not nag.
    liveSpec.onBattery = UPower.onBattery
  }

  // ---------------------------------------------------------------------
  // Live spec + power state
  // ---------------------------------------------------------------------
  QtObject {
    id: liveSpec

    property bool userEnabled: true

    // Lock state arrives two ways, and either one going true is reason enough
    // to park. The companion lock plugin pushes it over IPC; failing that, the
    // mounted lock service is read directly, so installing this plugin on its
    // own still stops the scene animating behind a lock surface nobody can
    // see. OR, not precedence — the two must not be able to cancel each other.
    property bool ipcLocked: false
    readonly property bool locked: ipcLocked || root.observedLocked

    property string themeName: ""
    property var spec: null

    // Four layers, merged shallow per section, later wins. The built-in
    // baseline is what makes every theme live on a fresh install: the renderer
    // already falls back per key, and "auto" colours resolve against whatever
    // palette is loaded, so a theme that ships nothing still animates in its
    // own colours. Halftone stays off in the baseline on purpose — the ben-day
    // comic pass is a Spider-Verse conceit and looks wrong on a photographic
    // or minimal theme, so only a theme that asks for it gets it.
    readonly property var baseSpec: ({
      "version": 1,
      "motion": { "period": 36, "speed": 1.0, "zoom": 0.05, "driftX": 0.014, "driftY": 0.009 },
      "print":  { "halftone": 0.0, "dotScale": 150, "grain": 0.022, "vignette": 0.30, "bloom": 0.08 },
      "pulse":  { "everyMin": 24, "everyMax": 55, "attack": 200, "hold": 90, "release": 800, "aberration": 0.004 },
      "glints": { "count": 2, "everyMin": 12, "everyMax": 30, "length": 0.45, "thickness": 1.6, "speed": 1100 },
      "motes":  { "rate": 14, "life": 14000, "size": 2.6, "drift": 16, "fall": 18 },
      "colors": { "accent": "auto", "secondary": "auto" },
      "lock":   { "pulse": 0.5 },
      "power":  { "onBattery": "off", "notifyOnBattery": true },
      "video":  null
    })

    property var userGlobal: null
    property var themeLayer: null
    property var userTheme: null

    readonly property string specPath: root.currentThemePath + "/live/live.json"
    readonly property string userGlobalPath: root.home + "/.config/omarchy/live.json"
    readonly property string userThemePath: themeName === "" ? "" : root.home + "/.config/omarchy/live/" + themeName + ".json"

    // Names the layers that actually contributed, so `omarchy-live status` can
    // explain why the current look is what it is.
    readonly property var layers: {
      var names = ["builtin"]
      if (userGlobal) names.push("user-global")
      if (themeLayer) names.push("theme")
      if (userTheme) names.push("user-theme")
      return names
    }

    // Hyprland reports fullscreen per workspace. A wallpaper that nobody can
    // see should not be burning a GPU pass, and this is the single largest
    // power win the plugin has.
    property bool anyFullscreen: false
    property bool onBattery: false
    property bool batterySeen: false
    property bool batteryNoticeSent: false

    readonly property bool settled: root.incomingBackground === "" && root.revealProgress >= 1
    // `spec` is never null now that the baseline exists, so the real gate is
    // the explicit opt-out any layer can set, plus the session switch.
    readonly property bool available: spec !== null && userEnabled && spec.enabled !== false

    // What unplugging should do: "off" parks the scene, "low" drops to parallax
    // only, "ignore" leaves it alone. `batterySaver: true` from an older spec
    // still means "low", so specs written against the previous key keep working.
    readonly property string powerMode: {
      var power = spec ? spec.power : null
      if (!power) return "off"
      if (power.onBattery === "off" || power.onBattery === "low" || power.onBattery === "ignore")
        return power.onBattery
      if (power.batterySaver === true) return "low"
      if (power.batterySaver === false) return "ignore"
      return "off"
    }

    // Battery is a *derived* gate, never a switch that gets flipped. That is
    // what makes plugging back in restore the treatment on its own: there is no
    // stored "paused" state to get stuck in, so the moment UPower says the mains
    // are back, quality returns to what it was.
    readonly property string quality: {
      if (!available) return "off"
      if (locked || anyFullscreen) return "off"
      if (onBattery && powerMode === "off") return "off"
      if (onBattery && powerMode === "low") return "low"
      return "high"
    }

    function reloadSoon() {
      reloadTimer.restart()
    }

    // A malformed layer degrades to the layer below rather than to a black
    // wallpaper, so a typo in an override is never destructive.
    function parseLayer(raw, path) {
      try {
        var parsed = JSON.parse(String(raw || ""))
        return (parsed && typeof parsed === "object") ? parsed : null
      } catch (e) {
        console.warn("livewallpaper: ignoring malformed " + path + " — " + e)
        return null
      }
    }

    // Shallow per section: a layer naming "motion" owns that whole section,
    // and sections it omits fall through to the layer below. Deep-merging
    // individual keys would make an override impossible to reason about.
    function merge() {
      var out = {}
      var sources = [baseSpec, userGlobal, themeLayer, userTheme]
      for (var i = 0; i < sources.length; i++) {
        var src = sources[i]
        if (!src || typeof src !== "object") continue
        for (var key in src) out[key] = src[key]
      }
      // Clamped once here so everything downstream of the merge sees the same
      // bounded values: the renderer, the `status` IPC that reports what is in
      // effect, the sliders in the bar, and the resolved spec published into the
      // runtime directory for the lock surface to pick up.
      spec = SpecBounds.sanitize(out)
    }

    onUserGlobalChanged: merge()
    onThemeLayerChanged: merge()
    onUserThemeChanged: merge()
    Component.onCompleted: merge()
  }

  Timer {
    id: reloadTimer
    interval: 120
    repeat: false
    // A theme swap replaces the whole current/theme directory, so the watcher
    // on the old inode is gone. Re-pointing the FileView is what re-arms it.
    onTriggered: {
      specFile.rearm()
      // The override directory is never swapped, so its watcher survives and
      // its path re-points itself once the theme name below updates. Assigning
      // that path here would overwrite the binding and freeze it on the old
      // theme, which is exactly the bug this comment exists to prevent.
      //
      // Clear before reloading: a *deleted* file does not raise onLoadFailed,
      // so `omarchy-live reset` would drop the layer from the list while its
      // values stayed merged in. Nulling first makes absence mean absence.
      liveSpec.userTheme = null
      liveSpec.userGlobal = null
      userThemeFile.reload()
      userGlobalFile.reload()
      themeNameFile.reload()
    }
  }

  GuardedFile {
    id: specFile
    path: liveSpec.specPath
    onLoaded: function(text) { liveSpec.themeLayer = liveSpec.parseLayer(text, specFile.path) }
    onLoadFailed: liveSpec.themeLayer = null
  }

  GuardedFile {
    id: userGlobalFile
    path: liveSpec.userGlobalPath
    onLoaded: function(text) { liveSpec.userGlobal = liveSpec.parseLayer(text, userGlobalFile.path) }
    onLoadFailed: liveSpec.userGlobal = null
  }

  // The per-theme override lives outside the theme directory on purpose:
  // themes are often git checkouts or read-only stock themes, and tuning one
  // must not dirty a repo or need write access under /usr/share.
  GuardedFile {
    id: userThemeFile
    path: liveSpec.userThemePath
    onLoaded: function(text) { liveSpec.userTheme = liveSpec.parseLayer(text, userThemeFile.path) }
    onLoadFailed: liveSpec.userTheme = null
  }

  // The lock screen needs the same answer this plugin computed, not its own
  // guess from one layer. Publishing the resolved spec keeps a single resolver;
  // the runtime dir means it is rebuilt each boot and never goes stale.
  FileView {
    id: resolvedFile
    path: root.resolvedSpecPath
    printErrors: false
    // Write-only. Nothing here ever reads this file, but FileView would load it
    // the moment it is pointed at the path, so a file already sitting at that
    // path would be pulled into the shell for no reason at all.
    preload: false
    // Atomic writes replace the file, so every publish would hand out a new
    // inode and silently kill every watcher pointed at this path — the bar
    // panel and the lock screen both stop updating after the first change.
    // Writing in place keeps their watches alive.
    atomicWrites: false
  }

  // setText() does not create parent directories, and the runtime dir is empty
  // on a fresh boot. Without this the publish fails silently and takes the lock
  // screen's live treatment with it.
  Process {
    id: resolvedDir
    running: true
    command: ["mkdir", "-p", root.runtimeDir + "/omarchy-live"]
    onExited: if (liveSpec.spec) resolvedFile.setText(JSON.stringify(liveSpec.spec))
  }

  Connections {
    target: liveSpec
    function onSpecChanged() {
      if (!liveSpec.spec) return
      resolvedFile.setText(JSON.stringify(liveSpec.spec))
    }
  }

  GuardedFile {
    id: themeNameFile
    path: root.themeNamePath
    // A theme name, not a document.
    maxBytes: 4096
    onLoaded: function(text) { liveSpec.themeName = String(text || "").trim() }
  }

  // Fullscreen tracking -------------------------------------------------
  function recomputeFullscreen() {
    var workspaces = (Hyprland.workspaces && Hyprland.workspaces.values) ? Hyprland.workspaces.values : []
    for (var i = 0; i < workspaces.length; i++) {
      var ws = workspaces[i]
      var ipc = ws ? ws.lastIpcObject : null
      // Only workspaces that are actually on a monitor can be covering a
      // wallpaper; a fullscreen window parked on a hidden workspace is not.
      if (ipc && ipc.hasfullscreen && ws.monitor) {
        liveSpec.anyFullscreen = true
        return
      }
    }
    liveSpec.anyFullscreen = false
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var name = String(event && event.name ? event.name : "")
      if (name === "fullscreen" || name === "openwindow" || name === "closewindow"
        || name === "workspace" || name === "focusedmon" || name === "movewindow") {
        Hyprland.refreshWorkspaces()
        fullscreenSettle.restart()
      }
    }
  }

  Timer {
    // The workspace model reuses its objects, so refreshWorkspaces() updates
    // lastIpcObject in place without the model emitting a change. Recomputing
    // shortly after the refresh lands is what makes resume feel immediate
    // instead of waiting for the slow backstop below.
    id: fullscreenSettle
    interval: 150
    repeat: false
    onTriggered: root.recomputeFullscreen()
  }

  Connections {
    target: Hyprland.workspaces
    function onValuesChanged() { root.recomputeFullscreen() }
  }

  Timer {
    // Backstop. Hyprland's fullscreen event does not fire for every path into
    // and out of fullscreen (client-side fullscreen in particular), so a slow
    // poll keeps the gate honest without a per-frame cost.
    interval: 5000
    running: liveSpec.available
    repeat: true
    onTriggered: {
      Hyprland.refreshWorkspaces()
      // Recomputed here too, not only from the model signal, so the gate still
      // works if the model reuses objects and never emits a values change.
      root.recomputeFullscreen()
    }
  }

  // Battery -------------------------------------------------------------
  //
  // UPower, not sysfs. This used to read /sys/class/power_supply/AC/online
  // directly, which was wrong twice: that node is called ADP1, ACAD or AC0 on
  // plenty of laptops, so on those machines the read simply failed and the
  // plugin believed it was on mains forever; and sysfs does not deliver the
  // inotify events the file watcher was waiting on, so even where the path was
  // right the value never changed after startup. UPower is event-driven, is
  // correct on every machine, reports false on a desktop with no battery, and
  // is already what stock Omarchy's battery service uses.
  Connections {
    target: UPower
    function onOnBatteryChanged() {
      liveSpec.batterySeen = true
      liveSpec.onBattery = UPower.onBattery
    }
  }


  // The scene parks itself on battery now, so this says what happened rather
  // than asking the user to do it. Once per discharge, re-armed when the mains
  // come back. There is no click action any more: offering to pause a thing
  // that has already paused only reads as a second, contradictory switch.
  Connections {
    target: liveSpec

    function onOnBatteryChanged() {
      if (!liveSpec.onBattery) {
        liveSpec.batteryNoticeSent = false   // re-arm for the next discharge
        return
      }
      // The reading at startup is a state, not a transition, so a shell restart
      // while already unplugged does not nag.
      if (!liveSpec.batterySeen) return
      if (liveSpec.batteryNoticeSent) return
      // Nothing was running, so nothing was given up.
      if (!liveSpec.available) return
      // The mode that changes nothing has nothing to announce.
      if (liveSpec.powerMode === "ignore") return
      var power = liveSpec.spec ? liveSpec.spec.power : null
      if (power && power.notifyOnBattery === false) return

      liveSpec.batteryNoticeSent = true
      batteryNotice.command = [
        "omarchy-notification-send",
        "--app-name", "omarchy-live",
        "-u", "normal",
        "-g", "󰂃",
        "On battery",
        liveSpec.powerMode === "off"
          ? "Live wallpaper paused to save power. It resumes when you plug back in."
          : "Live wallpaper reduced to save power. Full effects resume when you plug back in."
      ]
      batteryNotice.running = true
    }
  }

  Process { id: batteryNotice }

  // First-mount setup ---------------------------------------------------
  //
  // `omarchy plugin add <url> --enable` clones, enables and stops — it never
  // runs this plugin's install.sh, and the Omarchy menu does not read a
  // plugin's own menu.jsonc. So on a machine that installed this the documented
  // way, neither the `omarchy-live` command nor the Style > Live Wallpaper rows
  // exist, and the plugin looks broken through no fault of the person who
  // installed it. bin/omarchy-live-setup closes both gaps; it is idempotent and
  // prints nothing at all unless it actually changed something.
  Process {
    id: firstRunSetup
    running: true
    command: ["bash", Qt.resolvedUrl("bin/omarchy-live-setup").toString().replace("file://", "")]
    stdout: StdioCollector {
      onStreamFinished: {
        var did = String(text || "").trim()
        if (!did) return
        console.log("livewallpaper: first-run setup —", did)
        setupNotice.command = [
          "omarchy-notification-send",
          "--app-name", "omarchy-live",
          "-u", "low",
          "Live Wallpaper ready",
          did
        ]
        setupNotice.running = true
      }
    }
  }

  Process { id: setupNotice }

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: panel
      required property var modelData

      screen: modelData
      visible: !remapGuard.remapping
      anchors { top: true; bottom: true; left: true; right: true }

      ScreenMoveRemap {
        id: remapGuard
        window: panel
      }
      color: "transparent"
      // Keep render updates enabled. The background layer has been observed to
      // lose its committed buffer while parked with updatesEnabled=false,
      // leaving a black desktop until omarchy-shell is restarted. The wallpaper
      // itself is static, so this favors correctness over a small render-loop
      // optimization.
      updatesEnabled: true

      property bool maskReady: false

      function maybeStartReveal() {
        if (!root.incomingBackground || root.revealProgress !== 0 || maskReady) return
        if (incomingFrame.status !== Image.Ready) return
        Qt.callLater(function() {
          if (!root.incomingBackground || root.revealProgress !== 0 || maskReady) return
          if (incomingFrame.status !== Image.Ready) return
          root.startReveal(panel)
        })
      }

      WlrLayershell.namespace: "omarchy-background"
      WlrLayershell.layer: WlrLayer.Background
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Ignore

      Image {
        id: base
        anchors.fill: parent
        source: root.imageUrl(root.displayedBackground)
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
        // Hidden once the live scene has taken over, to avoid paying for a
        // full-screen opaque draw that nothing can see.
        visible: !liveLoader.covering
        onStatusChanged: {
          if (status === Image.Ready && root.finishingTransition) {
            root.incomingBackground = ""
            root.oldBackground = ""
            root.finishingTransition = false
          }
        }
      }

      // The live treatment. Sits above the still plate and below the
      // transition layers, and fades out for the duration of a wipe so the
      // stock reveal reads cleanly.
      Loader {
        id: liveLoader
        anchors.fill: parent
        active: liveSpec.available && root.displayedBackground !== ""
        asynchronous: true

        readonly property bool covering: status === Loader.Ready && item && item.opacity >= 0.999

        sourceComponent: LiveScene {
          imagePath: root.displayedBackground
          spec: liveSpec.spec
          quality: liveSpec.quality
          opacity: liveSpec.settled ? 1 : 0
          Behavior on opacity { NumberAnimation { duration: 260; easing.type: Easing.InOutQuad } }
        }
      }

      Image {
        id: oldFrame
        anchors.fill: parent
        source: root.imageUrl(root.oldBackground)
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: false
        smooth: true
        mipmap: true
        visible: root.oldBackground !== "" && root.revealProgress < 1
        onStatusChanged: panel.maybeStartReveal()
      }

      Item {
        id: incomingLayer
        anchors.fill: parent
        visible: root.incomingBackground !== "" && incomingFrame.status === Image.Ready && (root.revealProgress >= 1 || panel.maskReady)
        layer.enabled: root.incomingBackground !== "" && root.revealProgress < 1
        layer.smooth: true
        layer.effect: MultiEffect {
          maskEnabled: true
          maskSource: revealMask
          maskThresholdMin: 0.5
          maskSpreadAtMin: 0.02
        }

        Image {
          id: incomingFrame
          anchors.fill: parent
          source: root.imageUrl(root.incomingBackground)
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          cache: false
          smooth: true
          mipmap: true
          onStatusChanged: panel.maybeStartReveal()
        }
      }

      Item {
        id: revealMask
        anchors.fill: parent
        visible: false
        layer.enabled: true

        readonly property real slant: -0.18
        readonly property real centerTop: width / 2 - slant * height / 2
        readonly property real centerBottom: width / 2 + slant * height / 2
        readonly property real reach: width / 2 + Math.abs(slant) * height / 2 + 4
        readonly property real spread: reach * root.revealProgress

        Shape {
          anchors.fill: parent
          antialiasing: true
          preferredRendererType: Shape.CurveRenderer
          ShapePath {
            fillColor: "white"
            strokeColor: "transparent"
            startX: revealMask.centerTop - revealMask.spread; startY: 0
            PathLine { x: revealMask.centerTop + revealMask.spread; y: 0 }
            PathLine { x: revealMask.centerBottom + revealMask.spread; y: revealMask.height }
            PathLine { x: revealMask.centerBottom - revealMask.spread; y: revealMask.height }
            PathLine { x: revealMask.centerTop - revealMask.spread; y: 0 }
          }
        }
      }

      Connections {
        target: root
        function onIncomingBackgroundChanged() {
          panel.maskReady = false
          panel.maybeStartReveal()
        }
      }

      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onDoubleClicked: function(mouse) {
          if (mouse.button === Qt.RightButton) root.openThemeSwitcher()
          else root.openSelector()
          mouse.accepted = true
        }
      }
    }
  }
}
