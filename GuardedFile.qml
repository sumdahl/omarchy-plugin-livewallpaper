import QtQuick
import Quickshell.Io

// A file read with a ceiling on how much of it will ever be read.
//
// Everything this plugin reads is writable local state: a theme's `live.json`,
// the user's global and per-theme overrides, the resolved spec published into
// the runtime directory, the current theme name, the AC sysfs node. `FileView`
// reads whatever it is pointed at, in full, into a process that stays alive for
// the whole session, and it offers no size limit of its own — a file that has
// grown to hundreds of megabytes at one of those paths takes the shell's memory
// with it, whether it got that way through corruption or on purpose.
//
// So `FileView` is used here only for the half of its job that is safe:
// watching. `preload: false` stops it reading the file at all, while
// `watchChanges` keeps delivering the change notifications live edits depend
// on. The content comes from `head -c`, which stops at the ceiling inside the
// read itself rather than measuring the file and then trusting the measurement
// — nothing above the ceiling is ever allocated, and there is no window between
// the check and the read for the file to grow in.
//
// One byte above the ceiling is asked for so an overflow is visible rather than
// silent. A file that trips it is named in the log and then treated exactly as a
// missing one, which for every caller here means falling through to the layer
// below — the same degradation a malformed file already gets.
Item {
  id: guarded

  visible: false
  width: 0
  height: 0

  property string path: ""
  property int maxBytes: 262144
  property bool watchChanges: true
  // A read that never finishes is as bad as one that never stops growing: it
  // holds the single reader, so every later reload queues behind it and this
  // file stops updating for the rest of the session.
  property int timeoutSec: 5

  signal loaded(string text)
  signal loadFailed()

  // Set while a read is in flight and another was asked for. Process ignores a
  // command change while it is running, so the second request has to wait for
  // the first to land rather than being dropped.
  property bool queued: false
  property bool started: false

  onPathChanged: guarded.reload()
  Component.onCompleted: if (guarded.path && !guarded.started) guarded.reload()

  // Re-point the watcher as well as re-read. A theme swap replaces the whole
  // directory the file lived in, so the watch is left on an inode nothing
  // writes to any more; only reassigning the path re-arms it.
  function rearm() {
    watcher.path = ""
    watcher.path = guarded.path
    guarded.reload()
  }

  function reload() {
    if (!guarded.path) {
      guarded.loadFailed()
      return
    }
    if (readProc.running) {
      guarded.queued = true
      return
    }
    guarded.queued = false
    guarded.started = true
    // Two guards the plain `head` did not have.
    //
    // `[ -f ]` is the regular-file test, and it answers from a stat rather than
    // an open, so a FIFO planted at one of these paths is rejected without ever
    // being opened — opening one with no writer on the other end blocks forever,
    // which is exactly the hang this has to avoid. Character devices and
    // directories fail the same test.
    //
    // `timeout` covers what the test cannot: a path that turns into a FIFO in
    // the moment between the test and the read, and a regular file that is
    // simply slow to serve — one on a network mount that has gone away. It runs
    // the read in its own process group and signals the group, so nothing is
    // left behind. Either failure exits non-zero and lands as absence, the same
    // as a missing file.
    readProc.command = ["timeout", "-s", "KILL", String(guarded.timeoutSec),
                        "sh", "-c",
                        "[ -f \"$1\" ] || exit 1\nexec head -c \"$2\" -- \"$1\"",
                        "sh", guarded.path, String(guarded.maxBytes + 1)]
    readProc.running = true
  }

  FileView {
    id: watcher
    path: guarded.path
    // Watch only. Without this the file is read here as well, which is the
    // whole thing this component exists to prevent.
    preload: false
    watchChanges: guarded.watchChanges
    printErrors: false
    onFileChanged: guarded.reload()
  }

  Process {
    id: readProc

    property string collected: ""

    stdout: StdioCollector {
      // Bounded by the `head -c` in the command rather than by trusting the
      // file, so this cannot collect more than the ceiling plus one byte.
      onStreamFinished: readProc.collected = String(text || "")
    }

    onExited: function(exitCode, exitStatus) {
      var text = readProc.collected
      readProc.collected = ""
      var pending = guarded.queued
      guarded.queued = false

      if (exitCode !== 0 || exitStatus !== 0) {
        // Missing, unreadable, not a regular file, or past the deadline.
        // Absence, as far as every caller is concerned.
        guarded.loadFailed()
      } else if (text.length > guarded.maxBytes) {
        console.warn("livewallpaper: ignoring " + guarded.path
                     + " — larger than the " + guarded.maxBytes + " byte ceiling")
        guarded.loadFailed()
      } else {
        guarded.loaded(text)
      }

      if (pending) guarded.reload()
    }
  }
}
