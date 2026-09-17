(function (global) {
  "use strict";
  var Details = global.CodexBridgeDesktopAgentConnectorDetails;
  var HeadlessConsent = global.CodexBridgeDesktopAgentHeadlessConsent;
  function create(provider, dependencies) {
    var S = dependencies.S;
    var D = dependencies.D;
    var context = dependencies.context;
    var pending = null;
    var lastBusy = null;
    var actionMode = null;
    var currentProvider = provider;
    var currentInstallations = [];
    var rowsForInstallation = new Map();

    var row = S.node("article", "agent-connect-row");
    var header = S.node("div", "agent-connect-header");
    header.appendChild(S.icon("cpu.fill", "service-icon"));
    var main = S.node("div", "agent-connect-main");
    var heading = S.node("div", "client-heading");
    var title = S.node("div", "row-title");
    var status = S.badge("正在查找", "neutral");
    heading.appendChild(title);
    heading.appendChild(status);
    main.appendChild(heading);
    var detail = S.node("div", "row-detail");
    main.appendChild(detail);
    header.appendChild(main);
    row.appendChild(header);
    var fields = S.node("div", "form-grid agent-connect-fields");
    var baseURL = S.textField("Base URL", "", "https://api.example.com"),
      apiKey = S.textField("API key", "", "输入 API key");
    apiKey.control.type = "password";
    apiKey.control.autocomplete = "off";
    fields.appendChild(baseURL.wrapper);
    fields.appendChild(apiKey.wrapper);
    var configPanel = S.node("div", "agent-config-panel"); configPanel.appendChild(fields);
    var configSave = S.button("更新配置", null, {}, null, "small", true); configPanel.appendChild(configSave);
    row.appendChild(configPanel);

    var actionBar = S.node("div", "agent-connect-actionbar");
    var action = S.button("连接", null, {}, null, "small primary", true);
    var actionHint = S.node("span", "agent-action-hint");
    actionBar.appendChild(action);
    actionBar.appendChild(actionHint);
    row.appendChild(actionBar);
    var reviewConfirmation = Details.confirmation(S, "确认新的 Agent 文件并重新检查？", function () {
        var installation = primaryInstallation(currentInstallations);
        if (installation && installation.canReprobe) sendReprobe(installation, context.acceptReplacement);
    });
    row.appendChild(reviewConfirmation.root);
    var headlessConfirmation = HeadlessConsent.create(S, function () {
      sendConnect(action, true);
    });
    row.appendChild(headlessConfirmation.root);

    var details = S.node("details", "agent-details");
    var summary = S.node("summary", null, "查看详情");
    var detailsBody = S.node("div", "agent-details-body");
    var providerDetail = S.node("p", "agent-provider-detail");
    detailsBody.appendChild(providerDetail);
    details.appendChild(summary);
    details.appendChild(detailsBody);
    row.appendChild(details);

    var draft = D.bind({ baseURL: baseURL.control, apiKey: apiKey.control });

    function configurationValid() {
      if (!currentProvider.requiresConfiguration) return true;
      var base = hasValue(baseURL.control.value);
      var key = hasValue(apiKey.control.value);
      if (base || key) return base && key;
      return currentInstallations.length > 0 || !!currentProvider.discoveredConfigurationPath;
    }

    function refreshAction() {
      var primary = primaryInstallation(currentInstallations);
      var isConnectedValue = currentInstallations.some(isConnected);
      var review = primary && primary.availability === "needs_review";
      var ready = context.canConnect && !context.busy && configurationValid();
      var hasConfigurationInput = hasValue(baseURL.control.value) || hasValue(apiKey.control.value);
      var noCandidate = !primary && discoveryState(currentProvider) === "not_found";
      actionMode = null;
      actionBar.hidden = isConnectedValue;
      action.hidden = isConnectedValue || (!primary && discoveryState(currentProvider) === "discovering")
        || (!primary && discoveryState(currentProvider) === "not_found");
      configPanel.hidden = !currentProvider.requiresConfiguration || noCandidate
        || (!isConnectedValue && !!currentProvider.discoveredConfigurationPath);
      configSave.hidden = !isConnectedValue || !currentProvider.requiresConfiguration;
      configSave.disabled = !isConnectedValue || !ready || !hasConfigurationInput || !!pending;
      if (pending) {
        actionBar.hidden = false;
        action.hidden = false;
        action.textContent = "处理中…";
        action.disabled = true;
        actionHint.textContent = "正在更新本机连接状态";
        return;
      }
      if (review) {
        actionMode = "review";
        action.textContent = primary.enabled ? "确认更新并连接" : "确认更新并检查";
        action.disabled = !ready || !primary.canReprobe;
        actionHint.textContent = "需要确认本机 Agent 文件已由你更新。";
        return;
      }
      if (!action.hidden) {
        actionMode = "connect";
        action.textContent = primary
          ? (primary.availability === "available" ? "连接" : "重试")
          : discoveryState(currentProvider) === "discovered" ? "连接" : "重试";
        action.disabled = !ready;
        actionHint.textContent = currentProvider.requiresHeadlessAlwaysProceed
          ? "连接前需要同意为 AGY 启用无头模式 Always Proceed。"
          : "连接成功后会显示在本行状态中。";
      } else {
        action.disabled = true;
        actionHint.textContent = isConnectedValue ? "" : discoveryMessage(currentProvider);
      }
    }

    function sendConnect(button, alwaysProceedConfirmed) {
      if (button.disabled) return;
      var values = draft.values();
      pending = { revision: context.revision, kind: "connect" };
      headlessConfirmation.close();
      refreshAction();
      context.emit("connectAgent", {
        providerID: currentProvider.providerID,
        baseURL: currentProvider.requiresConfiguration ? values.baseURL : null,
        apiKey: currentProvider.requiresConfiguration ? values.apiKey : null,
        confirmed: !!alwaysProceedConfirmed
      });
      apiKey.control.value = "";
      draft.update({ baseURL: baseURL.control.value, apiKey: "" });
    }

    function sendReprobe(installation, acceptReplacement) {
      if (!installation || !installation.canReprobe || context.busy || pending) return;
      pending = { revision: context.revision, kind: "reprobe", installationID: installation.installationID };
      reviewConfirmation.close();
      refreshAction();
      context.emit("reprobeAgent", {
        installationID: installation.installationID,
        acceptReplacement: !!acceptReplacement
      });
    }

    function sendToggle(installation, enabled) {
      if (!installation || !installation.canToggle || context.busy || pending) return;
      pending = { revision: context.revision, kind: "toggle", installationID: installation.installationID, enabled: enabled };
      refreshAction();
      context.emit("setAgentEnabled", {
        installationID: installation.installationID,
        enabled: enabled
      });
    }

    function sendRemove(installation) {
      if (!installation || !installation.canRemove || context.busy || pending) return;
      pending = { revision: context.revision, kind: "remove", installationID: installation.installationID };
      refreshAction();
      context.emit("removeAgent", { installationID: installation.installationID });
    }

    function update(nextProvider, installations, nextContext) {
      currentProvider = nextProvider;
      currentInstallations = S.safeArray(installations);
      context.canConnect = !!nextContext.canConnect; context.busy = !!nextContext.busy;
      context.acceptReplacement = nextContext.acceptReplacement !== false;
      if (lastBusy === true && !context.busy) pending = null;
      lastBusy = context.busy;
      finishPending();

      title.textContent = nextProvider.displayName;
      var primary = primaryInstallation(currentInstallations);
      var isConnectedValue = currentInstallations.some(isConnected);
      status.textContent = stateLabel(nextProvider, primary, isConnectedValue);
      status.className = "status-badge " + stateTone(nextProvider, primary, isConnectedValue);
      detail.textContent = rowDetail(nextProvider, currentInstallations, primary, isConnectedValue);
      fields.hidden = !nextProvider.requiresConfiguration || (!isConnectedValue && !!nextProvider.discoveredConfigurationPath)
        || (!primary && discoveryState(nextProvider) === "not_found");
      providerDetail.textContent = providerDetailText(nextProvider, currentInstallations);
      providerDetail.hidden = !providerDetail.textContent;
      if (isConnectedValue && configPanel.parentNode !== detailsBody) {
        detailsBody.insertBefore(configPanel, detailsBody.firstChild.nextSibling);
      } else if (!isConnectedValue && configPanel.parentNode !== row) {
        row.insertBefore(configPanel, actionBar);
      }
      updateDetails(nextProvider, currentInstallations, primary);
      draft.update({ baseURL: baseURL.control.value, apiKey: "" });
      refreshAction();
    }

    function finishPending() {
      if (!pending) return;
      if (pending.revision !== context.revision || (!context.canConnect && !context.busy)) pending = null;
    }

    function updateDetails(nextProvider, installations, primary) {
      summary.textContent = installations.length > 1
        ? "查看详情 · " + installations.length + " 个本机安装" : "查看详情";
      var visible = new Set();
      installations.forEach(function (installation, index) {
        var item = rowsForInstallation.get(installation.installationID);
        if (!item) {
          item = Details.createInstallationDetail(
            S,
            installation,
            function (value, accept) { sendReprobe(value, accept); },
            sendToggle,
            sendRemove
          );
          rowsForInstallation.set(installation.installationID, item);
        }
        item.update(
          installation,
          context,
          !!pending && (!pending.installationID || pending.installationID === installation.installationID)
        );
        place(detailsBody, item.root, detailsBody.contains(configPanel) ? index + 2 : index + 1);
        visible.add(installation.installationID);
      });
      rowsForInstallation.forEach(function (item, installationID) {
        if (!visible.has(installationID)) {
          item.root.remove();
          rowsForInstallation.delete(installationID);
        }
      });
      if (!primary || primary.availability !== "needs_review") {
        reviewConfirmation.close();
      }
      if (!HeadlessConsent.required(nextProvider)) headlessConfirmation.close();
      var message = detailsBody.querySelector(".agent-discovery-message");
      if (!installations.length) {
        if (!message) {
          message = S.node("p", "agent-discovery-message");
          detailsBody.appendChild(message);
        }
        message.textContent = discoveryMessage(nextProvider);
      } else if (message) {
        message.remove();
      }
    }

    [baseURL.control, apiKey.control].forEach(function (control) {
      control.addEventListener("input", refreshAction);
      control.addEventListener("compositionend", refreshAction);
    });
    action.addEventListener("click", function () {
      if (actionMode === "review") reviewConfirmation.open();
      else if (actionMode === "connect") {
        if (HeadlessConsent.required(currentProvider)) headlessConfirmation.open();
        else sendConnect(action, false);
      }
    });
    configSave.addEventListener("click", function () { sendConnect(configSave); });
    return { root: row, update: update };
  }

  function place(parent, child, index) {
    var current = parent.children[index];
    if (current === child) return;
    if (current) parent.insertBefore(child, current);
    else parent.appendChild(child);
  }

  function hasValue(value) { return !!value && value.trim().length > 0; }
  function isConnected(item) { return item && item.enabled === true && item.availability === "available"; }
  function primaryInstallation(items) {
    return items.find(isConnected)
      || items.find(function (item) { return item.availability === "needs_review"; })
      || items.find(function (item) { return item.availability === "available"; })
      || items[0] || null;
  }
  function discoveryState(provider) { return provider.discoveryState || "discovering"; }
  function discoveryMessage(provider) {
    if (provider.discoveryMessage) return provider.discoveryMessage;
    var state = discoveryState(provider);
    if (state === "not_found") return "本机未发现可用安装。";
    if (state === "failed") return "本机索引失败，请稍后重试。";
    if (state === "discovered") return "已发现本机安装，点击连接完成验证。";
    return "正在查找本机安装…";
  }
  function stateLabel(provider, item, connected) {
    if (connected) return "已连接";
    if (item) return Details.availabilityLabel(item.availability, item.enabled);
    if (discoveryState(provider) === "discovered") return "已发现";
    if (discoveryState(provider) === "not_found") return "未发现";
    if (discoveryState(provider) === "failed") return "查找失败";
    return "正在查找";
  }
  function stateTone(provider, item, connected) {
    if (connected) return "success";
    if (item) return Details.availabilityTone(item.availability, item.enabled);
    return discoveryState(provider) === "failed" ? "error"
      : discoveryState(provider) === "discovered" ? "warning" : "neutral";
  }
  function rowDetail(provider, items, primary, connected) {
    if (connected) return "已连接 · " + primary.displayName
      + (items.length > 1 ? " · 另有 " + (items.length - 1) + " 个安装" : "");
    if (primary) return primary.displayName + (primary.version ? " · " + primary.version : "");
    return discoveryMessage(provider);
  }
  function providerDetailText(provider, installations) {
    var values = provider.detail ? [provider.detail] : [];
    values.push(provider.requiresConfiguration ? "需要 Base URL 和 API key" : "无需配置文件");
    if (installations.length > 1) values.push("已索引 " + installations.length + " 个本机安装");
    return values.join(" · ");
  }

  global.CodexBridgeDesktopAgentConnectorRow = { create: create };
}(window));
