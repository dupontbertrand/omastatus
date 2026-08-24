import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string configDirectory: Quickshell.env("OMASTATUS_CONFIG_DIR")
    || (root.home + "/.config/omastatus")
  readonly property string configPath: root.configDirectory + "/config.json"
  readonly property string pluginDirectory: Qt.resolvedUrl(".").toString()
    .replace(/^file:\/\//, "").replace(/\/$/, "")
  readonly property string cliPath: root.pluginDirectory + "/bin/omastatus"

  property var configData: ({
    settings: {
      intervalSeconds: 30,
      timeoutSeconds: 4,
      failureThreshold: 1,
      notifications: true,
      viewMode: "grouped"
    },
    categories: [],
    services: []
  })
  property var results: []
  property var summary: ({
    total: 0,
    up: 0,
    down: 0,
    degraded: 0,
    unknown: 0,
    disabled: 0,
    overall: "unknown"
  })
  property int resultsRevision: 0
  property string configError: ""
  property string checkError: ""
  property string checkOutput: ""
  property bool rerunRequested: false
  property bool initialized: false
  property bool cachedStateLoaded: false
  property string probeSignature: ""

  readonly property bool checking: checkProcess.running
  readonly property int intervalSeconds: {
    var settings = root.configData && root.configData.settings
      ? root.configData.settings : {}
    return Math.max(5, Number(settings.intervalSeconds || 30))
  }
  readonly property bool notificationsEnabled: {
    var settings = root.configData && root.configData.settings
      ? root.configData.settings : {}
    return settings.notifications !== false
  }

  function safeArray(value) {
    return Array.isArray(value) ? value : []
  }

  function parseConfig(raw) {
    try {
      var parsed = JSON.parse(String(raw || ""))
      if (!parsed || typeof parsed !== "object") throw new Error("invalid root object")
      parsed.settings = parsed.settings && typeof parsed.settings === "object" ? parsed.settings : {}
      parsed.categories = root.safeArray(parsed.categories)
      parsed.services = root.safeArray(parsed.services)
      var probes = []
      for (var i = 0; i < parsed.services.length; i++) {
        var service = parsed.services[i]
        probes.push({
          id: service.id,
          target: service.target,
          type: service.type,
          enabled: service.enabled,
          timeoutSeconds: service.timeoutSeconds
        })
      }
      var signature = JSON.stringify({
        services: probes,
        failureThreshold: parsed.settings.failureThreshold
      })
      var probesChanged = signature !== root.probeSignature
      root.probeSignature = signature
      root.configData = parsed
      root.reconcileResults(parsed)
      root.configError = ""
      if (root.initialized && root.cachedStateLoaded && probesChanged) root.checkAllNow()
    } catch (error) {
      root.configError = "Invalid Omastatus configuration: " + String(error)
      console.warn("omastatus: config parse failed", String(error))
    }
  }

  function rowsById(rows) {
    var indexed = {}
    for (var i = 0; i < rows.length; i++) indexed[String(rows[i].id || "")] = rows[i]
    return indexed
  }

  function categoryName(config, categoryId) {
    var categories = config && Array.isArray(config.categories) ? config.categories : []
    for (var i = 0; i < categories.length; i++) {
      if (String(categories[i].id || "") === String(categoryId || ""))
        return String(categories[i].name || "Uncategorised")
    }
    return "Uncategorised"
  }

  function summarizeRows(rows) {
    var counts = {
      total: 0,
      up: 0,
      down: 0,
      degraded: 0,
      unknown: 0,
      disabled: 0,
      overall: "unknown"
    }
    for (var i = 0; i < rows.length; i++) {
      var status = String(rows[i].status || "unknown")
      if (status === "disabled") {
        counts.disabled++
      } else {
        counts.total++
        if (counts.hasOwnProperty(status)) counts[status]++
        else counts.unknown++
      }
    }
    if (counts.down > 0) counts.overall = "down"
    else if (counts.degraded > 0) counts.overall = "degraded"
    else if (counts.total > 0 && counts.up === counts.total) counts.overall = "up"
    return counts
  }

  function reconcileResults(config) {
    var previous = root.rowsById(root.results)
    var services = config && Array.isArray(config.services) ? config.services : []
    var next = []
    for (var i = 0; i < services.length; i++) {
      var service = services[i]
      var old = previous[String(service.id || "")]
      var row = {}
      if (old) for (var key in old) row[key] = old[key]
      row.id = service.id
      row.name = service.name
      row.target = service.target
      row.type = service.type
      row.categoryId = String(service.categoryId || "")
      row.categoryName = root.categoryName(config, row.categoryId)
      row.enabled = service.enabled !== false
      if (!row.enabled) {
        row.status = "disabled"
        row.message = "Disabled"
      } else if (!old || old.status === "disabled") {
        row.status = "unknown"
        row.message = "Waiting for first check"
        row.checkedAt = 0
        row.latencyMs = 0
      }
      next.push(row)
    }
    root.results = next
    root.summary = root.summarizeRows(next)
    root.resultsRevision++
  }

  function notify(title, detail, urgency, glyph) {
    Quickshell.execDetached([
      "omarchy-notification-send",
      "--app-name", "omastatus",
      "--urgency", urgency,
      "--glyph", glyph,
      title,
      detail
    ])
  }

  function announceTransitions(previousRows, nextRows) {
    if (!root.notificationsEnabled) return
    var previous = root.rowsById(previousRows)
    for (var i = 0; i < nextRows.length; i++) {
      var row = nextRows[i]
      var old = previous[String(row.id || "")]
      if (row.status === "down" && (!old || old.status !== "down")) {
        root.notify(row.name + " is down", row.message || row.target, "critical", "󰅚")
      } else if (row.status === "up" && old && old.status === "down") {
        root.notify(row.name + " recovered", row.message || row.target, "normal", "󰄬")
      }
    }
  }

  function applyState(raw, announce) {
    try {
      var parsed = JSON.parse(String(raw || ""))
      if (!parsed || typeof parsed !== "object" || !Array.isArray(parsed.services))
        throw new Error("invalid state object")
      var previous = root.results
      // A configuration edit can land while a check using the previous
      // snapshot is still running. Reconcile first so removed, paused, or
      // retargeted services cannot publish a stale transition notification.
      root.results = parsed.services
      root.reconcileResults(root.configData)
      if (announce) root.announceTransitions(previous, root.results)
      root.checkError = ""
    } catch (error) {
      root.checkError = "The checker returned invalid data."
      console.warn("omastatus: state parse failed", String(error))
    }
  }

  function reloadConfig() {
    configFile.reload()
  }

  function loadCachedState() {
    if (!statusProcess.running) statusProcess.running = true
  }

  function checkAllNow() {
    if (!root.initialized) return
    if (checkProcess.running) {
      root.rerunRequested = true
      return
    }
    root.rerunRequested = false
    root.checkOutput = ""
    root.checkError = ""
    checkProcess.running = true
  }

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    onLoaded: root.parseConfig(text())
    onLoadFailed: function(_error) {
      if (root.initialized) root.configError = "Could not load " + root.configPath
    }
    onFileChanged: reload()
  }

  Process {
    id: initProcess
    command: [root.cliPath, "init"]
    running: true
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (String(text || "").trim()) root.configError = String(text).trim()
      }
    }
    onExited: function(exitCode) {
      root.initialized = exitCode === 0
      if (exitCode !== 0) {
        if (!root.configError) root.configError = "Omastatus could not initialise its configuration."
        return
      }
      configFile.reload()
      root.loadCachedState()
    }
  }

  Process {
    id: statusProcess
    command: [root.cliPath, "status"]
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyState(text, false)
    }
    onExited: function(_exitCode) {
      root.cachedStateLoaded = true
      Qt.callLater(root.checkAllNow)
    }
  }

  Process {
    id: checkProcess
    command: [root.cliPath, "check"]
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.checkOutput = String(text || "").trim()
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.checkError = String(text || "").trim()
    }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.applyState(root.checkOutput, true)
      } else if (!root.checkError) {
        root.checkError = "Health check failed."
      }
      if (root.rerunRequested) Qt.callLater(root.checkAllNow)
    }
  }

  Timer {
    interval: root.intervalSeconds * 1000
    running: root.initialized
    repeat: true
    triggeredOnStart: false
    onTriggered: root.checkAllNow()
  }
}
