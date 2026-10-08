(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;

  function update(entry, title, value, label, tone, available) {
    entry.update({ title: title, value: value, available: available !== false });
    if (!entry.connectionStatus) {
      entry.connectionStatus = S.status(label, tone);
      entry.accessory.appendChild(entry.connectionStatus);
    } else S.updateStatus(entry.connectionStatus, label, tone);
  }

  function providerSummary(provider, installations, operations) {
    if (provider.providerID === "qoder") {
      installations = installations.filter(function (item) {
        return item.distribution === (provider.qoderDistribution || "cn");
      });
    }
    var primary = installations.find(function (item) { return item.isActive; })
      || installations.find(function (item) { return item.enabled && item.availability === "available"; })
      || installations[0];
    var operation = S.safeArray(operations).filter(function (item) {
      return item.providerID === provider.providerID
        && (provider.providerID !== "qoder" || item.distribution === (provider.qoderDistribution || "cn"));
    }).slice(-1)[0];
    if (operation && global.CodexBridgeDesktopAgentSetup.running(operation)) {
      return { value: operation.message || "", label: "配置中", tone: "running" };
    }
    if (operation && operation.state === "needs_user_action") {
      return { value: operation.message || "", label: "待处理", tone: "warning" };
    }
    if (operation && (operation.state === "failed" || operation.state === "interrupted")) {
      return { value: operation.message || "", label: operation.state === "failed" ? "配置失败" : "配置中断",
        tone: operation.state === "failed" ? "error" : "warning" };
    }
    if (provider.providerID === "deepseek-harness-desktop") {
      var desktop = provider.desktop;
      if (primary && primary.availability === "needs_review") {
        return { value: "原生桌面", label: "需确认更新", tone: "warning" };
      }
      var connected = desktop && desktop.connected && desktop.paired;
      var failed = desktop && desktop.errorCode && desktop.errorCode !== "desktop_connector_not_ready"
        && desktop.errorCode !== "desktop_pairing_required" && desktop.errorCode !== "desktop_not_running";
      var found = desktop && desktop.executablePath || primary || provider.discoveredExecutablePath
        || provider.discoveryState === "discovered";
      return { value: "原生桌面", label: connected ? "已连接" : failed ? "连接失败"
        : desktop && desktop.pairingCode && !desktop.paired ? "等待配对"
        : found && desktop && desktop.connectorInstalled && desktop.errorCode === "desktop_not_running"
          ? "DSH 桌面版未打开"
        : found ? desktop && desktop.connectorInstalled ? "待连接" : "待安装连接器"
        : provider.discoveryState === "not_found" ? "未发现" : "正在查找",
        tone: connected ? "success" : failed ? "error" : "neutral" };
    }
    if (primary) {
      return { value: primary.version || primary.displayName || "",
        label: global.CodexBridgeDesktopAgentConnectorDetails.availabilityLabel(primary.availability, primary.enabled),
        tone: global.CodexBridgeDesktopAgentConnectorDetails.availabilityTone(primary.availability, primary.enabled) };
    }
    var state = provider.discoveryState || "discovering";
    return { value: "", label: state === "not_found" ? "未发现" : state === "failed" ? "查找失败"
      : state === "discovered" ? "已发现" : "正在查找",
      tone: state === "failed" ? "error" : state === "discovered" ? "warning"
        : state === "discovering" ? "running" : "neutral" };
  }

  global.CodexBridgeDesktopConnectionsNavigation = {
    update: update, providerSummary: providerSummary
  };
}(window));
