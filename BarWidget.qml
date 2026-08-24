import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root

  moduleName: "io.github.dupontbertrand.omastatus"

  readonly property var monitorService: bar && bar.shell
    ? bar.shell.serviceFor(root.moduleName)
    : null
  readonly property var summary: monitorService ? monitorService.summary : ({})
  readonly property string overall: String(summary.overall || "unknown")
  readonly property int totalCount: Number(summary.total || 0)
  readonly property int downCount: Number(summary.down || 0)
  readonly property int degradedCount: Number(summary.degraded || 0)
  readonly property bool checking: monitorService ? monitorService.checking : false
  readonly property color healthyColor: "#59d98e"
  readonly property color alertColor: bar ? bar.urgent : Color.urgent
  readonly property color foregroundColor: bar ? bar.barForeground : Color.foreground
  readonly property color dimColor: Qt.darker(root.foregroundColor, 1.55)
  readonly property color statusColor: {
    if (root.downCount > 0) return root.alertColor
    if (root.degradedCount > 0 || root.checking) return Color.accent
    if (root.overall === "up") return root.healthyColor
    return root.dimColor
  }

  readonly property bool opened: panelLoader.item
    ? panelLoader.item.opened === true
    : false

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function toggle() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  function injectPanel() {
    if (!panelLoader.item) return
    panelLoader.item.bar = root.bar
    panelLoader.item.anchorItem = button
    panelLoader.item.hostWidget = root
  }

  function tooltip() {
    if (root.totalCount === 0) return "Omastatus — no service configured"
    if (root.downCount > 0)
      return "Omastatus — " + root.downCount + " down out of " + root.totalCount
    if (root.degradedCount > 0)
      return "Omastatus — " + root.degradedCount + " check(s) unstable"
    return "Omastatus — all " + root.totalCount + " services are up"
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: root.injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: root.moduleName
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function checkAllNow(): void {
      if (root.monitorService) root.monitorService.checkAllNow()
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    active: root.overall !== "unknown" || root.checking
    tooltipText: root.tooltip()

    iconComponent: Component {
      Item {
        anchors.fill: parent

        Rectangle {
          anchors.centerIn: parent
          width: Style.space(9)
          height: width
          radius: width / 2
          color: root.statusColor

          SequentialAnimation on opacity {
            running: root.checking
            loops: Animation.Infinite
            NumberAnimation { from: 1; to: 0.35; duration: 500 }
            NumberAnimation { from: 0.35; to: 1; duration: 500 }
          }
        }
      }
    }

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton || buttonCode === Qt.MiddleButton) {
        if (root.monitorService) root.monitorService.checkAllNow()
      } else {
        root.toggle()
      }
    }
  }
}
