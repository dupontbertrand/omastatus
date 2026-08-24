import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root

  moduleName: "io.github.dupontbertrand.omastatus"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null

  readonly property var monitorService: bar && bar.shell
    ? bar.shell.serviceFor(root.moduleName)
    : null
  readonly property var configData: monitorService ? monitorService.configData : ({})
  readonly property var settings: configData && configData.settings ? configData.settings : ({})
  readonly property var categories: configData && Array.isArray(configData.categories)
    ? configData.categories : []
  readonly property var configuredServices: configData && Array.isArray(configData.services)
    ? configData.services : []
  readonly property var rows: monitorService && Array.isArray(monitorService.results)
    ? monitorService.results : []
  readonly property var summary: monitorService ? monitorService.summary : ({})
  readonly property string viewMode: String(settings.viewMode || "grouped")
  readonly property bool checking: monitorService ? monitorService.checking : false
  readonly property color foreground: bar ? bar.barForeground : Color.foreground
  // Service failures must remain red even when the active theme remaps the
  // shell's generic urgent colour to a different accent.
  readonly property color urgent: "#ef5f6b"
  readonly property color healthy: "#59d98e"
  readonly property color dim: Qt.darker(root.foreground, 1.45)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string pluginDirectory: Qt.resolvedUrl(".").toString()
    .replace(/^file:\/\//, "").replace(/\/$/, "")
  readonly property string cliPath: root.pluginDirectory + "/bin/omastatus"

  property string screen: "dashboard"
  property string filterCategory: "all"
  property string addName: ""
  property string addTarget: ""
  property string addType: "auto"
  property string addCategory: ""
  property string newCategoryName: ""
  property string mutationAction: ""
  property string mutationError: ""
  property string pendingServiceDelete: ""
  property string pendingCategoryDelete: ""
  property double now: Date.now()

  readonly property var examplePresets: [
    { label: "WEBSITE", name: "Website", target: "https://example.com/", type: "http" },
    { label: "DOCKER", name: "Docker container", target: "docker://my-container", type: "docker" },
    { label: "K8S", name: "Kubernetes deployment", target: "k8s://default/deployment/my-api", type: "kubernetes" },
    { label: "POSTGRES", name: "PostgreSQL", target: "postgres://localhost", type: "tcp" },
    { label: "SYSTEMD", name: "Worker service", target: "systemd://user/my-worker.service", type: "systemd" }
  ]

  readonly property var filteredRows: root.buildFilteredRows()
  readonly property var groupedRows: root.buildGroups()

  function open() {
    root.controller.show()
  }

  function close() {
    root.screen = "dashboard"
    root.pendingServiceDelete = ""
    root.pendingCategoryDelete = ""
    root.mutationError = ""
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.hostWidget || root, direction)
    return false
  }

  function safeArray(value) {
    return Array.isArray(value) ? value : []
  }

  function categoryName(categoryId) {
    for (var i = 0; i < root.categories.length; i++) {
      if (root.categories[i].id === categoryId) return root.categories[i].name
    }
    return "Uncategorised"
  }

  function filterChoices() {
    var values = [{ id: "all", name: "All" }, { id: "", name: "Uncategorised" }]
    for (var i = 0; i < root.categories.length; i++) values.push(root.categories[i])
    return values
  }

  function buildFilteredRows() {
    var out = []
    for (var i = 0; i < root.rows.length; i++) {
      var row = root.rows[i]
      if (root.filterCategory === "all" || String(row.categoryId || "") === root.filterCategory)
        out.push(row)
    }
    return out
  }

  function buildGroups() {
    var groups = []
    var ids = []
    for (var i = 0; i < root.filteredRows.length; i++) {
      var row = root.filteredRows[i]
      var id = String(row.categoryId || "")
      var index = ids.indexOf(id)
      if (index === -1) {
        ids.push(id)
        groups.push({ id: id, name: root.categoryName(id), rows: [row] })
      } else {
        groups[index].rows.push(row)
      }
    }
    return groups
  }

  function statusColor(status) {
    if (status === "up") return root.healthy
    if (status === "down") return root.urgent
    if (status === "degraded" || status === "checking") return Color.accent
    return root.dim
  }

  function statusLabel(status) {
    if (status === "up") return "UP"
    if (status === "down") return "DOWN"
    if (status === "degraded") return "UNSTABLE"
    if (status === "disabled") return "PAUSED"
    return "WAITING"
  }

  function resultDetail(row) {
    var parts = []
    if (Number(row.latencyMs || 0) > 0) parts.push(Number(row.latencyMs) + " ms")
    if (row.message) parts.push(String(row.message))
    return parts.length > 0 ? parts.join(" · ") : "No result yet"
  }

  function relativeTime(timestamp) {
    var value = Number(timestamp || 0)
    if (!value) return "never"
    var seconds = Math.max(0, Math.floor((root.now - value) / 1000))
    if (seconds < 5) return "now"
    if (seconds < 60) return seconds + "s"
    var minutes = Math.floor(seconds / 60)
    if (minutes < 60) return minutes + "m"
    return Math.floor(minutes / 60) + "h"
  }

  function headline() {
    var total = Number(root.summary.total || 0)
    var up = Number(root.summary.up || 0)
    var down = Number(root.summary.down || 0)
    var degraded = Number(root.summary.degraded || 0)
    var unknown = Number(root.summary.unknown || 0)
    var disabled = Number(root.summary.disabled || 0)
    if (total === 0) return "No service configured"
    var parts = []
    if (up > 0) parts.push(up + " up")
    if (down > 0) parts.push(down + " down")
    if (degraded > 0) parts.push(degraded + " unstable")
    if (unknown > 0) parts.push(unknown + " waiting")
    if (disabled > 0) parts.push(disabled + " paused")
    parts.push(total + " total")
    return parts.join(" · ")
  }

  function typeHint() {
    if (root.addType === "http") return "https://example.com/health"
    if (root.addType === "tcp") return "localhost:5432 or redis://localhost"
    if (root.addType === "ping") return "server.local or 192.168.1.10"
    if (root.addType === "systemd") return "nginx.service or systemd://user/my-app.service"
    if (root.addType === "docker") return "docker://container-name"
    if (root.addType === "kubernetes") return "k8s://namespace/kind/name"
    return "URL, host:port, DB URI, hostname, service, Docker, or Kubernetes"
  }

  function applyExample(example) {
    root.addName = String(example.name || "")
    root.addTarget = String(example.target || "")
    root.addType = String(example.type || "auto")
  }

  function runMutation(arguments, action) {
    if (mutationProcess.running) return
    root.mutationError = ""
    root.mutationAction = action
    mutationProcess.command = [root.cliPath].concat(arguments)
    mutationProcess.running = true
  }

  function addService() {
    if (!root.addName.trim() || !root.addTarget.trim()) {
      root.mutationError = "Name and target are required."
      return
    }
    var args = [
      "add",
      "--name", root.addName.trim(),
      "--target", root.addTarget.trim(),
      "--type", root.addType
    ]
    if (root.addCategory) args = args.concat(["--category", root.addCategory])
    root.runMutation(args, "addService")
  }

  function addNewCategory() {
    if (!root.newCategoryName.trim()) {
      root.mutationError = "Category name is required."
      return
    }
    root.runMutation(["add-category", root.newCategoryName.trim()], "addCategory")
  }

  function requestServiceRemoval(id) {
    if (root.pendingServiceDelete !== id) {
      root.pendingServiceDelete = id
      return
    }
    root.runMutation(["remove", id], "removeService")
  }

  function requestCategoryRemoval(id) {
    if (root.pendingCategoryDelete !== id) {
      root.pendingCategoryDelete = id
      return
    }
    root.runMutation(["remove-category", id], "removeCategory")
  }

  function nextCategoryId(currentId) {
    var ids = [""]
    for (var i = 0; i < root.categories.length; i++) ids.push(root.categories[i].id)
    var index = ids.indexOf(String(currentId || ""))
    return ids[(index + 1) % ids.length]
  }

  function cycleCategory(service) {
    root.runMutation(
      ["set-category", service.id, root.nextCategoryId(service.categoryId)],
      "setCategory"
    )
  }

  onOpenedChanged: if (root.opened) {
    root.now = Date.now()
    if (root.monitorService) root.monitorService.reloadConfig()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  onCategoriesChanged: {
    if (root.filterCategory !== "all" && root.filterCategory !== "") {
      var found = false
      for (var i = 0; i < root.categories.length; i++)
        if (root.categories[i].id === root.filterCategory) found = true
      if (!found) root.filterCategory = "all"
    }
  }

  Process {
    id: mutationProcess
    running: false
    command: []
    property string errorText: ""

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: mutationProcess.errorText = String(text || "").trim()
    }

    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.mutationError = mutationProcess.errorText || "The action failed."
      } else {
        root.mutationError = ""
        if (root.mutationAction === "addService") {
          root.addName = ""
          root.addTarget = ""
          root.addType = "auto"
          root.addCategory = ""
          root.screen = "dashboard"
        } else if (root.mutationAction === "addCategory") {
          root.newCategoryName = ""
        } else if (root.mutationAction === "removeService") {
          root.pendingServiceDelete = ""
        } else if (root.mutationAction === "removeCategory") {
          root.pendingCategoryDelete = ""
        }
        if (root.monitorService) root.monitorService.reloadConfig()
      }
      root.mutationAction = ""
      mutationProcess.errorText = ""
    }
  }

  Timer {
    interval: 1000
    running: root.opened
    repeat: true
    onTriggered: root.now = Date.now()
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(470))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight, Style.space(650))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: contentColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: contentColumn
          width: parent.width
          spacing: Style.space(10)

          Row {
            width: parent.width
            spacing: Style.space(10)

            Rectangle {
              width: Style.space(12)
              height: width
              radius: width / 2
              anchors.verticalCenter: parent.verticalCenter
              color: root.checking ? Color.accent
                : Number(root.summary.down || 0) > 0 ? root.urgent
                : String(root.summary.overall || "unknown") === "up" ? root.healthy
                : root.dim
            }

            Column {
              width: parent.width - headerActions.implicitWidth - Style.space(32)
              spacing: Style.space(2)

              Text {
                width: parent.width
                text: root.screen === "dashboard" ? "Omastatus"
                  : root.screen === "add" ? "Add a service"
                  : root.screen === "manage" ? "Manage services"
                  : "Categories & polling"
                textFormat: Text.PlainText
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
                font.bold: true
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                text: root.headline()
                textFormat: Text.PlainText
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }

            Row {
              id: headerActions
              spacing: Style.space(5)

              Button {
                visible: root.screen === "dashboard"
                iconText: "+"
                tooltipText: "Add a service"
                foreground: root.foreground
                accent: Color.accent
                fontFamily: root.fontFamily
                onClicked: root.screen = "add"
              }

              Button {
                visible: root.screen === "dashboard"
                iconText: "󰑐"
                iconSpinning: root.checking
                enabled: !root.checking
                tooltipText: "Check everything now"
                foreground: root.foreground
                accent: Color.accent
                fontFamily: root.fontFamily
                onClicked: if (root.monitorService) root.monitorService.checkAllNow()
              }

              Button {
                visible: root.screen !== "dashboard"
                text: "BACK"
                foreground: root.foreground
                accent: Color.accent
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                onClicked: {
                  root.screen = "dashboard"
                  root.mutationError = ""
                }
              }
            }
          }

          Text {
            visible: root.monitorService && root.monitorService.configError !== ""
            width: parent.width
            text: root.monitorService ? root.monitorService.configError : ""
            textFormat: Text.PlainText
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
            visible: root.monitorService && root.monitorService.checkError !== ""
            width: parent.width
            text: root.monitorService ? root.monitorService.checkError : ""
            textFormat: Text.PlainText
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
            visible: root.mutationError !== ""
            width: parent.width
            text: root.mutationError
            textFormat: Text.PlainText
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          PanelSeparator {
            width: parent.width
            foreground: root.foreground
          }

          // Dashboard -----------------------------------------------------
          Column {
            visible: root.screen === "dashboard"
            width: parent.width
            spacing: Style.space(9)

            Flow {
              width: parent.width
              spacing: Style.space(6)

              Button {
                text: "SERVICES"
                tooltipText: "Pause, categorise, or remove services"
                foreground: root.foreground
                accent: Color.accent
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                onClicked: root.screen = "manage"
              }

              Button {
                text: "CATEGORIES"
                tooltipText: "Create categories and change polling"
                foreground: root.foreground
                accent: Color.accent
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                onClicked: root.screen = "categories"
              }
            }

            Flow {
              width: parent.width
              spacing: Style.space(5)

              Repeater {
                model: root.filterChoices()

                Button {
                  required property var modelData
                  text: String(modelData.name).toUpperCase()
                  bordered: root.filterCategory === modelData.id
                  foreground: root.foreground
                  accent: Color.accent
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  horizontalPadding: Style.space(7)
                  verticalPadding: Style.space(3)
                  onClicked: root.filterCategory = modelData.id
                }
              }
            }

            Row {
              width: parent.width
              spacing: Style.space(6)

              Text {
                width: parent.width - viewButtons.implicitWidth - Style.space(6)
                text: "Panel view"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.verticalCenter: parent.verticalCenter
              }

              Row {
                id: viewButtons
                spacing: Style.space(4)

                Repeater {
                  model: [
                    { id: "grouped", label: "GROUP" },
                    { id: "compact", label: "LIST" },
                    { id: "grid", label: "GRID" }
                  ]

                  Button {
                    required property var modelData
                    text: modelData.label
                    bordered: root.viewMode === modelData.id
                    enabled: !mutationProcess.running
                    foreground: root.foreground
                    accent: Color.accent
                    fontFamily: root.fontFamily
                    fontSize: Style.font.caption
                    horizontalPadding: Style.space(6)
                    verticalPadding: Style.space(3)
                    onClicked: root.runMutation(["set-view", modelData.id], "setView")
                  }
                }
              }
            }

            PanelSeparator {
              width: parent.width
              foreground: root.foreground
              strength: 0.08
            }

            // Grouped view
            Column {
              visible: root.viewMode === "grouped"
              width: parent.width
              spacing: Style.space(10)

              Repeater {
                model: root.groupedRows

                Column {
                  id: groupBlock
                  required property var modelData
                  width: parent ? parent.width : 0
                  spacing: Style.space(5)

                  Text {
                    width: parent.width
                    text: groupBlock.modelData.name.toUpperCase()
                      + " · " + groupBlock.modelData.rows.length
                    textFormat: Text.PlainText
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    elide: Text.ElideRight
                  }

                  Repeater {
                    model: groupBlock.modelData.rows

                    Rectangle {
                      id: detailedRow
                      required property var modelData
                      width: groupBlock.width
                      height: detailedContent.implicitHeight + Style.space(14)
                      radius: Style.cornerRadius
                      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.045)

                      Row {
                        id: detailedContent
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.margins: Style.space(8)
                        spacing: Style.space(9)

                        Rectangle {
                          width: Style.space(9)
                          height: width
                          radius: width / 2
                          anchors.verticalCenter: parent.verticalCenter
                          color: root.statusColor(detailedRow.modelData.status)
                        }

                        Column {
                          width: parent.width - detailedStatus.implicitWidth - Style.space(26)
                          spacing: Style.space(2)

                          Text {
                            width: parent.width
                            text: detailedRow.modelData.name
                            textFormat: Text.PlainText
                            color: root.foreground
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.body
                            font.bold: true
                            elide: Text.ElideRight
                          }

                          Text {
                            width: parent.width
                            text: root.resultDetail(detailedRow.modelData)
                            textFormat: Text.PlainText
                            color: detailedRow.modelData.status === "down" ? root.urgent : root.dim
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                            elide: Text.ElideRight
                          }

                          Text {
                            width: parent.width
                            text: String(detailedRow.modelData.target || "")
                            textFormat: Text.PlainText
                            color: Qt.darker(root.dim, 1.15)
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                            elide: Text.ElideMiddle
                          }
                        }

                        Column {
                          id: detailedStatus
                          anchors.verticalCenter: parent.verticalCenter
                          spacing: Style.space(2)

                          Text {
                            text: root.statusLabel(detailedRow.modelData.status)
                            color: root.statusColor(detailedRow.modelData.status)
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                            font.bold: true
                            horizontalAlignment: Text.AlignRight
                          }

                          Text {
                            text: root.relativeTime(detailedRow.modelData.checkedAt)
                            color: root.dim
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                            horizontalAlignment: Text.AlignRight
                          }
                        }
                      }
                    }
                  }
                }
              }
            }

            // Compact list view
            Column {
              visible: root.viewMode === "compact"
              width: parent.width
              spacing: Style.space(4)

              Repeater {
                model: root.filteredRows

                Rectangle {
                  id: compactRow
                  required property var modelData
                  width: parent ? parent.width : 0
                  height: Style.space(34)
                  radius: Style.cornerRadius
                  color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.04)

                  Row {
                    anchors.fill: parent
                    anchors.leftMargin: Style.space(8)
                    anchors.rightMargin: Style.space(8)
                    spacing: Style.space(8)

                    Rectangle {
                      width: Style.space(8)
                      height: width
                      radius: width / 2
                      anchors.verticalCenter: parent.verticalCenter
                      color: root.statusColor(compactRow.modelData.status)
                    }

                    Text {
                      width: parent.width - compactMeta.implicitWidth - Style.space(25)
                      anchors.verticalCenter: parent.verticalCenter
                      text: compactRow.modelData.name
                      textFormat: Text.PlainText
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      elide: Text.ElideRight
                    }

                    Text {
                      id: compactMeta
                      anchors.verticalCenter: parent.verticalCenter
                      text: root.statusLabel(compactRow.modelData.status)
                        + (Number(compactRow.modelData.latencyMs || 0) > 0
                          ? " · " + Number(compactRow.modelData.latencyMs) + " ms" : "")
                      color: root.statusColor(compactRow.modelData.status)
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }
                }
              }
            }

            // Two-column grid view
            Flow {
              id: gridRows
              visible: root.viewMode === "grid"
              width: parent.width
              spacing: Style.space(7)

              Repeater {
                model: root.filteredRows

                Rectangle {
                  id: gridCard
                  required property var modelData
                  width: (gridRows.width - gridRows.spacing) / 2
                  height: gridContent.implicitHeight + Style.space(16)
                  radius: Style.cornerRadius
                  color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.045)

                  Column {
                    id: gridContent
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.margins: Style.space(8)
                    spacing: Style.space(4)

                    Row {
                      width: parent.width
                      spacing: Style.space(7)

                      Rectangle {
                        width: Style.space(9)
                        height: width
                        radius: width / 2
                        anchors.verticalCenter: parent.verticalCenter
                        color: root.statusColor(gridCard.modelData.status)
                      }

                      Text {
                        width: parent.width - Style.space(18)
                        text: gridCard.modelData.name
                        textFormat: Text.PlainText
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                        font.bold: true
                        elide: Text.ElideRight
                      }
                    }

                    Text {
                      width: parent.width
                      text: root.statusLabel(gridCard.modelData.status)
                        + (Number(gridCard.modelData.latencyMs || 0) > 0
                          ? " · " + Number(gridCard.modelData.latencyMs) + " ms" : "")
                      color: root.statusColor(gridCard.modelData.status)
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                    }

                    Text {
                      width: parent.width
                      text: String(gridCard.modelData.target || "")
                      textFormat: Text.PlainText
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideMiddle
                    }
                  }
                }
              }
            }

            Text {
              visible: root.filteredRows.length === 0
              width: parent.width
              text: root.rows.length === 0
                ? "No services yet. Use + to add a URL, port, host, database, or systemd unit."
                : "No service in this category."
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
              topPadding: Style.space(24)
              bottomPadding: Style.space(24)
            }

            Text {
              width: parent.width
              text: "Checks every " + Number(root.settings.intervalSeconds || 30)
                + " seconds · right-click the bar dot to check now"
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
            }
          }

          // Add service ---------------------------------------------------
          Column {
            visible: root.screen === "add"
            width: parent.width
            spacing: Style.space(9)

            Text {
              width: parent.width
              text: "Auto recognises web URLs, host:port, database URIs, hostnames, *.service units, docker:// containers, and k8s:// resources. Credentials are never accepted or stored."
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Text {
              width: parent.width
              text: "EXAMPLES — CLICK TO PREFILL"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            Flow {
              width: parent.width
              spacing: Style.space(5)

              Repeater {
                model: root.examplePresets

                Button {
                  required property var modelData
                  text: modelData.label
                  foreground: root.foreground
                  accent: Color.accent
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  horizontalPadding: Style.space(7)
                  verticalPadding: Style.space(3)
                  onClicked: root.applyExample(modelData)
                }
              }
            }

            TextField {
              width: parent.width
              placeholderText: "Service name"
              text: root.addName
              foreground: root.foreground
              accent: Color.accent
              onTextEdited: root.addName = text
            }

            TextField {
              width: parent.width
              placeholderText: root.typeHint()
              text: root.addTarget
              foreground: root.foreground
              accent: Color.accent
              onTextEdited: root.addTarget = text
              onAccepted: root.addService()
            }

            Text {
              width: parent.width
              text: "CHECK TYPE"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            Flow {
              width: parent.width
              spacing: Style.space(5)

              Repeater {
                model: ["auto", "http", "tcp", "ping", "systemd", "docker", "kubernetes"]

                Button {
                  required property string modelData
                  text: modelData === "kubernetes" ? "K8S" : modelData.toUpperCase()
                  bordered: root.addType === modelData
                  foreground: root.foreground
                  accent: Color.accent
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  horizontalPadding: Style.space(7)
                  verticalPadding: Style.space(3)
                  onClicked: root.addType = modelData
                }
              }
            }

            Text {
              width: parent.width
              text: "CATEGORY"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            Flow {
              width: parent.width
              spacing: Style.space(5)

              Button {
                text: "NONE"
                bordered: root.addCategory === ""
                foreground: root.foreground
                accent: Color.accent
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                onClicked: root.addCategory = ""
              }

              Repeater {
                model: root.categories

                Button {
                  required property var modelData
                  text: String(modelData.name).toUpperCase()
                  bordered: root.addCategory === modelData.id
                  foreground: root.foreground
                  accent: Color.accent
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  onClicked: root.addCategory = modelData.id
                }
              }
            }

            Row {
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(7)
              topPadding: Style.space(5)

              Button {
                text: mutationProcess.running && root.mutationAction === "addService"
                  ? "ADDING…" : "ADD SERVICE"
                enabled: !mutationProcess.running
                  && root.addName.trim().length > 0
                  && root.addTarget.trim().length > 0
                bordered: true
                foreground: root.foreground
                accent: Color.accent
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                onClicked: root.addService()
              }

              Button {
                text: "CATEGORIES"
                enabled: !mutationProcess.running
                foreground: root.foreground
                accent: Color.accent
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                onClicked: root.screen = "categories"
              }
            }
          }

          // Manage services -----------------------------------------------
          Column {
            visible: root.screen === "manage"
            width: parent.width
            spacing: Style.space(7)

            Text {
              width: parent.width
              text: "Click a category to move a service to the next one. Removing a service needs two clicks."
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Repeater {
              model: root.configuredServices

              Rectangle {
                id: manageRow
                required property var modelData
                width: parent ? parent.width : 0
                height: Math.max(manageName.implicitHeight, manageActions.implicitHeight) + Style.space(14)
                radius: Style.cornerRadius
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.045)

                Column {
                  id: manageName
                  anchors.left: parent.left
                  anchors.right: manageActions.left
                  anchors.leftMargin: Style.space(8)
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(2)

                  Text {
                    width: parent.width
                    text: manageRow.modelData.name
                    textFormat: Text.PlainText
                    color: manageRow.modelData.enabled ? root.foreground : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                    elide: Text.ElideRight
                  }

                  Text {
                    width: parent.width
                    text: String(manageRow.modelData.target || "")
                    textFormat: Text.PlainText
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideMiddle
                  }
                }

                Row {
                  id: manageActions
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(7)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(4)

                  Button {
                    text: root.categoryName(manageRow.modelData.categoryId).toUpperCase()
                    tooltipText: "Move to the next category"
                    enabled: !mutationProcess.running
                    foreground: root.foreground
                    accent: Color.accent
                    fontFamily: root.fontFamily
                    fontSize: Style.font.caption
                    horizontalPadding: Style.space(6)
                    verticalPadding: Style.space(3)
                    onClicked: root.cycleCategory(manageRow.modelData)
                  }

                  Button {
                    text: manageRow.modelData.enabled ? "ON" : "OFF"
                    bordered: manageRow.modelData.enabled
                    enabled: !mutationProcess.running
                    tooltipText: manageRow.modelData.enabled ? "Pause checks" : "Resume checks"
                    foreground: root.foreground
                    accent: Color.accent
                    fontFamily: root.fontFamily
                    fontSize: Style.font.caption
                    onClicked: root.runMutation(["toggle", manageRow.modelData.id], "toggleService")
                  }

                  Button {
                    text: root.pendingServiceDelete === manageRow.modelData.id ? "CONFIRM" : "REMOVE"
                    enabled: !mutationProcess.running
                    tooltipText: "Remove this service"
                    foreground: root.pendingServiceDelete === manageRow.modelData.id ? root.urgent : root.foreground
                    accent: root.urgent
                    fontFamily: root.fontFamily
                    fontSize: Style.font.caption
                    onClicked: root.requestServiceRemoval(manageRow.modelData.id)
                  }
                }
              }
            }

            Text {
              visible: root.configuredServices.length === 0
              width: parent.width
              text: "No services configured."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
              topPadding: Style.space(20)
              bottomPadding: Style.space(20)
            }
          }

          // Categories and polling ----------------------------------------
          Column {
            visible: root.screen === "categories"
            width: parent.width
            spacing: Style.space(9)

            Text {
              width: parent.width
              text: "Create categories, then assign them while adding a service or from Manage services. Removing a category keeps its services as uncategorised."
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Row {
              width: parent.width
              spacing: Style.space(6)

              TextField {
                width: parent.width - addCategoryButton.implicitWidth - Style.space(6)
                placeholderText: "New category name"
                text: root.newCategoryName
                foreground: root.foreground
                accent: Color.accent
                onTextEdited: root.newCategoryName = text
                onAccepted: root.addNewCategory()
              }

              Button {
                id: addCategoryButton
                text: "ADD"
                enabled: !mutationProcess.running && root.newCategoryName.trim().length > 0
                bordered: true
                foreground: root.foreground
                accent: Color.accent
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                onClicked: root.addNewCategory()
              }
            }

            Repeater {
              model: root.categories

              Rectangle {
                id: categoryRow
                required property var modelData
                width: parent ? parent.width : 0
                height: Math.max(categoryText.implicitHeight, categoryRemove.implicitHeight) + Style.space(12)
                radius: Style.cornerRadius
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.045)

                Text {
                  id: categoryText
                  anchors.left: parent.left
                  anchors.right: categoryRemove.left
                  anchors.leftMargin: Style.space(9)
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  text: categoryRow.modelData.name
                  textFormat: Text.PlainText
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }

                Button {
                  id: categoryRemove
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(6)
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.pendingCategoryDelete === categoryRow.modelData.id ? "CONFIRM" : "REMOVE"
                  enabled: !mutationProcess.running
                  foreground: root.pendingCategoryDelete === categoryRow.modelData.id ? root.urgent : root.foreground
                  accent: root.urgent
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  onClicked: root.requestCategoryRemoval(categoryRow.modelData.id)
                }
              }
            }

            Text {
              visible: root.categories.length === 0
              width: parent.width
              text: "No categories yet."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
              topPadding: Style.space(12)
              bottomPadding: Style.space(12)
            }

            PanelSeparator {
              width: parent.width
              foreground: root.foreground
              strength: 0.08
            }

            Text {
              width: parent.width
              text: "CHECK INTERVAL"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            Flow {
              width: parent.width
              spacing: Style.space(5)

              Repeater {
                model: [15, 30, 60, 120, 300]

                Button {
                  required property int modelData
                  text: modelData < 60 ? modelData + " SEC" : (modelData / 60) + " MIN"
                  bordered: Number(root.settings.intervalSeconds || 30) === modelData
                  enabled: !mutationProcess.running
                  foreground: root.foreground
                  accent: Color.accent
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  onClicked: root.runMutation(["set-interval", String(modelData)], "setInterval")
                }
              }
            }
          }
        }
      }
    }
  }
}
