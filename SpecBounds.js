.pragma library

// Ranges for every numeric the spec can set.
//
// A ceiling on how many bytes of a spec file are read says nothing about what
// those bytes ask for. `glints.count` becomes a `Repeater.model`, `motes.rate`
// an emitter's particles per second, `motes.life` how long each one is retained,
// and the pulse and glint values become animation durations and timer intervals.
// A file well under a kilobyte can therefore ask for a million scene items or an
// emitter that never retires a particle, and the cost lands in a compositor-
// adjacent process that stays up for the whole session. Every one of these paths
// is writable local state — a theme's `live.json`, the user overrides — so the
// values are treated as input to validate rather than configuration to trust.
//
// The ranges are deliberately wider than anything a real theme wants: they are
// the point past which a value stops being a look and starts being a denial of
// service. Out-of-range clamps to the nearest end rather than dropping the whole
// layer, so a typo still renders something close to what was asked for.
// Non-numeric or non-finite is not a value at all and falls back to the layer's
// own default instead.
var BOUNDS = {
  // Camera. `period` is the loop length in seconds; the rest are fractions of
  // the screen, and the still is overscanned to cover them.
  "motion.period": [4, 3600],
  // Multiplier on the loop, so a spec can ask for livelier motion without
  // restating the period. Effective loop = period / speed.
  "motion.speed": [0.1, 8],
  "motion.zoom": [0, 0.5],
  "motion.driftX": [0, 0.25],
  "motion.driftY": [0, 0.25],

  // Comic-print pass. Uniforms on one shader — cost is fixed per frame, so
  // these bound the look rather than the load.
  "print.halftone": [0, 1],
  "print.dotScale": [1, 1000],
  "print.grain": [0, 1],
  "print.vignette": [0, 1],
  "print.bloom": [0, 1],

  // Spider-sense pulse. Seconds between fires, milliseconds per stage.
  "pulse.everyMin": [1, 3600],
  "pulse.everyMax": [1, 3600],
  "pulse.attack": [16, 10000],
  "pulse.hold": [0, 10000],
  "pulse.release": [16, 10000],
  "pulse.aberration": [0, 0.1],

  // Web glints. `count` is the one that instantiates scene items, so it gets
  // the tightest ceiling here — a dozen strands is already more than reads.
  "glints.count": [0, 12],
  "glints.everyMin": [1, 3600],
  "glints.everyMax": [1, 3600],
  "glints.length": [0, 4],
  "glints.thickness": [0, 64],
  // Also an animation duration with 180ms subtracted from it, so the floor
  // keeps that remainder positive.
  "glints.speed": [200, 20000],

  // Motes. `rate` x `life` is the population the particle system carries, so
  // both ends matter: 500/s held for 120s is the worst this can be asked for.
  "motes.rate": [0, 500],
  "motes.life": [100, 120000],
  "motes.size": [0, 64],
  "motes.drift": [0, 500],
  "motes.fall": [-500, 500],

  // Lock surface intensity.
  "lock.pulse": [0, 1]
}

var SECTION_KEYS = (function () {
  var map = {}
  for (var name in BOUNDS) {
    var dot = name.indexOf(".")
    var section = name.substring(0, dot)
    if (!map[section]) map[section] = []
    map[section].push(name.substring(dot + 1))
  }
  return map
})()

// Clamp one value on the way out of the spec. Keys with no range — colours, the
// video path, booleans — are returned untouched.
function clamp(section, key, value, fallback) {
  var bound = BOUNDS[section + "." + key]
  if (!bound) return value
  var n = Number(value)
  if (!isFinite(n)) return fallback
  if (n < bound[0]) return bound[0]
  if (n > bound[1]) return bound[1]
  return n
}

// Clamp a whole merged spec. Returns a copy: the merged sections are the very
// objects the parsed layers hold, and a layer must still say what its file said
// so a later re-merge starts from the same place.
//
// A value that is not a number is deleted rather than replaced, because the
// right default belongs to the consumer, and dropping the key is what makes it
// fall through to that consumer's own fallback.
function sanitize(spec) {
  if (!spec || typeof spec !== "object") return spec
  var out = {}
  for (var k in spec) out[k] = spec[k]

  for (var section in SECTION_KEYS) {
    var src = out[section]
    if (!src || typeof src !== "object") continue
    var copy = {}
    for (var key in src) copy[key] = src[key]

    var keys = SECTION_KEYS[section]
    for (var i = 0; i < keys.length; i++) {
      var name = keys[i]
      if (copy[name] === undefined || copy[name] === null) continue
      var n = Number(copy[name])
      if (!isFinite(n)) delete copy[name]
      else copy[name] = clamp(section, name, n, n)
    }
    out[section] = copy
  }
  return out
}
