# Live Wallpaper

A drop-in replacement for Omarchy's `omarchy.background` service that adds a
**per-theme live treatment** to the desktop.

The lock screen picks up the same treatment behind its blur if you also install
the companion `io.github.sumdahl.lock` plugin. That part is optional — without
it the desktop treatment works exactly the same and the lock screen stays
stock.

**Every theme is live by default.** Install the plugin and all of them animate,
each in its own palette — a theme has to ship nothing at all. Themes that want
a specific look declare it; users who want something else override it; anyone
who wants a static wallpaper opts out.

## Install

```bash
omarchy-plugin-clone io.github.sumdahl.livewallpaper   # or clone the repo into ~/.config/omarchy/plugins/
./install.sh                                           # enables it and adds the menu rows
omarchy restart shell                                  # service plugins mount on restart only
```

`install.sh` calls `omarchy-live menu-install`, which merges the
`Style > Live Wallpaper` rows into `~/.config/omarchy/extensions/omarchy-menu.jsonc`.
That step is separate because Omarchy's menu reads exactly one user file and
plugins cannot contribute rows to it. The merge is textual and additive: it
creates the file if missing, never touches keys it does not own, preserves the
comments in a JSONC file, and is a no-op on a second run.
`omarchy-live menu-uninstall` removes only its own rows.

Nothing about the menu is required — the bar icon works on its own.

## Bar widget

An icon on the bar, active while the treatment is actually rendering:

- **click** — panel with the controls below
- **middle click** — pause or resume, no panel
- **tooltip** — current theme and whether the scene is running, parked behind a
  fullscreen window, or reduced on battery

The panel adjusts loop length, zoom, halftone, grain, vignette, bloom, motes and
glints; toggles the treatment and the battery notice; and resets to the theme
default by dropping your override. Sliders commit on release, so a drag is one
write rather than sixty. Values are read from the resolved spec the service
publishes, so the panel follows changes made from the menu, from a terminal, or
by switching theme.

## Spec layers

Four sources, merged **shallow per section** — a layer naming `motion` owns that
whole section, and sections it omits fall through. Later wins:

| # | Source | Purpose |
|---|--------|---------|
| 1 | built-in defaults | Baseline: parallax and motes, no halftone, colours `auto` |
| 2 | `~/.config/omarchy/live.json` | Your preference for every theme |
| 3 | `<theme>/live/live.json` | What the theme's author intended |
| 4 | `~/.config/omarchy/live/<theme>.json` | Your override for one theme |

`"auto"` colours resolve against the live palette, so ink always matches the
desktop. Halftone is **off** in the baseline on purpose: the ben-day comic pass
is a Spider-Verse conceit and looks wrong on a photographic or minimal theme, so
only a theme that asks for it gets it.

A malformed layer is warned about and skipped — the layer below shows instead of
a black wallpaper.

**Opting out:** `"enabled": false` at the top level of any layer. In layer 2 it
disables the plugin everywhere, in layer 3 a theme author declares "this theme
should not animate", and in layer 4 you overrule either:

```bash
omarchy-live disable nord     # persistent, this theme
omarchy-live off              # this session, every theme
```

## Where edits land

`tune`, `preset` and `edit` always write to layer 4,
`~/.config/omarchy/live/<theme>.json` — never into the theme itself. So tuning
works identically on a stock theme under `/usr/share/omarchy/`, on a theme
cloned from git, and on one you wrote yourself, and none of them are modified
by it. `omarchy-live path` prints the file that would be used.

That also makes **reset** meaningful: `omarchy-live reset` drops your override
and the theme's own look returns.

Editing a theme's own spec is an authoring act, and needs saying so:

```bash
omarchy-live edit theme      # opens <theme>/live/live.json itself
```

An earlier version guessed at this — it wrote into a theme's own spec whenever
one existed and was writable. That quietly dirtied git checkouts on every slider
drag, and left `reset` with nothing to reset to, since the "default" was the
file being edited.

`omarchy-live install <theme>` materialises an editable spec inside a theme
directory. For a stock theme it creates an **overlay** — a user theme directory
holding nothing but `live/`. `omarchy-theme-set` copies the stock theme into
staging first and lays the user one over the top, so the overlay adds a spec
without forking wallpapers or colours.

## What it renders

Composited in this order, then put through one shader pass so the whole frame
reads as a single printed cel rather than layered sprites:

| Layer | What it does |
|-------|--------------|
| **Parallax** | Slow zoom and elliptical drift over the wallpaper. Every term is an integer harmonic of one `0..2π` phase, so the loop closes with matching position *and* velocity — no seam at the wrap. |
| **Web glints** | Thin angled light streaks sweeping across, at randomised intervals. Reads as light travelling along a strand. |
| **Motes** | GPU particles drifting down — dust, snow, city light. |
| **Comic print** | Fragment shader: rotated ben-day dot screens in the theme's two ink colours, chromatic aberration on the spider-sense pulse, an accent rim, highlight bloom, animated grain, vignette. |

The dot screens are weighted to the **midtones**, not to everything dark, so a
large flat night sky stays clean instead of turning into a screen door.

## Power behaviour

The scene parks itself — animations stopped, shader layer and its offscreen
buffer dropped entirely — when:

- a **fullscreen window** covers the wallpaper (resumes within ~1s of leaving it)
- the **screen is locked** — detected from whichever lock plugin is mounted,
  so this works on its own; the companion plugin also pushes the signal over
  IPC when installed
- the treatment is switched off

Measured cost of the full treatment on Intel Iris Xe at 1920x1080:
**+3.6 percentage points of one core** over the stock static background.

`power.batterySaver: true` drops to parallax-only on battery. The baseline ships
it **off**, so the full effect is always on; turn it on if you want the battery
back.

On unplugging, a notification offers a one-click pause — once per discharge,
never at startup, and never when the treatment is already off. Pausing parks the
scene but leaves the plugin mounted, so `omarchy-live on` restores the desktop
and the lock screen exactly as they were. Silence it with
`power.notifyOnBattery: false` in any layer.

## Control

```bash
omarchy-live status              # current state as JSON, including which layers apply
omarchy-live off | on | toggle   # this session, every theme
omarchy-live disable <theme>     # persistent, one theme
omarchy-live tune print.halftone 0.4
omarchy-live preset bold         # subtle | balanced | bold
omarchy-live reset               # drop your override for this theme
omarchy-live path                # print the file an edit would go to
omarchy-live edit                # open that file
```

When an edit lands in a theme's own spec it is mirrored into the staged copy
under `~/.local/state/` too — writing only there would look right until the next
`omarchy theme set` rebuilt the directory and silently discarded the change.

## live.json

Every key is optional; the values below are the built-in defaults.

```jsonc
{
  "enabled": true,                                      // false opts this layer out
  "motion": { "period": 60, "zoom": 0.05, "driftX": 0.014, "driftY": 0.009 },
  "print":  { "halftone": 0.0, "dotScale": 150, "grain": 0.022,
              "vignette": 0.30, "bloom": 0.08 },
  "pulse":  { "everyMin": 24, "everyMax": 55, "attack": 200, "hold": 90,
              "release": 800, "aberration": 0.004 },
  "glints": { "count": 2, "everyMin": 12, "everyMax": 30, "length": 0.45,
              "thickness": 1.6, "speed": 1100 },
  "motes":  { "rate": 14, "life": 14000, "size": 2.6, "drift": 16, "fall": 18 },
  "colors": { "accent": "auto", "secondary": "auto" },  // "auto" = theme palette
  "lock":   { "pulse": 0.5 },                           // 0 disables the lock rim
  "power":  { "batterySaver": false, "notifyOnBattery": true },
  "video":  null                                        // path, relative to live/
}
```

`period` is in seconds; every other duration is in milliseconds.

### Video wallpapers

Set `video` to a file next to `live.json` and it plays looped through
QtMultimedia instead of the parallax still, with the shader pass still applied
on top. If the file is missing or the codec is unavailable the still image shows
instead — the plate underneath is already loaded and correct for the theme.

The parallax path is usually the better choice: it stays crisp at any
resolution because it samples the 4K source directly, loops with no seam, and
costs far less than continuous video decode.

## How it replaces the built-in

`manifest.json` declares `omarchy.clonedFrom: "omarchy.background"`, so enabling
this plugin moves the built-in into `disabledPlugins[]` and exactly one
background renderer is ever mounted.

The stock contract is preserved verbatim: the `background` IPC target that
`omarchy-theme-bg-set` and `omarchy-theme-set` call into, the masked wipe
between wallpapers, and the double-click selectors. The live scene fades out for
the duration of a wipe so theme switching still gets the stock reveal instead of
a crossfade between two animating scenes.

Live controls sit on a separate `livewallpaper` IPC target so that contract is
never touched.

## Rebuilding the shader

`shaders/livefx.frag.qsb` is committed. After editing the `.frag`:

```bash
/usr/lib/qt6/bin/qsb --glsl "100 es,120,150" --hlsl 50 --msl 12 \
  -o shaders/livefx.frag.qsb shaders/livefx.frag
omarchy restart shell
```

Service plugins are remounted on shell restart, not by `rescanPlugins` — editing
one and only rescanning leaves the old code running.
