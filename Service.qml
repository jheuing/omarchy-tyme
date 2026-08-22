import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  property var shell: null
  property var state: ({ clients: [], active: null, entries: [], settings: {} })
  property var pendingDone: null
  readonly property string helperPath: Qt.resolvedUrl("client_timer.py").toString().replace("file://", "")

  function run(args, done) {
    if (helper.running) return false
    pendingDone = done || null
    helper.stdout = out.createObject(helper)
    helper.stderr = err.createObject(helper)
    helper.command = ["python3", helperPath].concat(args)
    helper.running = true
    return true
  }

  Component { id: out; StdioCollector {} }
  Component { id: err; StdioCollector {} }
  Process {
    id: helper
    onExited: {
      var done = root.pendingDone
      root.pendingDone = null
      var response
      try { response = JSON.parse(stdout.text) }
      catch (e) { response = { ok: false, error: stderr.text || "Could not read timer state" } }
      if (response.ok && response.state) root.state = response.state
      if (done) done(response)
    }
  }

  Component.onCompleted: run(["init"])
}
