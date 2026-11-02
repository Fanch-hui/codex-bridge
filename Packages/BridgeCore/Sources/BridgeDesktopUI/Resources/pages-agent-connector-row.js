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

    var row = S.node("article", (dependencies.detail ? "connection-detail " : "page-card ") + "connection-card agent-connect-row");
    var header = S.node("div", "agent-connect-header");
    if (!dependencies.detail) header.appendChild(S.icon("cpu.fill", "service-icon"));
    var main = S.node("div", "agent-connect-main");
    var heading = S.node("div", "client-heading");
    var title = S.node("div", "row-title");
    title.hidden = !!dependencies.detail;
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
    var inferenceProtocol = S.selectField("推理协议", "deepseek-messages", [
      { id: "deepseek-messages", title: "DeepSeek Messages" },
      { id: "openai-completions", title: "OpenAI Chat Completions" }
    ], refreshAction);
    var catalogBaseURL = S.textField("模型目录 Base URL（可选）", "", "留空时按推理协议解析");
    apiKey.control.type = "password";
    apiKey.control.autocomplete = "off";
    fields.appendChild(inferenceProtocol.wrapper);
    fields.appendChild(baseURL.wrapper);
    fields.appendChild(catalogBaseURL.wrapper);
    fields.appendChild(apiKey.wrapper);
    var configPanel = S.node("div", "agent-config-panel"); configPanel.appendChild(fields);
    var configSave = S.button("更新配置", null, {}, null, "small", true); configPanel.appendChild(configSave);
    row.appendChild(configPanel);
    var desktop = global.CodexBridgeDesktopDSHDesktop.create(S, function (command, payload) { context.emit(command, payload); });
    row.appendChild(desktop.root);
    var qoderSettings = global.CodexBridgeDesktopQoderRuntimeSettings.create(refreshAction);
    var regionPicker = dependencies.detail && qoderSettings.root.querySelector(".form-grid > .field");
    if (regionPicker) {
      regionPicker.classList.add("agent-region-picker");
      row.appendChild(regionPicker);
    }

    var actionBar = S.node("div", "agent-connect-actionbar");
    var action = S.button("连接", null, {}, null, "small primary", true);
    var actionHint = S.node("span", "agent-action-hint");
    actionBar.appendChild(action);
    if (!dependencies.detail) actionBar.appendChild(actionHint);
    var setupPrimary = S.button("安装并连接", null, {}, null, "small primary", false);
    var setupHelp = S.button("登录或配置", null, {}, null, "small", false);
    var setupAction = S.button("重新配置", null, {}, null, "small", false);
    var setupProgress = S.button("查看配置进度", null, {}, null, "small primary", false);
    var setupHistory = S.button("查看配置结果", null, {}, null, "small", false);
    actionBar.appendChild(setupPrimary);
    actionBar.appendChild(setupProgress);
    actionBar.appendChild(setupHelp);
    row.appendChild(actionBar);
    if (dependencies.detail) row.appendChild(actionHint);
    var setup = global.CodexBridgeDesktopAgentSetup.create(context, provider, beginSetup);
    row.appendChild(setup.root);
    var installOptions = S.node("details", "agent-details");
    installOptions.appendChild(S.node("summary", null, "高级安装选项"));
    var installDirectory = S.textField("安装目录（可选）", "", "留空时使用应用管理的安装目录");
    installOptions.appendChild(installDirectory.wrapper);

    function beginSetup() {
      context.emit("beginAgentSetup", { providerID: currentProvider.providerID,
        qoderDistribution: currentProvider.providerID === "qoder" ? qoderSettings.distribution() : null,
        installationID: currentProvider.providerID === "qoder" ? qoderSettings.installationID() : null,
        installDirectory: installDirectory.control.value.trim() || null });
      setupAction.disabled = true;
      setupPrimary.disabled = true;
      setupHelp.disabled = true;
    }
    setupPrimary.addEventListener("click", beginSetup);
    setupHelp.addEventListener("click", beginSetup);
    setupAction.addEventListener("click", beginSetup);
    setupProgress.addEventListener("click", function () { setup.open(); });
    setupHistory.addEventListener("click", function () { setup.open(); });
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
    var summary = S.node("summary", null, "高级配置");
    var detailsBody = S.node("div", "agent-details-body");
    var providerDetail = S.node("p", "agent-provider-detail");
    detailsBody.appendChild(providerDetail);
    detailsBody.appendChild(qoderSettings.root);
    detailsBody.appendChild(installOptions);
    detailsBody.appendChild(setupAction);
    detailsBody.appendChild(setupHistory);
    if (dependencies.openMCP && (provider.providerID === "pi" || provider.providerID === "qoder")) {
      var mcp = S.button("MCP 服务", null, {}, null, "small", false);
      mcp.addEventListener("click", function () {
        dependencies.openMCP(currentProvider.providerID === "qoder"
          ? "qoder." + qoderSettings.distribution() : currentProvider.providerID, mcp);
      });
      detailsBody.appendChild(mcp);
    }
    detailsBody.appendChild(desktop.maintenanceRoot);
    var installationDetails = S.node("div", "agent-installations");
    detailsBody.appendChild(installationDetails);
    details.appendChild(summary);
    details.appendChild(detailsBody);
    var defaults = S.section(row, "任务默认设置");
    var defaultsBody = S.node("div", "agent-defaults-slot"); defaults.appendChild(defaultsBody);
    if (global.CodexBridgeDesktopSettingsPage) {
      global.CodexBridgeDesktopSettingsPage.mountAgent(provider.providerID, defaultsBody);
    }
    row.appendChild(details);

    var draft = D.bind({ baseURL: baseURL.control, apiKey: apiKey.control,
      inferenceProtocol: inferenceProtocol.control, catalogBaseURL: catalogBaseURL.control });

    function scopedInstallations() {
      if (currentProvider.providerID !== "qoder") return currentInstallations;
      var distribution = qoderSettings.distribution();
      return currentInstallations.filter(function (item) {
        return item.distribution === distribution;
      });
    }

    function configurationValid() {
      if (desktop.isDesktop()) return desktop.presentation().canAct;
      if (!currentProvider.requiresConfiguration) return true;
      var base = hasValue(baseURL.control.value);
      var key = hasValue(apiKey.control.value);
      if (currentProvider.configuredBaseURL) return base || !key;
      if (base || key) return base && key;
      return currentInstallations.length > 0 || !!currentProvider.discoveredConfigurationPath;
    }

    function updateDesktopAction(primary) {
      actionBar.hidden = false; action.hidden = false; actionMode = "desktop";
      configPanel.hidden = true; setupAction.hidden = true; setupPrimary.hidden = true;
      setupProgress.hidden = true; setupHistory.hidden = true; setupHelp.hidden = true; installOptions.hidden = true;
      var native = desktop.presentation();
      S.updateStatus(status, native.label, native.tone);
      if (primary && primary.availability === "needs_review") {
        actionMode = "review";
        action.textContent = primary.enabled ? "确认更新并连接" : "确认更新并检查";
        action.disabled = !context.canConnect || context.busy || !primary.canReprobe || !!pending;
      } else {
        var connected = desktop.connected();
        actionMode = connected ? "use" : "desktop";
        action.hidden = native.actionHidden && !connected;
        action.textContent = connected ? "打开工作台" : native.actionTitle;
        action.disabled = !connected && (!context.canConnect || context.busy || !native.canAct);
      }
      actionHint.textContent = native.actionHint;
    }

    function updateSetupActions(operation, noCandidate, connected) {
      var running = global.CodexBridgeDesktopAgentSetup.running(operation);
      setupAction.disabled = !context.canConnect || context.busy || running;
      setupPrimary.hidden = !noCandidate;
      setupPrimary.disabled = !context.canConnect || context.busy || running;
      var needsSetup = !!operation && (running || operation.state === "needs_user_action"
        || !connected && ["failed", "interrupted"].indexOf(operation.state) >= 0);
      setupProgress.hidden = !needsSetup;
      setupHistory.hidden = !operation || needsSetup;
      setupProgress.textContent = operation && operation.state === "needs_user_action" ? "继续连接"
        : operation && operation.state === "failed" ? "查看失败原因" : "查看连接进度";
      return needsSetup;
    }

    function refreshAction() {
      var scopedOperation = S.safeArray(context.setupOperations).filter(function (item) {
        return item.providerID === currentProvider.providerID
          && (currentProvider.providerID !== "qoder" || item.distribution === qoderSettings.distribution());
      }).slice(-1)[0] || null;
      setup.update(scopedOperation, currentProvider);
      var scoped = scopedInstallations();
      var primary = primaryInstallation(scoped);
      if (currentProvider.providerID === "qoder") {
        var selectedConnected = scoped.some(isConnected);
        S.updateStatus(status, stateLabel(currentProvider, primary, selectedConnected),
          stateTone(currentProvider, primary, selectedConnected));
        detail.textContent = scopedOperation ? scopedOperation.message
          : rowDetail(currentProvider, scoped, primary, selectedConnected);
        updateDetails(currentProvider, scoped, primary);
        if (dependencies.onStateChange) dependencies.onStateChange();
      }
      if (desktop.isDesktop()) {
        updateDesktopAction(primary);
        return;
      }
      setupAction.hidden = false; installOptions.hidden = false;
      var isConnectedValue = scoped.some(isConnected);
      var review = primary && primary.availability === "needs_review";
      var ready = context.canConnect && !context.busy && configurationValid();
      var hasConfigurationInput = baseURL.control.value !== (currentProvider.configuredBaseURL || "")
        || hasValue(apiKey.control.value)
        || inferenceProtocol.control.value !== (currentProvider.configuredInferenceProtocol || "deepseek-messages")
        || catalogBaseURL.control.value !== (currentProvider.configuredCatalogBaseURL || "");
      var noCandidate = !primary && discoveryState(currentProvider) === "not_found";
      actionMode = null;
      var operation = setup.operation();
      actionBar.hidden = false;
      var needsSetup = updateSetupActions(operation, noCandidate, isConnectedValue);
      setupHelp.hidden = isConnectedValue || noCandidate
        || !(primary && primary.availability === "unavailable" || discoveryState(currentProvider) === "failed");
      setupHelp.disabled = !context.canConnect || context.busy || global.CodexBridgeDesktopAgentSetup.running(operation);
      action.hidden = isConnectedValue || (!primary && discoveryState(currentProvider) === "discovering")
        || (!primary && discoveryState(currentProvider) === "not_found");
      configPanel.hidden = !currentProvider.requiresConfiguration || noCandidate
        || (!isConnectedValue && !!currentProvider.discoveredConfigurationPath);
      configSave.hidden = !isConnectedValue || !currentProvider.requiresConfiguration;
      configSave.disabled = !isConnectedValue || !ready || !hasConfigurationInput || !!pending;
      if (pending) {
        actionBar.hidden = false;
        action.hidden = false;
        setupPrimary.hidden = setupProgress.hidden = setupHelp.hidden = true;
        action.textContent = "处理中…";
        action.disabled = true;
        actionHint.textContent = "正在更新本机连接状态";
        return;
      }
      if (needsSetup) {
        action.hidden = setupPrimary.hidden = setupHelp.hidden = true;
        actionHint.textContent = "";
        return;
      }
      if (review) {
        setupPrimary.hidden = setupHelp.hidden = true;
        action.hidden = false;
        actionMode = "review";
        action.textContent = primary.enabled ? "确认更新并连接" : "确认更新并检查";
        action.disabled = !ready || !primary.canReprobe;
        actionHint.textContent = "需要确认本机 Agent 文件已由你更新。";
        return;
      }
      if (isConnectedValue) {
        actionMode = "use";
        action.hidden = false;
        action.textContent = "打开工作台";
        action.disabled = false;
        actionHint.textContent = "";
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
          : "";
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
        inferenceProtocol: currentProvider.providerID === "deepseek-harness" && hasValue(values.baseURL) ? values.inferenceProtocol : null,
        catalogBaseURL: currentProvider.providerID === "deepseek-harness" && hasValue(values.baseURL) ? values.catalogBaseURL : null,
        confirmed: !!alwaysProceedConfirmed,
        qoderDistribution: currentProvider.providerID === "qoder"
          ? qoderSettings.distribution() : null,
        installationID: currentProvider.providerID === "qoder"
          ? qoderSettings.installationID() : null
      });
      apiKey.control.value = "";
      draft.update({ baseURL: baseURL.control.value, apiKey: "",
        inferenceProtocol: inferenceProtocol.control.value, catalogBaseURL: catalogBaseURL.control.value });
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
      desktop.update(nextProvider, currentInstallations, nextContext.busy);
      context.canConnect = !!nextContext.canConnect; context.busy = !!nextContext.busy;
      context.acceptReplacement = nextContext.acceptReplacement !== false;
      qoderSettings.update(nextProvider, currentInstallations, {
        canEdit: context.canConnect,
        busy: context.busy
      }, context.emit);
      if (regionPicker) regionPicker.hidden = nextProvider.providerID !== "qoder";
      if (lastBusy === true && !context.busy) pending = null;
      lastBusy = context.busy;
      finishPending();

      var operation = S.safeArray(nextContext.setupOperations).filter(function (item) {
        return item.providerID === nextProvider.providerID
          && (nextProvider.providerID !== "qoder" || item.distribution === qoderSettings.distribution());
      }).slice(-1)[0] || null;
      setup.update(operation, nextProvider);
      var scoped = scopedInstallations();
      title.textContent = dependencies.detail ? "连接状态" : nextProvider.displayName;
      var primary = primaryInstallation(scoped);
      var isConnectedValue = scoped.some(isConnected);
      S.updateStatus(status, stateLabel(nextProvider, primary, isConnectedValue),
        stateTone(nextProvider, primary, isConnectedValue));
      detail.textContent = operation ? operation.message : rowDetail(nextProvider, scoped, primary, isConnectedValue);
      if (desktop.isDesktop()) {
        var native = desktop.presentation();
        S.updateStatus(status, native.label, native.tone);
        detail.textContent = "DSH 原生桌面会话";
      }
      fields.hidden = !nextProvider.requiresConfiguration || (!isConnectedValue && !!nextProvider.discoveredConfigurationPath)
        || (!primary && discoveryState(nextProvider) === "not_found");
      providerDetail.textContent = desktop.isDesktop()
        ? "使用 DSH 桌面已登录的账号和原生会话。" : providerDetailText(nextProvider, scoped);
      providerDetail.hidden = !providerDetail.textContent;
      if (isConnectedValue && configPanel.parentNode !== detailsBody) {
        detailsBody.insertBefore(configPanel, detailsBody.firstChild.nextSibling);
      } else if (!isConnectedValue && configPanel.parentNode !== row) {
        row.insertBefore(configPanel, desktop.root);
      }
      updateDetails(nextProvider, scoped, primary);
      inferenceProtocol.wrapper.hidden = nextProvider.providerID !== "deepseek-harness";
      catalogBaseURL.wrapper.hidden = nextProvider.providerID !== "deepseek-harness";
      draft.update({
        baseURL: nextProvider.configuredBaseURL || "",
        apiKey: "",
        inferenceProtocol: nextProvider.configuredInferenceProtocol || "deepseek-messages",
        catalogBaseURL: nextProvider.configuredCatalogBaseURL || ""
      });
      refreshAction();
    }

    function finishPending() {
      if (!pending) return;
      if (pending.revision !== context.revision || (!context.canConnect && !context.busy)) pending = null;
    }

    function updateDetails(nextProvider, installations, primary) {
      summary.textContent = installations.length > 1
        ? "高级配置 · " + installations.length + " 个本机安装" : "高级配置";
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
          !!pending && (!pending.installationID || pending.installationID === installation.installationID),
          desktop.isDesktop() ? desktop.presentation() : null
        );
        place(installationDetails, item.root, index);
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
        message.textContent = desktop.isDesktop() && discoveryState(nextProvider) === "discovered"
          ? "已发现 DSH 桌面，安装连接器后即可配对。" : discoveryMessage(nextProvider);
      } else if (message) {
        message.remove();
      }
    }

    [baseURL.control, apiKey.control, catalogBaseURL.control, inferenceProtocol.control].forEach(function (control) {
      control.addEventListener("input", refreshAction);
      control.addEventListener("compositionend", refreshAction);
    });
    action.addEventListener("click", function () {
      if (actionMode === "use" && global.CodexBridgeDesktopDSHWorkbench) {
        global.CodexBridgeDesktopDSHWorkbench.openCollaboration();
      } else if (actionMode === "desktop") { desktop.connect(); refreshAction(); }
      else if (actionMode === "review") reviewConfirmation.open();
      else if (actionMode === "connect") {
        if (HeadlessConsent.required(currentProvider)) headlessConfirmation.open();
        else sendConnect(action, false);
      }
    });
    configSave.addEventListener("click", function () { sendConnect(configSave); });
    return { root: row, update: update, advanced: detailsBody, defaults: defaultsBody,
      primaryActions: actionBar, status: status, selectedDistribution: qoderSettings.distribution,
      selectDistribution: qoderSettings.selectDistribution };
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
    return items.find(function (item) { return item.isActive === true; })
      || items.find(isConnected)
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
    if (connected) return (primary.version || primary.displayName)
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
