(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  var sequence = 0;

  function create(container) {
    var workspace = S.node("div", "connections-workspace");
    var overview = S.node("nav", "connections-list");
    var inspector = S.node("div", "connections-inspector");
    var entries = new Map(), selected = null;
    overview.setAttribute("aria-label", "连接");
    workspace.appendChild(overview); workspace.appendChild(inspector);
    container.appendChild(workspace);

    function open(id, options) {
      var entry = entries.get(id);
      if (!entry || entry.root.hidden) return;
      if (selected && entries.has(selected)) {
        var previous = entries.get(selected);
        previous.panel.hidden = true;
        previous.root.removeAttribute("aria-current");
      }
      selected = id;
      entry.panel.hidden = false;
      entry.root.setAttribute("aria-current", "page");
      entry.returnTarget = options && options.returnTo ? options : null;
      entry.returnButton.hidden = !entry.returnTarget;
      inspector.scrollTop = 0;
      if (options && options.focus) entry.heading.focus({ preventScroll: true });
    }

    function register(id, label, body) {
      if (entries.has(id)) return entries.get(id);
      var root = S.node("button", "connection-list-item"); root.type = "button";
      var copy = S.node("span", "connection-list-copy");
      var name = S.node("span", "connection-list-name", label);
      var value = S.node("span", "connection-list-value");
      var accessory = S.node("span", "connection-list-status");
      var suffix = String(++sequence);
      name.id = "connection-name-" + suffix;
      value.id = "connection-value-" + suffix;
      accessory.id = "connection-status-" + suffix;
      copy.appendChild(name); copy.appendChild(value);
      root.appendChild(copy); root.appendChild(accessory);
      root.dataset.detailID = id;
      root.setAttribute("aria-labelledby", [name.id, value.id, accessory.id].join(" "));
      value.hidden = true;

      var panel = S.node("section", "connection-inspector-panel"); panel.hidden = true;
      var header = S.node("header", "connection-inspector-header");
      var identity = S.node("div", "connection-inspector-identity");
      var title = S.node("h2", null, label);
      title.id = "connection-heading-" + suffix;
      title.tabIndex = -1;
      panel.setAttribute("aria-labelledby", title.id);
      var detailStatus = S.node("span");
      identity.appendChild(title); identity.appendChild(detailStatus);
      var actions = S.node("div", "connection-inspector-actions");
      var returnButton = S.button("返回", null, {}, null, "small", false);
      returnButton.hidden = true;
      returnButton.addEventListener("click", function () {
        var target = entry.returnTarget;
        if (!target) return;
        open(target.returnTo);
        if (target.trigger && target.trigger.isConnected) target.trigger.focus({ preventScroll: true });
      });
      actions.appendChild(returnButton);
      header.appendChild(identity); header.appendChild(actions);
      var content = S.node("div", "connection-inspector-content"); content.appendChild(body);
      panel.appendChild(header); panel.appendChild(content); inspector.appendChild(panel);
      var entry = {
        root: root, body: body, panel: panel, heading: title, value: value, accessory: accessory,
        detailStatus: detailStatus, title: label, returnButton: returnButton,
        open: function () { open(id); },
        setActions: function (element) { if (element) actions.appendChild(element); },
        setStatus: function (element) {
          if (!element) return;
          if (typeof detailStatus.replaceWith === "function") {
            detailStatus.replaceWith(element);
          } else if (detailStatus.parentNode) {
            detailStatus.parentNode.insertBefore(element, detailStatus);
            detailStatus.parentNode.removeChild(detailStatus);
          }
          detailStatus = element;
          entry.detailStatus = element;
          entry.customStatus = true;
        },
        update: function (next) {
          if (next.title !== undefined) { entry.title = next.title; name.textContent = next.title; title.textContent = next.title; }
          if (next.value !== undefined) { value.textContent = next.value || ""; value.hidden = !next.value; }
          if (next.available !== undefined) {
            root.hidden = !next.available;
            if (!next.available && selected === id) open("chatgpt");
          }
        }
      };
      root.addEventListener("click", entry.open);
      entries.set(id, entry);
      return entry;
    }

    function remove(id) {
      var entry = entries.get(id);
      if (!entry) return;
      if (selected === id) open("chatgpt");
      entry.root.remove(); entry.panel.remove(); entries.delete(id);
    }

    return { overview: overview, register: register, open: open, remove: remove,
      selectedID: function () { return selected; } };
  }

  function update(entry, title, value, label, tone, available) {
    var nextStep = "";
    if (/未发现/.test(label)) {
      nextStep = entry.root.dataset.detailID === "agent:deepseek-harness-desktop" ? "下载桌面版" : "安装并连接";
    } else if (/未连接|待连接|已发现|未启用/.test(label)) {
      nextStep = "选择以连接";
    } else if (/待处理|失败|中断|需确认|待更新/.test(label)) {
      nextStep = "查看处理方式";
    }
    entry.update({ title: title, value: nextStep, available: available !== false });
    if (!entry.connectionStatus) {
      entry.connectionStatus = S.status(label, tone);
      entry.accessory.appendChild(entry.connectionStatus);
    } else S.updateStatus(entry.connectionStatus, label, tone);
    if (!entry.customStatus) S.updateStatus(entry.detailStatus, label, tone);
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
      var updateAvailable = desktop && desktop.connectorUpdateAvailable;
      var connected = desktop && desktop.connected && desktop.paired && !updateAvailable;
      var failed = desktop && desktop.errorCode && desktop.errorCode !== "desktop_connector_not_ready"
        && desktop.errorCode !== "desktop_pairing_required" && desktop.errorCode !== "desktop_not_running";
      var found = desktop && desktop.executablePath || primary || provider.discoveredExecutablePath
        || provider.discoveryState === "discovered";
      return { value: "原生桌面", label: connected ? "已连接" : failed ? "连接失败"
        : updateAvailable ? "待更新连接器"
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
    create: create, update: update, providerSummary: providerSummary
  };
}(window));
