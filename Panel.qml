import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "ch.wertstifter.tyme"
  implicitWidth: timerButton.implicitWidth
  implicitHeight: timerButton.implicitHeight

  property var state: ({ clients: [], active: null, entries: [] })
  property string selectedClientId: ""
  property bool quickListOpen: false
  property bool quickSelectionArmed: false
  property string activeTab: "timer"
  property string editingClientId: ""
  property bool companyEditorOpen: false
  property string errorText: ""
  property string exportText: ""
  property var pendingDone: null
  property string reportWeek: ""
  property var report: ({ weekStart: "", weekEnd: "", weekNumber: 0, month: "", days: [], monthRows: [], monthTotalSeconds: 0 })
  property var todaySummary: ({ rows: [], seconds: 0 })
  property string exportPeriod: "week"
  property string exportCursor: ""
  property var exportSummary: ({ count: 0, seconds: 0, rows: [] })
  property int workdayHoursSetting: 8
  property string menuLabelStyle: "project"
  readonly property bool opened: panelController.open
  property bool popoutSwitchClosing: false
  readonly property real openPanelIndicatorWidth: timerButton.labelWidth
  readonly property string helperPath: Qt.resolvedUrl("client_timer.py").toString().replace("file://", "")
  readonly property var active: state.active
  readonly property bool running: active !== null
  readonly property bool paused: running && active.pausedAt !== null
  readonly property color panelForeground: bar ? bar.foreground : Color.foreground
  readonly property var themeColorOptions: [
    { value: "theme:red", label: "Color 1" }, { value: "theme:orange", label: "Color 2" },
    { value: "theme:yellow", label: "Color 3" }, { value: "theme:green", label: "Color 4" },
    { value: "theme:cyan", label: "Color 5" }, { value: "theme:blue", label: "Color 6" },
    { value: "theme:magenta", label: "Color 7" }, { value: "theme:brown", label: "Color 8" }
  ]

  SystemClock { id: clock; precision: SystemClock.Seconds; enabled: root.running }

  FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/colors.toml"
    watchChanges: true
    printErrors: false
    onLoaded: if (root.state.clients.length) root.refresh()
    onFileChanged: reload()
  }
  Timer {
    id: themeColorRefresh
    interval: 250
    repeat: false
    onTriggered: {
      if (helper.running) restart()
      else root.refresh()
    }
  }
  Connections {
    target: Color
    function onAccentChanged() { themeColorRefresh.restart() }
    function onForegroundChanged() { themeColorRefresh.restart() }
    function onBackgroundChanged() { themeColorRefresh.restart() }
  }

  function clientFor(id) {
    for (var i = 0; i < state.clients.length; i++) if (state.clients[i].id === id) return state.clients[i]
    return null
  }
  function resolvedCompanyColor(color) {
    if (String(color).indexOf("theme:") === 0)
      return state.themeColors ? state.themeColors[String(color).slice(6)] || Color.accent : Color.accent
    return color
  }
  function elapsed() {
    if (!active) return 0
    var until = paused ? Date.parse(active.pausedAt) : clock.date.getTime()
    return Math.max(0, Math.floor((until - Date.parse(active.start)) / 1000) - Number(active.pausedSeconds || 0))
  }
  function elapsedText() {
    var seconds = elapsed(); var h = Math.floor(seconds / 3600); var m = Math.floor((seconds % 3600) / 60); var s = seconds % 60
    return (h < 10 ? "0" : "") + h + ":" + (m < 10 ? "0" : "") + m + ":" + (s < 10 ? "0" : "") + s
  }
  function localDateString(date) {
    return date.getFullYear() + "-" + ("0" + (date.getMonth() + 1)).slice(-2) + "-" + ("0" + date.getDate()).slice(-2)
  }
  function weekFor(date) {
    var copy = new Date(date.getFullYear(), date.getMonth(), date.getDate())
    copy.setDate(copy.getDate() - ((copy.getDay() + 6) % 7))
    return localDateString(copy)
  }
  function dateAdd(dateString, days) {
    var date = new Date(dateString + "T12:00:00")
    date.setDate(date.getDate() + days)
    return localDateString(date)
  }
  function monthRange(dateString) {
    var date = new Date(dateString + "T12:00:00")
    var start = new Date(date.getFullYear(), date.getMonth(), 1)
    var end = new Date(date.getFullYear(), date.getMonth() + 1, 0)
    return { from: localDateString(start), to: localDateString(end) }
  }
  function exportRange() {
    if (exportPeriod === "month") return monthRange(exportCursor)
    if (exportPeriod === "custom") return { from: exportFrom.text.trim(), to: exportTo.text.trim() }
    return { from: weekFor(new Date(exportCursor + "T12:00:00")), to: dateAdd(weekFor(new Date(exportCursor + "T12:00:00")), 6) }
  }
  function loadExportSummary() {
    var range = exportRange()
    if (range.from !== "" && range.to !== "") run(["summary", "--from", range.from, "--to", range.to])
  }
  function shiftExportPeriod(amount) {
    exportCursor = dateAdd(exportCursor, exportPeriod === "month" ? amount * 31 : amount * 7)
    loadExportSummary()
  }
  function exportFileName() {
    var range = exportRange()
    return Quickshell.env("HOME") + "/Downloads/tyme_" + range.from + "_to_" + range.to + ".csv"
  }
  function exportRangeLabel() {
    var range = exportRange()
    return localShortDate(range.from) + "  -  " + localShortDate(range.to)
  }
  function loadReport() { if (reportWeek !== "") run(["report", "--week", reportWeek]) }
  function loadToday(done) { run(["today"], done) }
  function shiftReportWeek(days) {
    var date = new Date(reportWeek + "T12:00:00")
    date.setDate(date.getDate() + days)
    reportWeek = weekFor(date)
    loadReport()
  }
  function reportMaxSeconds() {
    var max = 1
    for (var i = 0; i < report.monthRows.length; i++) max = Math.max(max, report.monthRows[i].seconds)
    return max
  }
  function reportMaxDaySeconds() {
    var max = workdayTargetHours() * 3600
    for (var i = 0; i < report.days.length; i++) max = Math.max(max, report.days[i].seconds)
    return max
  }
  function daySegmentOffset(segments, index) {
    var offset = 0
    for (var i = 0; i < index; i++) offset += Number(segments[i].seconds) || 0
    return offset
  }
  function workdayTargetHours() { return workdayHoursSetting }
  function workdayDifferenceLabel(seconds) {
    var difference = (Number(seconds) || 0) - workdayTargetHours() * 3600
    return (difference >= 0 ? "+" : "-") + hoursLabel(Math.abs(difference))
  }
  function menuLabelColor(tab) {
    if (activeTab !== tab || menuLabelStyle === "plain") return panelForeground
    if (menuLabelStyle === "project" && active && clientFor(active.clientId)) return clientFor(active.clientId).color
    return Color.accent
  }
  function hoursLabel(seconds) {
    var total = Math.max(0, Math.round((Number(seconds) || 0) / 60))
    var hours = Math.floor(total / 60)
    var minutes = total % 60
    return hours > 0 ? hours + "h " + (minutes < 10 ? "0" : "") + minutes + "m" : minutes + "m"
  }
  function activeStartText() {
    if (!active) return ""
    return Qt.locale().toString(new Date(active.start), "HH:mm")
  }
  function dayLabel(dateString) {
    var date = new Date(dateString + "T12:00:00")
    return ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"][(date.getDay() + 6) % 7]
  }
  function localShortDate(dateString) {
    var date = new Date(dateString + "T12:00:00")
    try { return Qt.locale().toString(date, Locale.ShortFormat) }
    catch (error) {
      return ("0" + date.getDate()).slice(-2) + "." + ("0" + (date.getMonth() + 1)).slice(-2) + "." + date.getFullYear()
    }
  }
  function localMonth(monthString) {
    var date = new Date(monthString + "-01T12:00:00")
    try { return Qt.locale().toString(date, "MMMM yyyy") }
    catch (error) { return monthString }
  }
  function labelTextColor(hex) {
    var text = hex && hex.toString ? hex.toString() : ""
    if (!/^#[0-9a-fA-F]{6}$/.test(text)) return Color.background
    var value = parseInt(text.slice(1), 16)
    var brightness = ((value >> 16) * 299 + ((value >> 8) & 255) * 587 + (value & 255) * 114) / 1000
    return brightness > 150 ? "#1a1b26" : "#f7f7f7"
  }
  function run(args, done) {
    if (helper.running) return
    errorText = ""
    pendingDone = done || null
    helper.stdout = out.createObject(helper)
    helper.stderr = err.createObject(helper)
    helper.command = ["python3", helperPath].concat(args)
    helper.running = true
  }
  function refresh() { run(["state"]) }
  function matchingCompanies(query) {
    var needle = query.trim().toLowerCase()
    if (needle === "") return state.clients
    return state.clients.filter(function(company) { return company.name.toLowerCase().indexOf(needle) !== -1 })
  }
  function companyForQuery(query) {
    var matches = matchingCompanies(query)
    var needle = query.trim().toLowerCase()
    for (var i = 0; i < matches.length; i++)
      if (matches[i].name.toLowerCase() === needle) return matches[i]
    return matches.length === 1 ? matches[0] : null
  }
  function selectQuickCompany(company) {
    selectedClientId = company.id
    quickSelectionArmed = true
    quickCompanyField.forceActiveFocus()
  }
  function primaryTimerAction(stopWhenEmpty) {
    var company = companyForQuery(quickCompanyField.text) || (selectedClientId ? clientFor(selectedClientId) : null)
    if (!company) {
      if (stopWhenEmpty && running && quickCompanyField.text.trim() === "") run(["stop"])
      else errorText = "Choose a project from the matches"
      return
    }
    selectedClientId = company.id
    run([running ? "switch" : "start", "--client-id", company.id, "--note", noteField.text])
    quickListOpen = false
    quickCompanyField.text = ""
    selectedClientId = ""
    quickSelectionArmed = false
    noteField.text = ""
  }
  function moveQuickCompany(delta) {
    quickListOpen = true
    var matches = matchingCompanies(quickCompanyField.text)
    if (matches.length === 0) return
    var index = -1
    for (var i = 0; i < matches.length; i++)
      if (matches[i].id === selectedClientId) { index = i; break }
    index = index < 0 ? (delta > 0 ? 0 : matches.length - 1) : (index + delta + matches.length) % matches.length
    selectedClientId = matches[index].id
    quickSelectionArmed = true
  }
  function editCompany(clientId) {
    var company = clientFor(clientId)
    if (!company) return
    editingClientId = clientId
    companyEditorOpen = true
    companyName.text = company.name
    var color = company.colorToken || company.color
    companyColor.value = String(color).indexOf("theme:") === 0 ? color : "custom"
    customCompanyColor.text = companyColor.value === "custom" ? color : ""
  }
  function newCompany() {
    editingClientId = ""
    companyEditorOpen = true
    companyName.text = ""
    companyColor.value = "theme:blue"
    customCompanyColor.text = ""
    companyName.forceActiveFocus()
  }
  function saveCompany() {
    var color = companyColor.value === "custom" ? customCompanyColor.text.trim() : companyColor.value
    var saved = function() {
      root.companyEditorOpen = false
      root.editingClientId = ""
      companyName.text = ""
    }
    if (editingClientId)
      run(["client-update", "--id", editingClientId, "--name", companyName.text, "--color", color], saved)
    else
      run(["client-add", "--name", companyName.text, "--color", color], saved)
  }
  function saveWorkday() {
    var hours = Number(workdayHours.text.trim())
    if (hours < 1 || hours > 10 || hours % 1 !== 0) {
      errorText = "Daily target must be a whole number between 1 and 10"
      return
    }
    workdayHoursSetting = hours
    todayDonut.requestPaint()
    run(["workday-set", "--hours", workdayHours.text.trim()])
  }
  function saveMenuLabelStyle(style) {
    menuLabelStyle = style
    run(["menu-labels-set", "--style", style])
  }
  function editedCompanyColor() {
    return companyColor.value === "custom" ? customCompanyColor.text.trim() : companyColor.value
  }
  function showTab(tab) {
    activeTab = tab
    if (tab === "timer") Qt.callLater(function() { quickCompanyField.forceActiveFocus() })
    if (tab === "reports") loadReport()
    if (tab === "export") loadExportSummary()
    if (tab === "settings") Qt.callLater(function() {
      workdayHours.text = String(root.workdayHoursSetting)
    })
  }
  function cycleTab(direction) {
    var tabs = ["timer", "reports", "export", "settings"]
    var index = tabs.indexOf(activeTab)
    showTab(tabs[(index + direction + tabs.length) % tabs.length])
  }
  function open() { panelController.show() }
  function close() { panelController.hide() }
  function toggle() { opened ? close() : open() }
  function closeForPopoutSwitch() {
    popoutSwitchClosing = true
    close()
    Qt.callLater(function() { popoutSwitchClosing = false })
  }

  onOpenedChanged: {
    if (opened && activeTab === "timer") {
      quickListOpen = false
      Qt.callLater(function() { quickCompanyField.forceActiveFocus() })
    }
  }

  PanelController { id: panelController }

  Component {
    id: heroIcon
    Text {
      text: root.activeTab === "timer"
        ? "\uf520"
        : (root.activeTab === "reports" ? "\uf080" : (root.activeTab === "export" ? "\udb80\ude79" : "\udb81\udc93"))
      color: root.activeTab === "timer" && root.active && root.clientFor(root.active.clientId)
        ? root.clientFor(root.active.clientId).color : root.panelForeground
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.display
    }
  }

  Component { id: out; StdioCollector {} }
  Component { id: err; StdioCollector {} }
  Process {
    id: helper
    onExited: {
      var done = root.pendingDone
      root.pendingDone = null
      var response
      try { response = JSON.parse(stdout.text) } catch (e) { response = { ok: false, error: stderr.text || "Could not read timer state" } }
      if (response.ok) {
        if (response.state) {
          root.state = response.state
          root.workdayHoursSetting = Number(root.state.settings.workdayHours) || 8
          root.menuLabelStyle = root.state.settings.menuLabelStyle || "project"
          if (!root.selectedClientId && root.state.clients.length) root.selectedClientId = root.state.clients[0].id
        }
        if (response.report) root.report = response.report
        if (response.today) root.todaySummary = response.today
        if (response.summary) root.exportSummary = response.summary
        if (response.path) root.exportText = "CSV saved to Downloads"
      } else root.errorText = response.error || "Timer action failed"
      if (response.ok && done) done()
      else if (response.ok && response.state) Qt.callLater(root.loadToday)
    }
  }
  Component.onCompleted: {
    reportWeek = weekFor(new Date())
    exportCursor = localDateString(new Date())
    run(["init"], function() {
      Qt.callLater(function() { root.loadToday(function() { Qt.callLater(root.loadReport) }) })
    })
  }

  WidgetButton {
    id: timerButton
    anchors.fill: parent
    bar: root.bar
    horizontalMargin: root.running && root.menuLabelStyle === "plain" ? 4 : 10
    verticalPadding: 6
    fixedWidth: root.running ? companyBadge.implicitWidth + 2 * scaledHorizontalMargin : -1
    active: root.opened && root.menuLabelStyle === "plain"
    useActiveColor: false
    foreground: root.active && root.clientFor(root.active.clientId) ? root.clientFor(root.active.clientId).color : Color.foreground
    text: root.running
      ? " "
      : "\uf520"
    labelVisible: !root.running
    tooltipText: root.active && root.running
      ? root.clientFor(root.active.clientId).name + " · " + root.elapsedText() + (root.paused ? " · paused" : "")
      : "Click to start tracking a client"
    onPressed: function(button) { if (button === Qt.LeftButton) root.toggle() }

    Rectangle {
      id: companyBadge
      visible: root.running
      implicitWidth: badgeName.implicitWidth + (root.menuLabelStyle === "plain" ? 0 : Style.space(14))
      implicitHeight: root.menuLabelStyle === "plain" ? badgeName.implicitHeight : Style.space(20)
      width: implicitWidth
      height: implicitHeight
      radius: Style.space(3)
      color: root.menuLabelStyle === "plain" ? "transparent"
        : (root.menuLabelStyle === "project" && root.active && root.clientFor(root.active.clientId)
          ? root.clientFor(root.active.clientId).color : Color.accent)
      anchors.centerIn: parent

      Text {
        id: badgeName
        anchors.centerIn: parent
        text: "\uf520 " + (root.active && root.clientFor(root.active.clientId)
          ? root.clientFor(root.active.clientId).name : "Company")
        color: root.menuLabelStyle === "plain" ? root.panelForeground : root.labelTextColor(parent.color)
        font.family: timerButton.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
      }
    }
  }

  KeyboardPanel {
    id: popup
    anchorItem: timerButton
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: root.activeTab === "timer" ? quickCompanyField : keyCatcher
    contentWidth: popup.fittedContentWidth(Style.space(380))
    contentHeight: popup.fittedContentHeight(content.implicitHeight)
    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) { if (dx !== 0) root.cycleTab(dx) }
      onReturnRequested: if (root.activeTab === "timer") root.primaryTimerAction(true)
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
    }
    Column {
      id: content
      width: parent.width
      spacing: Style.space(10)
      PanelHero {
        width: parent.width
        iconComponent: heroIcon
        foreground: root.panelForeground
        fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        title: root.activeTab === "timer" ? "Tyme" : (root.activeTab === "reports" ? "Reports" : (root.activeTab === "export" ? "Export" : "Settings"))
        meta: root.activeTab === "timer"
          ? (root.active ? root.clientFor(root.active.clientId).name + " · " + root.elapsedText()
            + (root.paused ? " · PAUSED" : "") : "READY TO TRACK TIME")
          : (root.activeTab === "reports" ? "WEEK " + root.report.weekNumber + " · " + root.localMonth(root.report.month)
            : (root.activeTab === "export" ? root.state.entries.length + " RECENT ENTRIES" : "PROJECTS & COLORS"))
      }
      Row {
        width: parent.width
        spacing: Style.space(6)
        Button {
          width: (parent.width - 3 * parent.spacing) / 4
          text: "Timer"
          iconText: "\udb81\udd1b"
          selected: root.activeTab === "timer"
          foreground: root.menuLabelColor("timer")
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          fontSize: Style.font.caption
          onClicked: root.showTab("timer")
        }
        Button {
          width: (parent.width - 3 * parent.spacing) / 4
          text: "Reports"
          iconText: "\uf080"
          selected: root.activeTab === "reports"
          foreground: root.menuLabelColor("reports")
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          fontSize: Style.font.caption
          onClicked: root.showTab("reports")
        }
        Button {
          width: (parent.width - 3 * parent.spacing) / 4
          text: "Export"
          iconText: "\udb80\ude79"
          selected: root.activeTab === "export"
          foreground: root.menuLabelColor("export")
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          fontSize: Style.font.caption
          onClicked: root.showTab("export")
        }
        Button {
          width: (parent.width - 3 * parent.spacing) / 4
          text: "Settings"
          iconText: "\udb81\udc93"
          selected: root.activeTab === "settings"
          foreground: root.menuLabelColor("settings")
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          fontSize: Style.font.caption
          onClicked: root.showTab("settings")
        }
      }
      PanelSeparator { width: parent.width }
      PanelSectionHeader {
        visible: root.activeTab === "timer" && root.active !== null
        text: "CURRENT"
        foreground: root.panelForeground
        fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
      }
      Item {
        visible: root.activeTab === "timer" && root.active !== null
        width: parent.width
        implicitHeight: Style.space(100)

        Column {
          anchors.fill: parent
          anchors.topMargin: Style.space(8)
          anchors.bottomMargin: Style.space(8)
          spacing: Style.space(2)
          Row {
            width: parent.width
            Rectangle {
              id: activeProjectBadge
              implicitWidth: activeProjectName.implicitWidth + Style.space(14)
              implicitHeight: Style.space(20)
              width: Math.min(implicitWidth, parent.width - activeElapsed.implicitWidth)
              height: implicitHeight
              radius: Style.space(3)
              color: root.active && root.clientFor(root.active.clientId) ? root.clientFor(root.active.clientId).color : Color.accent
              Text {
                id: activeProjectName
                anchors.centerIn: parent
                width: parent.width - Style.space(14)
                text: root.active && root.clientFor(root.active.clientId) ? root.clientFor(root.active.clientId).name : "Project"
                color: root.labelTextColor(parent.color)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.bodySmall
                font.bold: true
                elide: Text.ElideRight
              }
            }
            Item { width: parent.width - activeProjectBadge.width - activeElapsed.implicitWidth; height: 1 }
            Text {
              id: activeElapsed
              text: root.elapsedText()
              color: root.active && root.clientFor(root.active.clientId) ? root.clientFor(root.active.clientId).color : Color.accent
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
              font.bold: true
              anchors.verticalCenter: parent.verticalCenter
            }
          }
          Item { width: 1; height: Style.space(7) }
          Text {
            text: "Start at " + root.activeStartText()
            color: root.panelForeground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }
          Row {
            width: parent.width
            spacing: Style.space(4)
            Row {
              id: startAdjustmentButtons
              spacing: Style.space(4)
              Repeater {
                model: [-15, -5, 5, 15]
                Button {
                  required property int modelData
                  width: Style.space(32)
                  text: (modelData > 0 ? "+" : "") + modelData
                  bordered: true
                  fontSize: Style.font.caption
                  onClicked: root.run(["adjust-active-start", "--minutes", String(modelData)])
                }
              }
            }
            Item {
              width: parent.width - startAdjustmentButtons.width - stopNowButton.width - 2 * parent.spacing
              height: 1
            }
            Button {
              id: stopNowButton
              text: "Stop now"
              bordered: true
              fontSize: Style.font.caption
              onClicked: root.run(["stop"])
            }
          }
        }
      }
      PanelSeparator {
        visible: root.activeTab === "timer" && root.active !== null
        width: parent.width
      }
      PanelSectionHeader {
        visible: root.activeTab === "timer"
        text: root.running ? "CHANGE PROJECT" : "START PROJECT"
        foreground: root.panelForeground
        fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
      }
      TextField {
        id: quickCompanyField
        visible: root.activeTab === "timer"
        width: parent.width
        placeholderText: root.running ? "Type a company to switch timers" : "Start typing a company name"
        onTextChanged: {
          var company = root.companyForQuery(text)
          root.selectedClientId = company ? company.id : ""
          if (text.trim() === "") root.quickSelectionArmed = false
        }
        onTextEdited: {
          root.quickListOpen = true
          root.quickSelectionArmed = true
        }
        onAccepted: {
          if (root.running && !root.quickSelectionArmed) root.run(["stop"])
          else root.primaryTimerAction(false)
        }
        TapHandler { onTapped: root.quickListOpen = true }
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Down) {
            root.moveQuickCompany(1)
            event.accepted = true
          } else if (event.key === Qt.Key_Up) {
            root.moveQuickCompany(-1)
            event.accepted = true
          }
        }
      }
      Repeater {
        model: root.activeTab === "timer" && root.quickListOpen ? root.matchingCompanies(quickCompanyField.text) : []
        Button {
          required property var modelData
          width: parent.width
          text: modelData.name
          leftAlign: true
          selected: root.selectedClientId === modelData.id
          foreground: modelData.color
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          onClicked: root.selectQuickCompany(modelData)
        }
      }
      TextField {
        id: noteField
        visible: root.activeTab === "timer"
        width: parent.width
        placeholderText: "Optional note"
      }
      Button {
        readonly property var company: root.companyForQuery(quickCompanyField.text) || (root.selectedClientId ? root.clientFor(root.selectedClientId) : null)
        visible: root.activeTab === "timer"
        width: parent.width
        text: company
          ? (root.running ? "Switch to " + company.name : "Start " + company.name)
          : "Choose a project"
        active: company !== null
        onClicked: root.primaryTimerAction(false)
      }
      PanelSeparator {
        visible: root.activeTab === "timer"
        width: parent.width
      }
      PanelSectionHeader {
        visible: root.activeTab === "timer"
        text: "TODAY"
        foreground: root.panelForeground
        fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
      }
      Item {
        visible: root.activeTab === "timer"
        width: parent.width
        implicitHeight: Math.max(todayDonut.implicitHeight, todayLegend.implicitHeight) + Style.space(16)

        Row {
          anchors.fill: parent
          anchors.margins: Style.space(8)
          spacing: Style.space(12)

          Canvas {
            id: todayDonut
            property var summary: root.todaySummary
            implicitWidth: Math.round(parent.width * 0.5 - parent.spacing / 2)
            implicitHeight: Style.space(148)
            width: implicitWidth
            height: implicitHeight
            anchors.verticalCenter: parent.verticalCenter
            onSummaryChanged: requestPaint()
            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()
            onPaint: {
              var context = getContext("2d")
              var rows = summary.rows || []
              var targetSeconds = root.workdayTargetHours() * 3600
              var gaugeSeconds = 10 * 3600
              var start = Math.PI * 0.75
              var sweep = Math.PI * 1.5
              var radius = Math.min(width, height) / 2 - Style.space(12)
              context.clearRect(0, 0, width, height)
              context.lineWidth = Style.space(24)
              context.lineCap = "butt"
              context.beginPath()
              context.strokeStyle = Color.muted
              context.arc(width / 2, height / 2, radius, start, start + sweep)
              context.stroke()
              var offset = 0
              var separatorAngle = Style.space(2) / radius
              for (var i = 0; i < rows.length; i++) {
                var seconds = Math.max(0, Math.min(rows[i].seconds, gaugeSeconds - offset))
                if (seconds <= 0) break
                var segmentStart = start + sweep * offset / gaugeSeconds
                var segmentEnd = start + sweep * (offset + seconds) / gaugeSeconds
                context.beginPath()
                context.strokeStyle = rows[i].color
                context.arc(width / 2, height / 2, radius,
                  segmentStart + separatorAngle / 2,
                  Math.max(segmentStart + separatorAngle / 2, segmentEnd - separatorAngle / 2))
                context.stroke()
                offset += seconds
              }
              var tick = start + sweep * targetSeconds / gaugeSeconds
              context.beginPath()
              context.strokeStyle = Color.foreground
              context.lineWidth = Style.space(2)
              context.moveTo(width / 2 + Math.cos(tick) * (radius - Style.space(10)), height / 2 + Math.sin(tick) * (radius - Style.space(10)))
              context.lineTo(width / 2 + Math.cos(tick) * (radius + Style.space(10)), height / 2 + Math.sin(tick) * (radius + Style.space(10)))
              context.stroke()
              context.textAlign = "center"
              context.textBaseline = "middle"
              context.fillStyle = root.panelForeground
              context.font = "bold " + Style.font.subtitle + "px sans-serif"
              context.fillText(root.hoursLabel(root.todaySummary.seconds), width / 2, height / 2 - Style.space(6))
              context.fillStyle = Color.muted
              context.font = "bold " + Style.font.caption + "px sans-serif"
              context.fillText(root.workdayDifferenceLabel(root.todaySummary.seconds), width / 2, height / 2 + Style.space(10))
            }
          }

          Column {
            id: todayLegend
            width: parent.width - todayDonut.width - parent.spacing
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)

            Repeater {
              model: root.todaySummary.rows
              Row {
                required property var modelData
                width: parent.width
                spacing: Style.space(6)
                Rectangle {
                  width: Style.space(7)
                  height: width
                  radius: width / 2
                  color: modelData.color
                  anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                  width: parent.width - parent.children[0].width - timeLabel.implicitWidth - 2 * parent.spacing
                  text: modelData.name
                  color: root.panelForeground
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
                Text {
                  id: timeLabel
                  text: root.hoursLabel(modelData.seconds)
                  color: Color.muted
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }
            }
            Text {
              visible: root.todaySummary.rows.length === 0
              text: "No time logged today"
              color: Color.muted
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }
      }
      PanelSectionHeader {
        visible: root.activeTab === "settings"
        text: "WORKDAY"
        foreground: root.panelForeground
        fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
      }
      Row {
        visible: root.activeTab === "settings"
        width: parent.width
        spacing: Style.space(8)
        Text {
          width: Style.space(104)
          text: "Daily target"
          color: root.panelForeground
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.body
          anchors.verticalCenter: parent.verticalCenter
        }
        TextField {
          id: workdayHours
          width: parent.width - parent.children[0].width - saveWorkdayButton.width - 2 * parent.spacing
          text: "8"
          placeholderText: "8"
          onAccepted: root.saveWorkday()
        }
        Button {
          id: saveWorkdayButton
          width: Style.space(56)
          height: workdayHours.height
          text: "Save"
          bordered: true
          onClicked: root.saveWorkday()
        }
      }
      PanelSeparator {
        visible: root.activeTab === "settings"
        width: parent.width
      }
      PanelSectionHeader {
        visible: root.activeTab === "settings"
        text: "ACTIVE MENU LABEL"
        foreground: root.panelForeground
        fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
      }
      Row {
        visible: root.activeTab === "settings"
        width: parent.width
        spacing: Style.space(6)
        Button {
          width: (parent.width - 2 * parent.spacing) / 3
          text: "Project"
          selected: root.menuLabelStyle === "project"
          foreground: root.active && root.clientFor(root.active.clientId) ? root.clientFor(root.active.clientId).color : Color.accent
          fontSize: Style.font.caption
          onClicked: root.saveMenuLabelStyle("project")
        }
        Button {
          width: (parent.width - 2 * parent.spacing) / 3
          text: "Theme"
          selected: root.menuLabelStyle === "theme"
          foreground: Color.accent
          fontSize: Style.font.caption
          onClicked: root.saveMenuLabelStyle("theme")
        }
        Button {
          width: (parent.width - 2 * parent.spacing) / 3
          text: "Plain"
          selected: root.menuLabelStyle === "plain"
          foreground: root.panelForeground
          fontSize: Style.font.caption
          onClicked: root.saveMenuLabelStyle("plain")
        }
      }
      PanelSeparator {
        visible: root.activeTab === "settings"
        width: parent.width
      }
      Item {
        visible: root.activeTab === "reports"
        width: parent.width
        height: Math.max(reportBack.implicitHeight, reportHeading.implicitHeight, reportForward.implicitHeight)

        PanelActionButton {
          id: reportBack
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          iconText: "\uf053"
          tooltipText: "Previous week"
          foreground: root.panelForeground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          bordered: true
          onClicked: root.shiftReportWeek(-7)
        }

        Column {
          id: reportHeading
          anchors.left: reportBack.right
          anchors.right: reportForward.left
          anchors.leftMargin: Style.space(10)
          anchors.rightMargin: Style.space(10)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(1)

          Text {
            width: parent.width
            text: "WEEK " + root.report.weekNumber
            color: root.panelForeground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.subtitle
            font.bold: true
            horizontalAlignment: Text.AlignHCenter
          }
          Text {
            width: parent.width
            text: root.localShortDate(root.report.weekStart) + "  -  " + root.localShortDate(root.report.weekEnd)
            color: Color.muted
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
          }
        }

        PanelActionButton {
          id: reportForward
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          iconText: "\uf054"
          tooltipText: "Next week"
          foreground: root.panelForeground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          bordered: true
          onClicked: root.shiftReportWeek(7)
        }
      }
      Row {
        visible: root.activeTab === "reports"
        width: parent.width
        height: Style.space(116)
        spacing: Style.space(2)

        Repeater {
          model: root.report.days
          Item {
            required property var modelData
            width: (parent.width - parent.spacing * 6) / 7
            height: parent.height

            Column {
              anchors.fill: parent
              spacing: Style.space(2)
              Text {
                id: dayName
                width: parent.width
                text: root.dayLabel(modelData.date).toUpperCase()
                color: Color.muted
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
                horizontalAlignment: Text.AlignHCenter
              }
              Rectangle {
                width: Style.space(12)
                height: Style.space(72)
                radius: Style.space(3)
                color: Style.normalFillFor(root.panelForeground, Color.accent)
                anchors.horizontalCenter: parent.horizontalCenter

                Repeater {
                  id: daySegments
                  model: modelData.segments || []
                  Rectangle {
                    required property var modelData
                    required property int index
                    width: parent.width
                    height: parent.height * modelData.seconds / root.reportMaxDaySeconds()
                    y: parent.height - height - parent.height
                      * root.daySegmentOffset(daySegments.model, index) / root.reportMaxDaySeconds()
                    color: modelData.color
                  }
                }
              }
              Text {
                id: dayHours
                width: parent.width
                text: root.hoursLabel(modelData.seconds)
                color: root.panelForeground
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.bodySmall
                font.bold: true
                horizontalAlignment: Text.AlignHCenter
              }
            }
          }
        }
      }
      PanelSeparator { visible: root.activeTab === "reports"; width: parent.width }
      PanelSectionHeader {
        visible: root.activeTab === "reports"
        text: "MONTH " + root.localMonth(root.report.month) + " · " + root.hoursLabel(root.report.monthTotalSeconds)
        foreground: root.panelForeground
        fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
      }
      Repeater {
        model: root.activeTab === "reports" ? root.report.monthRows : []
        Column {
          required property var modelData
          width: parent.width
          spacing: Style.space(4)

          Row {
            width: parent.width
            Text {
              width: parent.width - companyHours.implicitWidth - parent.spacing
              text: modelData.name
              color: modelData.color
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
              font.bold: true
              elide: Text.ElideRight
            }
            Text {
              id: companyHours
              text: root.hoursLabel(modelData.seconds)
              color: Color.muted
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
          Rectangle {
            width: parent.width
            height: Style.space(6)
            radius: Style.space(3)
            color: Style.normalFillFor(root.panelForeground, Color.accent)
            Rectangle {
              width: parent.width * modelData.seconds / root.reportMaxSeconds()
              height: parent.height
              radius: parent.radius
              color: modelData.color
            }
          }
        }
      }
      Text {
        visible: root.activeTab === "reports" && root.report.monthRows.length === 0
        text: "No completed time in this month"
        color: Color.muted
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.caption
      }
      Item {
        visible: root.activeTab === "settings"
        width: parent.width
        height: Math.max(companiesHeader.implicitHeight, addCompanyButton.implicitHeight)

        PanelSectionHeader {
          id: companiesHeader
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: "PROJECTS"
          foreground: root.panelForeground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        }

        PanelActionButton {
          id: addCompanyButton
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          iconText: "+"
          tooltipText: "Add company"
          foreground: root.panelForeground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          bordered: true
          onClicked: root.newCompany()
        }
      }
      Repeater {
        model: root.activeTab === "settings" ? root.state.clients : []
        Item {
          required property var modelData
          width: parent.width
          implicitHeight: companyButton.implicitHeight

          Button {
            id: companyButton
            anchors.fill: parent
            text: modelData.name
            leftAlign: true
            selected: root.editingClientId === modelData.id
            foreground: root.panelForeground
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            horizontalPadding: Style.space(28)
            onClicked: root.editCompany(modelData.id)
          }

          Rectangle {
            width: Style.space(8)
            height: width
            radius: width / 2
            color: root.editingClientId === modelData.id
              ? root.resolvedCompanyColor(root.editedCompanyColor()) : modelData.color
            anchors.left: parent.left
            anchors.leftMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
          }
        }
      }
      TextField {
        id: companyName
        visible: root.activeTab === "settings" && root.companyEditorOpen
        width: parent.width
        placeholderText: "Company name"
        onAccepted: root.saveCompany()
      }
      Dropdown {
        id: companyColor
        visible: root.activeTab === "settings" && root.companyEditorOpen
        width: parent.width
        label: "Company color"
        value: "#61afef"
        options: root.themeColorOptions.concat([{ value: "custom", label: "Custom color..." }])
      }
      TextField {
        id: customCompanyColor
        visible: root.activeTab === "settings" && root.companyEditorOpen && companyColor.value === "custom"
        width: parent.width
        placeholderText: "#RRGGBB"
      }
      Button {
        visible: root.activeTab === "settings" && root.companyEditorOpen
        width: parent.width
        text: root.editingClientId ? "Save company" : "Add company"
        active: companyName.text.trim() !== ""
        onClicked: root.saveCompany()
      }
      Button {
        visible: root.activeTab === "settings" && root.companyEditorOpen
        width: parent.width
        text: "Cancel"
        bordered: true
        onClicked: {
          root.companyEditorOpen = false
          root.editingClientId = ""
        }
      }
      Dropdown {
        visible: root.activeTab === "export"
        width: parent.width
        label: "Export period"
        value: root.exportPeriod
        options: [
          { value: "week", label: "Weekly" },
          { value: "month", label: "Monthly" },
          { value: "custom", label: "Custom range" }
        ]
        onChanged: function(value) {
          root.exportPeriod = value
          root.loadExportSummary()
        }
      }
      Item {
        visible: root.activeTab === "export" && root.exportPeriod !== "custom"
        width: parent.width
        height: Math.max(exportBack.implicitHeight, exportRangeText.implicitHeight, exportForward.implicitHeight)

        PanelActionButton {
          id: exportBack
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          iconText: "\uf053"
          tooltipText: root.exportPeriod === "week" ? "Previous week" : "Previous month"
          foreground: root.panelForeground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          bordered: true
          onClicked: root.shiftExportPeriod(-1)
        }
        Text {
          id: exportRangeText
          anchors.left: exportBack.right
          anchors.right: exportForward.left
          anchors.leftMargin: Style.space(10)
          anchors.rightMargin: Style.space(10)
          anchors.verticalCenter: parent.verticalCenter
          text: root.exportRangeLabel()
          color: root.panelForeground
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          horizontalAlignment: Text.AlignHCenter
        }
        PanelActionButton {
          id: exportForward
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          iconText: "\uf054"
          tooltipText: root.exportPeriod === "week" ? "Next week" : "Next month"
          foreground: root.panelForeground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          bordered: true
          onClicked: root.shiftExportPeriod(1)
        }
      }
      Row {
        visible: root.activeTab === "export" && root.exportPeriod === "custom"
        width: parent.width
        spacing: Style.space(8)
        TextField {
          id: exportFrom
          width: (parent.width - parent.spacing) / 2
          placeholderText: "From (YYYY-MM-DD)"
          onAccepted: root.loadExportSummary()
        }
        TextField {
          id: exportTo
          width: (parent.width - parent.spacing) / 2
          placeholderText: "To (YYYY-MM-DD)"
          onAccepted: root.loadExportSummary()
        }
      }
      BorderSurface {
        visible: root.activeTab === "export"
        width: parent.width
        implicitHeight: Style.space(50)
        color: Style.normalFillFor(root.panelForeground, Color.accent)
        borderSpec: Border.controlSpec("normal", root.panelForeground, Color.accent)
        radius: Style.space(4)
        Row {
          anchors.fill: parent
          anchors.leftMargin: Style.space(12)
          anchors.rightMargin: Style.space(12)
          spacing: Style.space(8)
          Text {
            text: root.hoursLabel(root.exportSummary.seconds)
            color: root.panelForeground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.subtitle
            font.bold: true
            anchors.verticalCenter: parent.verticalCenter
          }
          Text {
            text: root.exportSummary.count + (root.exportSummary.count === 1 ? " entry selected" : " entries selected")
            color: Color.muted
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            anchors.verticalCenter: parent.verticalCenter
          }
        }
      }
      PanelSectionHeader {
        visible: root.activeTab === "export" && root.exportSummary.rows.length > 0
        text: "COMPANIES"
        foreground: root.panelForeground
        fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
      }
      Repeater {
        model: root.activeTab === "export" ? root.exportSummary.rows : []
        Row {
          required property var modelData
          width: parent.width
          spacing: Style.space(7)
          Rectangle {
            width: Style.space(7)
            height: width
            radius: width / 2
            color: modelData.color
            anchors.verticalCenter: parent.verticalCenter
          }
          Text {
            width: parent.width - parent.children[0].width - companyTotal.implicitWidth - 2 * parent.spacing
            text: modelData.name
            color: root.panelForeground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }
          Text {
            id: companyTotal
            text: root.hoursLabel(modelData.seconds)
            color: Color.muted
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }
      Text {
        visible: root.activeTab === "export" && root.exportSummary.rows.length === 0
        text: "No time in this range"
        color: Color.muted
        font.pixelSize: Style.font.caption
      }
      Button {
        visible: root.activeTab === "export" && root.exportSummary.count > 0
        width: parent.width
        text: "Export CSV"
        bordered: true
        onClicked: {
          var range = root.exportRange()
          root.run(["export", "--out", root.exportFileName(), "--from", range.from, "--to", range.to])
        }
      }
      Text { visible: root.errorText !== "" || root.exportText !== ""; text: root.errorText || root.exportText; color: root.errorText ? Color.urgent : Color.accent; font.pixelSize: Style.font.caption; wrapMode: Text.Wrap; width: parent.width }
    }
  }
}
