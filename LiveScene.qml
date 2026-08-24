import QtQuick
import QtQuick.Particles
import QtMultimedia
import qs.Commons
import "SpecBounds.js" as SpecBounds

// The live wallpaper itself, independent of where it is mounted. The desktop
// background layer and the lock surface both instantiate this, which is what
// keeps the motion identical everywhere instead of two look-alike renderers
// drifting apart.
//
// Composition order matters: parallax still (or video) -> web glints -> motes
// -> the whole stack through one comic-print shader pass. Running the shader
// over the composite is what unifies the frame; running it only over the photo
// would leave the glints and motes looking pasted on.
Item {
  id: root

  // Wallpaper to animate. Ignored when the spec carries a video.
  property string imagePath: ""
  // Parsed live.json for the current theme, or null for stock behaviour.
  property var spec: null
  // "high" full effects | "low" parallax only | "off" a plain still.
  property string quality: "high"
  // Global multiplier. The lock surface runs quieter than the desktop.
  property real intensity: 1.0

  readonly property bool hasSpec: spec !== null && spec !== undefined
  readonly property bool animating: hasSpec && quality !== "off"
  readonly property bool fullEffects: hasSpec && quality === "high"
  readonly property string videoPath: hasSpec && spec.video ? String(spec.video) : ""

  // Every numeric this scene reads comes through here, which is what makes this
  // the place to bound them. The values are parsed out of writable local state
  // and go straight into item counts, emitter rates and animation durations, so
  // they are clamped to the ranges in SpecBounds.js on the way out rather than
  // trusted for being small on disk. The clamp is applied here as well as at the
  // merge because this scene renders whatever spec it is handed, including one
  // that arrives from somewhere other than this plugin's own merge.
  function cfg(section, key, fallback) {
    var v = fallback
    if (hasSpec) {
      var s = spec[section]
      if (s && typeof s === "object" && s[key] !== undefined && s[key] !== null) v = s[key]
    }
    return SpecBounds.clamp(section, key, v, fallback)
  }

  // "auto" resolves against the live theme palette, so a theme that never
  // names a colour still gets ink that matches the rest of the desktop.
  function themeColor(key, fallback) {
    var v = cfg("colors", key, "auto")
    if (typeof v === "string" && v !== "auto" && v.length > 0) return v
    return fallback
  }

  readonly property color inkAccent: themeColor("accent", Color.accent)
  readonly property color inkSecondary: themeColor("secondary", Qt.tint(Color.accent, Qt.rgba(0.24, 0.43, 0.91, 0.55)))

  // Motion --------------------------------------------------------------
  // A single 0..2pi phase drives every camera move. Every term below is an
  // integer harmonic of it, so the loop closes with matching position *and*
  // velocity and there is no visible seam at the wrap.
  readonly property real motionPeriodMs: Math.max(4000, Number(cfg("motion", "period", 48)) * 1000)
  readonly property real zoomAmp: Number(cfg("motion", "zoom", 0.06)) * intensity
  readonly property real driftXAmp: Number(cfg("motion", "driftX", 0.018)) * intensity
  readonly property real driftYAmp: Number(cfg("motion", "driftY", 0.012)) * intensity

  property real phase: 0

  // Overscan must cover peak zoom plus peak drift or the crop edge slides into
  // frame at the extremes of the loop.
  readonly property real overscan: 1.0 + zoomAmp + 2.0 * Math.max(driftXAmp, driftYAmp) + 0.01

  // Mote population, which is neither of the values that produce it. The
  // standing particle count is emission rate times lifetime, so a spec can put
  // both of those well inside their own ranges and still ask for tens of
  // thousands of live particles — Qt caps an ImageParticle at 16383 and warns
  // about it on every frame past that. Emission is throttled against the budget
  // below so the population stays bounded whatever the two factors say.
  //
  // Real specs never come near it: the built-in baseline stands at roughly 280
  // particles, so this only ever engages for a value that was not a look.
  readonly property int maxMotes: 4000
  readonly property real moteLifeMs: Number(cfg("motes", "life", 12000))
  readonly property real moteRate: {
    var wanted = Number(cfg("motes", "rate", 26)) * intensity
    // lifeSpanVariation adds 40%, so the longest-lived mote outlives `life`.
    var secondsPerMote = Math.max(0.001, moteLifeMs * 1.4 / 1000)
    return Math.min(wanted, maxMotes / secondsPerMote)
  }

  NumberAnimation on phase {
    running: root.animating
    loops: Animation.Infinite
    from: 0
    to: 2 * Math.PI
    duration: root.motionPeriodMs
  }

  // Spider-sense pulse ---------------------------------------------------
  property real pulse: 0

  Timer {
    id: pulseTimer
    running: root.fullEffects
    repeat: true
    // Re-rolled on every fire so the pulse never lands on a countable beat.
    interval: 1000 * (Number(root.cfg("pulse", "everyMin", 14))
      + Math.random() * Math.max(0, Number(root.cfg("pulse", "everyMax", 34)) - Number(root.cfg("pulse", "everyMin", 14))))
    onTriggered: {
      interval = 1000 * (Number(root.cfg("pulse", "everyMin", 14))
        + Math.random() * Math.max(0, Number(root.cfg("pulse", "everyMax", 34)) - Number(root.cfg("pulse", "everyMin", 14))))
      pulseAnim.restart()
    }
  }

  SequentialAnimation {
    id: pulseAnim
    NumberAnimation {
      target: root; property: "pulse"; to: 1
      duration: Number(root.cfg("pulse", "attack", 140)); easing.type: Easing.OutQuad
    }
    PauseAnimation { duration: Number(root.cfg("pulse", "hold", 90)) }
    NumberAnimation {
      target: root; property: "pulse"; to: 0
      duration: Number(root.cfg("pulse", "release", 620)); easing.type: Easing.InOutQuad
    }
  }

  onFullEffectsChanged: if (!fullEffects) { pulseAnim.stop(); pulse = 0 }

  // Frame clock. Bound rather than timer-driven so it only advances on frames
  // the compositor actually asks for; a parked scene stops costing wakeups.
  FrameAnimation {
    id: clock
    running: root.fullEffects
  }

  // Scene ----------------------------------------------------------------
  Item {
    id: scene
    anchors.fill: parent
    // The shader pass needs the composite in a texture. When effects are off
    // the layer is dropped entirely rather than run with neutral uniforms, so
    // a parked wallpaper costs no offscreen buffer at all.
    layer.enabled: root.fullEffects
    layer.smooth: true
    layer.effect: ShaderEffect {
      fragmentShader: Qt.resolvedUrl("shaders/livefx.frag.qsb")
      property real time: clock.elapsedTime % 3600
      property real pulse: root.pulse
      property real aberration: Number(root.cfg("pulse", "aberration", 0.010)) * root.intensity
      property real halftone: Number(root.cfg("print", "halftone", 0.20)) * root.intensity
      property real dotScale: Number(root.cfg("print", "dotScale", 190))
      property real grain: Number(root.cfg("print", "grain", 0.035)) * root.intensity
      property real vignette: Number(root.cfg("print", "vignette", 0.34))
      property real bloom: Number(root.cfg("print", "bloom", 0.10)) * root.intensity
      property vector2d resolution: Qt.vector2d(Math.max(1, root.width), Math.max(1, root.height))
      property vector4d accent: Qt.vector4d(root.inkAccent.r, root.inkAccent.g, root.inkAccent.b, 1)
      property vector4d secondary: Qt.vector4d(root.inkSecondary.r, root.inkSecondary.g, root.inkSecondary.b, 1)
    }

    // Base plate: video when the theme ships one, still image otherwise.
    Loader {
      id: videoLoader
      anchors.fill: parent
      active: root.videoPath !== ""
      sourceComponent: videoComponent
    }

    Image {
      id: still
      // Stays underneath a video as the fallback plate, and is what shows if
      // the file is missing or the codec is unavailable on this machine.
      visible: root.videoPath === "" || videoLoader.status !== Loader.Ready
        || (videoLoader.item !== null && videoLoader.item.failed)
      source: root.imagePath ? Util.fileUrl(root.imagePath) : ""
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      cache: true
      smooth: true
      mipmap: true

      // Sized and centred by hand instead of anchored, because the parallax
      // transform has to move a plate that is deliberately larger than the
      // screen.
      width: parent.width * root.overscan
      height: parent.height * root.overscan
      x: (parent.width - width) / 2 + parent.width * root.driftXAmp * Math.sin(root.phase)
      y: (parent.height - height) / 2 + parent.height * root.driftYAmp * Math.cos(root.phase)
      // Cosine ramp rather than raw sine: it eases at both ends of the zoom,
      // so the camera never appears to stop dead and reverse.
      scale: 1.0 + root.zoomAmp * (0.5 - 0.5 * Math.cos(root.phase))
      transformOrigin: Item.Center
    }

    // Web glints: light travelling along strands somewhere off-frame. Thin,
    // rare and angled, so they read as reflections rather than as scanlines.
    Repeater {
      model: root.fullEffects ? Math.max(0, Number(root.cfg("glints", "count", 3))) : 0

      Item {
        id: glint
        required property int index
        anchors.fill: parent
        clip: true

        readonly property real angle: -22 + (index * 37) % 44
        readonly property real travel: Math.max(parent.width, parent.height) * 1.6

        Rectangle {
          id: streak
          width: glint.travel * Number(root.cfg("glints", "length", 0.55))
          height: Number(root.cfg("glints", "thickness", 2.0))
          opacity: 0
          rotation: glint.angle
          transformOrigin: Item.Center
          y: glint.height * (0.12 + 0.22 * glint.index) - height / 2
          gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0.0; color: "transparent" }
            GradientStop { position: 0.42; color: Qt.rgba(root.inkAccent.r, root.inkAccent.g, root.inkAccent.b, 0.75) }
            GradientStop { position: 0.5; color: Qt.rgba(1, 1, 1, 0.9) }
            GradientStop { position: 0.58; color: Qt.rgba(root.inkSecondary.r, root.inkSecondary.g, root.inkSecondary.b, 0.7) }
            GradientStop { position: 1.0; color: "transparent" }
          }
        }

        SequentialAnimation {
          id: sweep
          running: false
          ParallelAnimation {
            NumberAnimation {
              target: streak; property: "x"
              from: -streak.width; to: glint.width
              duration: Number(root.cfg("glints", "speed", 900))
              easing.type: Easing.InOutSine
            }
            SequentialAnimation {
              NumberAnimation { target: streak; property: "opacity"; to: 0.55 * root.intensity; duration: 180 }
              NumberAnimation { target: streak; property: "opacity"; to: 0; duration: Number(root.cfg("glints", "speed", 900)) - 180 }
            }
          }
          onFinished: glintTimer.restart()
        }

        Timer {
          id: glintTimer
          // Staggered first fire, otherwise every strand lights on the same
          // frame the wallpaper appears.
          interval: 1000 * (1 + glint.index * 2
            + Math.random() * Math.max(1, Number(root.cfg("glints", "everyMax", 18)) - Number(root.cfg("glints", "everyMin", 6))))
          running: root.fullEffects
          repeat: false
          onTriggered: sweep.restart()
        }

        Component.onDestruction: sweep.stop()
      }
    }

    // Motes: dust and snow catching the city light. GPU particles, so the
    // count can stay generous without touching the CPU per frame.
    ParticleSystem {
      id: moteSystem
      anchors.fill: parent
      running: root.fullEffects && root.moteRate > 0
      paused: !root.fullEffects

      ImageParticle {
        groups: ["motes"]
        color: root.inkAccent
        colorVariation: 0.55
        alpha: 0
        alphaVariation: 0.35
        entryEffect: ImageParticle.Fade
      }

      Emitter {
        group: "motes"
        // Emitted from a band above the frame so particles are already at
        // terminal drift by the time they enter view.
        anchors.fill: parent
        anchors.topMargin: -parent.height * 0.12
        emitRate: root.moteRate
        lifeSpan: root.moteLifeMs
        lifeSpanVariation: root.moteLifeMs * 0.4
        size: Number(root.cfg("motes", "size", 3.0))
        sizeVariation: Number(root.cfg("motes", "size", 3.0)) * 0.7
        endSize: Number(root.cfg("motes", "size", 3.0)) * 0.35
        velocity: PointDirection {
          x: 0
          y: Number(root.cfg("motes", "fall", 26))
          xVariation: Number(root.cfg("motes", "drift", 18))
          yVariation: Number(root.cfg("motes", "fall", 26)) * 0.6
        }
        acceleration: PointDirection { x: 0; y: 3; xVariation: 6 }
      }
    }
  }

  Component {
    id: videoComponent

    Item {
      property bool failed: false

      MediaPlayer {
        id: player
        source: root.videoPath ? Util.fileUrl(root.videoPath) : ""
        loops: MediaPlayer.Infinite
        videoOutput: vout
        audioOutput: null
        onErrorOccurred: function(error, msg) {
          // Falling back rather than leaving a black plate: the still image
          // underneath is already loaded and correct for the theme.
          console.warn("livewallpaper: video failed, falling back to still — " + msg)
          failed = true
        }
      }

      VideoOutput {
        id: vout
        anchors.fill: parent
        visible: !failed
        fillMode: VideoOutput.PreserveAspectCrop
      }

      Connections {
        target: root
        function onAnimatingChanged() {
          if (root.animating) player.play()
          else player.pause()
        }
      }

      Component.onCompleted: if (root.animating) player.play()
      Component.onDestruction: player.stop()
    }
  }
}
