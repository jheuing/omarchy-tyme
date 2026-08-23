import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  property var shell: null
  property var state: ({ clients: [], active: null, entries: [], settings: {} })
  property bool initialized: false
  property var pendingDone: null
  property string stdoutText: ""
  property string stderrText: ""
  property bool responseTooLarge: false
  // client_timer.py emits ASCII JSON, so character and byte counts match.
  readonly property int maxResponseBytes: 1024 * 1024
  readonly property int maxErrorBytes: 16 * 1024
  readonly property string helperPath: Qt.resolvedUrl("client_timer.py").toString().replace("file://", "")

  function appendOutput(data, isError) {
    var chunk = String(data)
    var limit = isError ? maxErrorBytes : maxResponseBytes
    var output = isError ? stderrText : stdoutText
    if (output.length + chunk.length > limit) {
      if (isError) stderrText = output + chunk.slice(0, limit - output.length)
      else {
        responseTooLarge = true
        helper.signal(9)
      }
      return
    }
    if (isError) stderrText = output + chunk
    else stdoutText = output + chunk
  }

  function run(args, done) {
    if (helper.running) return false
    pendingDone = done || null
    stdoutText = ""
    stderrText = ""
    responseTooLarge = false
    helper.command = ["python3", helperPath].concat(args)
    helper.running = true
    return true
  }

  Process {
    id: helper
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(data) { root.appendOutput(data, false) }
    }
    stderr: SplitParser {
      splitMarker: ""
      onRead: function(data) { root.appendOutput(data, true) }
    }
    onExited: {
      var done = root.pendingDone
      root.pendingDone = null
      var response
      if (root.responseTooLarge) response = { ok: false, error: "Timer response is too large" }
      else {
        try { response = JSON.parse(root.stdoutText) }
        catch (e) { response = { ok: false, error: root.stderrText || "Could not read timer state" } }
      }
      if (response.ok && response.state) {
        root.state = response.state
        root.initialized = true
      }
      if (done) done(response)
    }
  }

  Component.onCompleted: run(["init"])
}
