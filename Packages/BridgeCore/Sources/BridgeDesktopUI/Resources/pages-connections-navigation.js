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
      var connected = provider.desktop && provider.desktop.connected && provider.desktop.paired
        && (!primary || primary.availability !== "needs_review");
      return { value: "原生桌面", label: connected ? "已连接" : "等待桌面连接",
        tone: connected ? "success" : "neutral" };
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
