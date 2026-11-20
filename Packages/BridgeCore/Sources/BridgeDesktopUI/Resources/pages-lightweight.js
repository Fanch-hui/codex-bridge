(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  var T = global.CodexBridgeDesktopProviderGatewayTransport;
  var titles = { service: "服务", suppliers: "供应商", clients: "接入应用", activity: "活动" };
  var current = "service", requested = false, status = null, modeStatus = null, lastHostModeKey = "";
  var failure = "", loading = false, mutating = false, statusFlight = null;
  var statusError = "", busyPolls = 0, explicitRead = false, installing = false;
  var hostState = null, emitter = null, changed = null, timer = null, view = null, modeCards = [];
  var preferences = !!(global.location && new URLSearchParams(global.location.search).get("surface") === "preferences");

  function notify() { if (changed) changed(); }
  function isPreferencesSurface() {
    return preferences || !!(typeof document !== "undefined"
      && document.documentElement
      && document.documentElement.dataset
      && document.documentElement.dataset.surface === "preferences");
  }
  function hostModeFromSettings(settings) {
    if (!settings || (settings.applicationMode !== "full" && settings.applicationMode !== "lite")) return null;
    return {
      mode: settings.applicationMode,
      transition: settings.applicationModeTransition || null,
      error: settings.applicationModeError || null
    };
  }
  function syncHostMode(settings) {
    var next = hostModeFromSettings(settings);
    if (!next) return;
    var key = next.mode + "|" + (next.transition || "") + "|" + (next.error || "");
    if (key === lastHostModeKey) return;
    lastHostModeKey = key;
    modeStatus = null;
    statusError = "";
    busyPolls = 0;
  }
  function currentMode(settings) {
    var fromSettings = hostModeFromSettings(settings || (hostState && hostState.settings));
    if (modeStatus) return modeStatus;
    if (fromSettings) {
      if (status && status.mode === fromSettings.mode
        && (status.transition || null) === fromSettings.transition) {
        return {
          mode: fromSettings.mode,
          transition: fromSettings.transition,
          error: fromSettings.error || status.error || null
        };
      }
      return fromSettings;
    }
    return status;
  }
  function needsModePoll() {
    var active = currentMode();
    return !active || active.transition === "waiting";
  }
  function schedule() {
    if (timer) global.clearTimeout(timer);
    timer = null;
    if (!hostState || hostState.serviceConnected === false || document.visibilityState === "hidden") return;
    if (isPreferencesSurface()) {
      if (!needsModePoll()) return;
      var activeMode = currentMode();
      timer = global.setTimeout(pollMode, activeMode && activeMode.transition === "waiting" ? 2000 : 15000);
      return;
    }
    var operation = status && status.pluginOperation;
    var active = installing || operation && operation.state === "running" || status && (status.transition || status.communityModelsRefreshing);
    timer = global.setTimeout(poll, active ? 2000 : 15000);
  }
  function refresh() { explicitRead = true; return isPreferencesSurface() ? readModeStatus() : readStatus(); }
  function poll() { return readStatus(); }
  function pollMode() { return readModeStatus(); }
  function readModeStatus() {
    if (loading) return statusFlight;
    if (!hostState || hostState.serviceConnected === false) { explicitRead = false; return Promise.resolve(null); }
    loading = true;
    statusFlight = T.read("gateway.mode.status", function () {
      return T.call("mode.status", {}).catch(function (error) {
        if (error && error.code === "invalid_state") return T.call("status", {});
        throw error;
      });
    }).then(function (next) {
      if (next && (next.mode === "full" || next.mode === "lite")) {
        modeStatus = {
          mode: next.mode,
          transition: next.transition || null,
          error: next.error || null
        };
      }
      statusError = ""; busyPolls = 0;
      return next;
    }).catch(function (error) {
      var hasKnown = !!currentMode();
      if (error && error.code === "busy" && error.retryable === true) {
        busyPolls++;
        if (explicitRead || !hasKnown || busyPolls > 1) {
          statusError = hasKnown ? "服务正忙，当前显示上次读取的状态。" : "服务正忙，稍后将自动刷新。";
        }
      } else {
        busyPolls = 0;
        statusError = (error && error.message) || "读取服务状态失败。";
      }
      return null;
    }).finally(function () {
      loading = false; explicitRead = false; statusFlight = null;
      updateModeCards(); notify(); schedule();
    });
    return statusFlight;
  }
  function readStatus() {
    if (loading) return statusFlight;
    if (!hostState || hostState.serviceConnected === false) { explicitRead = false; return Promise.resolve(null); }
    loading = true;
    statusFlight = T.read("gateway.status", function () { return T.call("status", {}); }).then(function (next) {
      var prior = status && status.mode;
      status = next; statusError = ""; busyPolls = 0;
      if (prior !== next.mode) {
        requested = next.mode === "lite";
      }
      return next;
    }).catch(function (error) {
      if (error.code === "busy" && error.retryable === true) {
        busyPolls++;
        if (explicitRead || !status || busyPolls > 1) {
          statusError = status ? "服务正忙，当前显示上次读取的状态。" : "服务正忙，稍后将自动刷新。";
        }
      } else {
        busyPolls = 0;
        statusError = error.message || "读取服务状态失败。";
      }
      return null;
    }).finally(function () { loading = false; explicitRead = false; statusFlight = null; updateModeCards(); notify(); schedule(); });
    return statusFlight;
  }
  function configure(nextState, emit, onChanged) {
    hostState = nextState; emitter = emit; changed = onChanged; T.configure(emit);
    T.receive(nextState && (nextState.providerGatewayReceipts
      || nextState.workbench && nextState.workbench.embeddedDSHReceipts));
    syncHostMode(nextState && nextState.settings);
    if (nextState && nextState.serviceConnected === false) {
      if (timer) { global.clearTimeout(timer); timer = null; }
      updateModeCards();
      return;
    }
    if (isPreferencesSurface()) {
      if (nextState && nextState.serviceConnected !== false && needsModePoll() && !loading && !statusError) {
        void pollMode();
      } else {
        schedule();
      }
      updateModeCards();
      return;
    }
    if (nextState && nextState.serviceConnected !== false && !status && !loading && !statusError) poll();
    updateSidebarToggle();
  }
  function run(action, payload, options) {
    options = options || {};
    if (mutating) return Promise.reject(new Error("另一项操作仍在进行。"));
    failure = ""; mutating = true;
    if (action === "plugins.install") { installing = true; schedule(); }
    updateModeCards(); notify();
    var timeout = 60000;
    if (action === "plugins.callback") timeout = 900000;
    else if (/^plugins\.(install|update)$/.test(action)) timeout = 300000;
    return T.call(action, payload || {}, { timeoutMs: timeout }).then(function (result) {
      failure = "";
      if (isPreferencesSurface() && (action === "mode.set" || action === "mode.cancel")) {
        if (result && (result.mode === "full" || result.mode === "lite")) {
          modeStatus = {
            mode: result.mode,
            transition: result.transition || null,
            error: result.error || null
          };
          statusError = "";
          busyPolls = 0;
          schedule();
          return result;
        }
        return (statusFlight ? statusFlight.then(pollMode) : pollMode()).then(function () { return result; });
      }
      return (statusFlight ? statusFlight.then(refresh) : refresh()).then(function () { return result; });
    }).catch(function (error) {
      if (!options.localError) failure = error.message || "操作失败。";
      notify(); throw error;
    }).finally(function () {
      mutating = false;
      if (action === "plugins.install") { installing = false; schedule(); }
      updateModeCards(); notify();
    });
  }
  function setMode(mode, extra) {
    var payload = Object.assign({ mode: mode }, extra || {});
    return run("mode.set", payload);
  }
  function refreshModels(communityOnly) {
    failure = "";
    var payload = communityOnly === true ? { communityOnly: true } : {};
    return T.call("models.refresh", payload, { timeoutMs: 120000 }).then(function (catalog) {
      return refresh().then(function () { return catalog; });
    }).catch(function (error) {
      failure = error.message || "模型目录刷新失败。"; notify(); throw error;
    });
  }
  function select(tab) { if (current !== tab) failure = ""; current = titles[tab] ? tab : "service"; requested = true; notify(); }
  function leave() { requested = false; }
  function isOverlay(state) {
    if (isPreferencesSurface() || !state) return false;
    if (!status) return state.serviceConnected !== false;
    if (status.onboardingRequired) return true;
    if (status.mode === "lite") return requested || state.selectedNavigation !== "settings";
    return requested;
  }
  function modeCard() {
    var root = S.node("section", "settings-subsection"), label = S.node("p", "hint"), actions = S.node("div", "form-actions");
    var change = S.button("", null, {}, null, "small"), cancel = S.button("取消切换", null, {}, null, "small");
    var switching = false, cancelling = false, latestSettings = null;
    root.appendChild(S.node("h3", null, "运行模式")); root.appendChild(label);
    actions.appendChild(change); actions.appendChild(cancel); root.appendChild(actions);
    change.addEventListener("click", function () {
      var active = currentMode(latestSettings);
      if (!active || change.disabled) return;
      switching = true;
      if (S.setButtonPending) S.setButtonPending(change, true, "切换中…", change.textContent);
      setMode(active.mode === "lite" ? "full" : "lite").catch(function () {}).finally(function () {
        switching = false;
        if (S.setButtonPending) S.setButtonPending(change, false);
        updateModeCards();
      });
    });
    cancel.addEventListener("click", function () {
      if (cancel.disabled) return;
      cancelling = true;
      if (S.setButtonPending) S.setButtonPending(cancel, true, "取消中…", "取消切换");
      run("mode.cancel", {}).catch(function () {}).finally(function () {
        cancelling = false;
        if (S.setButtonPending) S.setButtonPending(cancel, false, null, "取消切换");
        updateModeCards();
      });
    });
    var card = { root: root, update: function (settings) {
      if (arguments.length > 0) {
        latestSettings = settings || null;
        syncHostMode(latestSettings);
      }
      var fromSettings = hostModeFromSettings(latestSettings || (hostState && hostState.settings));
      var active = currentMode(latestSettings);
      label.textContent = failure || statusError || (active && active.error) || (!active ? "正在读取模式…" : active.transition === "waiting"
        ? "正在等待工作台活动结束，期间不接受新的工作台任务。"
        : active.mode === "lite" ? "轻量模式：后台服务可独立运行。" : "完整模式：工作台与后台服务可用。");
      var nextTitle = active && active.mode === "lite" ? "切换到完整模式" : "切换到轻量模式";
      if (!switching) change.textContent = nextTitle;
      change.disabled = switching || !active || (!fromSettings && loading) || mutating || !!active.transition;
      cancel.hidden = !active || active.transition !== "waiting";
      cancel.disabled = cancelling;
    } };
    modeCards.push(card); card.update(); return card;
  }
  var sidebarToggleBound = false, sidebarSwitching = false;
  function updateSidebarToggle() {
    if (typeof document === "undefined" || !document.getElementById) return;
    var toggle = document.getElementById("sidebar-lightweight-toggle");
    if (!toggle) return;
    if (!sidebarToggleBound) {
      sidebarToggleBound = true;
      toggle.addEventListener("click", function () {
        var active = currentMode();
        if (!active || toggle.disabled || sidebarSwitching || mutating) return;
        sidebarSwitching = true;
        updateSidebarToggle();
        var action = active.transition === "waiting"
          ? run("mode.cancel", {})
          : setMode(active.mode === "lite" ? "full" : "lite");
        action.catch(function () {}).finally(function () {
          sidebarSwitching = false;
          updateModeCards();
        });
      });
    }
    var active = currentMode();
    var connected = !!(hostState && hostState.serviceConnected !== false);
    var lite = !!(active && active.mode === "lite");
    var waiting = !!(active && active.transition === "waiting");
    toggle.setAttribute("aria-checked", String(lite));
    toggle.classList.toggle("is-waiting", waiting);
    toggle.disabled = !connected || !active || sidebarSwitching || mutating || (!!active.transition && !waiting);
    var label = toggle.querySelector && toggle.querySelector(".sidebar-lightweight-label");
    if (label) label.textContent = waiting ? "等待切换…" : sidebarSwitching ? "切换中…" : "轻量模式";
  }
  function updateModeCards() { modeCards.forEach(function (card) { card.update(); }); updateSidebarToggle(); }

  function deadlineEditor(parent) {
    var details = S.node("details", "agent-details lightweight-deadline-details");
    details.appendChild(S.node("summary", null, "高级设置"));
    parent.appendChild(details);
    var form = S.node("form", "settings-stack lightweight-deadline-form");
    details.appendChild(form);
    var grid = S.node("div", "form-grid");
    form.appendChild(grid);
    var dirty = false, pending = false;
    function seconds(label) {
      var field = S.textField(label, "", "");
      field.control.type = "number"; field.control.min = "1"; field.control.max = "86400"; field.control.step = "1"; field.control.required = true;
      field.control.addEventListener("input", function () { dirty = true; });
      grid.appendChild(field.wrapper); return field.control;
    }
    var request = seconds("请求总期限（秒）"), idle = seconds("流式无数据期限（秒）");
    form.appendChild(S.node("p", "hint", "新请求使用保存的期限。活动记录最多保留 7 天或 100 MB。"));
    var actionBar = S.node("div", "form-actions");
    var save = S.button("保存期限", null, {}, null, "small primary");
    save.type = "submit"; actionBar.appendChild(save); form.appendChild(actionBar);
    form.addEventListener("submit", function (event) {
      event.preventDefault();
      if (pending || !form.reportValidity()) return;
      pending = true; request.disabled = idle.disabled = true;
      S.setButtonPending(save, true, "保存中…", "保存期限");
      run("service.setDeadlines", { requestSeconds: request.valueAsNumber, streamIdleSeconds: idle.valueAsNumber })
        .then(function () { dirty = false; S.flashButtonSuccess(save, "已保存"); }).catch(function () {
          S.setButtonPending(save, false, null, "保存期限");
        }).finally(function () {
          pending = false; save.disabled = request.disabled = idle.disabled = false; notify();
        });
    });
    return function (limits) {
      if (limits && !dirty && !pending) {
        request.value = String(limits.requestSeconds); idle.value = String(limits.streamIdleSeconds);
      }
    };
  }

  function createView() {
    var root = document.getElementById("lightweight-content"); S.clear(root);
    var notice = S.node("p", "page-message error"); notice.setAttribute("role", "status"); root.appendChild(notice);
    var loadingPanel = S.node("div", "page-card settings-stack"), retry = S.button("重试", null, {}, null, "small");
    retry.addEventListener("click", function () { S.runButtonAction(retry, "读取中…", refresh); });
    loadingPanel.appendChild(S.node("p", "hint", "正在读取服务状态…")); loadingPanel.appendChild(retry); root.appendChild(loadingPanel);
    var onboarding = S.node("div", "settings-stack"), intro = S.section(onboarding, "选择使用方式");
    intro.classList.add("lightweight-service-card");
    intro.appendChild(S.node("p", "hint", "两种模式使用同一份供应商和接入配置，之后可在设置中切换。"));
    var onboardingActions = S.node("div", "form-actions");
    var connectAgent = S.button("连接我的 Agent", null, {}, null, "small");
    var openWorkbench = S.button("使用 Bridge 工作台", null, {}, null, "small primary");
    connectAgent.addEventListener("click", function () { S.runButtonAction(connectAgent, "准备中…", function () { return run("onboarding.complete", { mode: "lite" }).catch(function () {}); }); });
    openWorkbench.addEventListener("click", function () { S.runButtonAction(openWorkbench, "打开中…", function () { return run("onboarding.complete", { mode: "full" }).catch(function () {}); }); });
    onboardingActions.appendChild(openWorkbench); onboardingActions.appendChild(connectAgent); intro.appendChild(onboardingActions);
    root.appendChild(onboarding);
    var service = S.node("div", "lightweight-service-grid"), serviceSection = S.section(service, "模型网关");
    serviceSection.classList.add("lightweight-service-card");
    var gatewayHead = S.node("div", "service-panel-head"), gatewayTitleRow = S.node("div", "plugin-card-title-row");
    var gatewayBadge = S.badge("读取中", "neutral");
    gatewayTitleRow.appendChild(serviceSection.firstChild); gatewayTitleRow.appendChild(gatewayBadge);
    var gatewayAction = S.button("", null, {}, null, "small");
    gatewayHead.appendChild(gatewayTitleRow); gatewayHead.appendChild(gatewayAction);
    serviceSection.appendChild(gatewayHead);
    var gatewayStatus = S.node("p", "hint"), gatewayAddress = S.node("code", "connection-endpoint-value mono");
    serviceSection.appendChild(gatewayStatus); serviceSection.appendChild(gatewayAddress);
    gatewayAction.addEventListener("click", function () {
      if (!status || gatewayAction.disabled) return;
      var stopping = !!status.gateway.enabled;
      S.runButtonAction(gatewayAction, stopping ? "停止中…" : "启动中…", function () {
        return run("service.setEnabled", { enabled: !stopping }).catch(function () {});
      });
    });
    var updateDeadlines = deadlineEditor(serviceSection);
    var mcpSection = S.section(service, "MCP 服务");
    mcpSection.classList.add("lightweight-service-card");
    var mcpHead = S.node("div", "service-panel-head"), mcpTitleRow = S.node("div", "plugin-card-title-row");
    var mcpBadge = S.badge("读取中", "neutral"), mcpAction = S.button("管理应用接入", null, {}, null, "small");
    mcpTitleRow.appendChild(mcpSection.firstChild); mcpTitleRow.appendChild(mcpBadge);
    mcpHead.appendChild(mcpTitleRow); mcpHead.appendChild(mcpAction);
    mcpSection.appendChild(mcpHead);
    var mcpStatus = S.node("p", "hint", "为本机与云端聊天客户端提供项目文件与工具调用。");
    mcpAction.addEventListener("click", function () { select("clients"); });
    mcpSection.appendChild(mcpStatus);
    var modeSection = modeCard(); modeSection.root.classList.add("lightweight-service-card");
    service.appendChild(modeSection.root); root.appendChild(service);
    var suppliers = S.node("div", "lightweight-suppliers"), supplierEditor = null;
    var pluginEditor = global.CodexBridgeDesktopLightweightPlugins.create({
      root: suppliers, run: run, refreshModels: refreshModels, transport: T,
      refreshStatus: function () { return statusFlight ? statusFlight.then(refresh) : refresh(); },
      openClients: function () { select("clients"); }
    });
    root.appendChild(suppliers);
    var clients = S.node("div", "settings-stack"), clientEditor = global.CodexBridgeDesktopLightweightClients.create({
      root: clients, run: run, refreshModels: refreshModels,
      refreshStatus: function () { return statusFlight ? statusFlight.then(refresh) : refresh(); },
      openSuppliers: function () { select("suppliers"); },
      registerProject: function () { emitter("registerProject", {}); },
      emit: function (command, payload) {
        if (command === "selectPage" && payload && payload.navigation === "settings") leave();
        emitter(command, payload);
      },
      copy: function (id) { return T.call("clients.configuration", { id: id }, { command: "providerGatewayCopyConnection" }); }
    });
    root.appendChild(clients);
    var activity = S.node("div", "lightweight-service-grid"), live = S.node("p", "page-message"); activity.appendChild(live);
    var approvals = S.section(activity, "待审批"); approvals.classList.add("lightweight-service-card");
    var approvalList = S.node("div"); approvals.appendChild(approvalList);
    var recent = S.section(activity, "最近活动"); recent.classList.add("lightweight-service-card");
    var recentList = S.node("div", "lightweight-activity-list"); recent.appendChild(recentList);
    root.appendChild(activity);
    return { root: root, notice: notice, loadingPanel: loadingPanel, retry: retry, onboarding: onboarding,
      onboardingActions: [connectAgent, openWorkbench], service: service,
      updateDeadlines: updateDeadlines, gatewayStatus: gatewayStatus, gatewayBadge: gatewayBadge,
      gatewayAddress: gatewayAddress, gatewayAction: gatewayAction, mcpBadge: mcpBadge, mcpStatus: mcpStatus,
      suppliers: suppliers, supplierEditor: supplierEditor, pluginEditor: pluginEditor,
      clients: clients, clientEditor: clientEditor, activity: activity, live: live, approvals: approvals,
      approvalList: approvalList, recentList: recentList, activitySignature: "" };
  }
  function updateService() {
    var gateway = status.gateway || {};
    view.updateDeadlines(status.deadlines);
    var badgeLabel = gateway.running ? "运行中" : gateway.enabled ? "正在启动" : "已停止";
    var badgeTone = gateway.running ? "success" : gateway.enabled ? "running" : "neutral";
    view.gatewayBadge.textContent = badgeLabel;
    view.gatewayBadge.className = "status-badge " + badgeTone;
    view.gatewayStatus.textContent = gateway.running ? (gateway.active || 0) + " 个请求处理中 · "
      + (gateway.queued || 0) + " 个排队" : gateway.enabled ? "正在启动本机模型网关…" : "按需启动后可为接入应用转发模型请求。";
    view.gatewayAddress.textContent = gateway.url || ""; view.gatewayAddress.hidden = !gateway.url;
    if (view.gatewayAction.dataset.pending !== "true") {
      S.syncButtonLabel(view.gatewayAction, gateway.enabled ? "停止模型网关" : "启动模型网关");
    }
    view.gatewayAction.disabled = loading || view.gatewayAction.dataset.pending === "true";
    var mcp = hostState && hostState.connections && hostState.connections.localMCPState;
    view.mcpBadge.textContent = mcp === "ready" ? "本机服务就绪" : mcp ? "未就绪" : "暂不可用";
    view.mcpBadge.className = "status-badge " + (mcp === "ready" ? "success" : mcp ? "warning" : "neutral");
    view.mcpStatus.textContent = mcp === "ready" ? "本机 MCP 通道运行正常，可授权给桌面或命令行客户端。"
      : mcp ? "本机服务尚未就绪，请检查后台服务状态。" : "等待读取本机 MCP 服务状态。";
  }
  function updateActivity() {
    var gateway = status.gateway || {};
    view.live.textContent = "网关实时状态：正在处理 " + (gateway.active || 0) + " 个模型请求 · " + (gateway.queued || 0) + " 个排队";
    var direct = S.safeArray(hostState && hostState.workbench && hostState.workbench.approvals).filter(function (item) { return item.isDirect; });
    view.approvals.hidden = !direct.length;
    global.CodexBridgeDesktopWorkbenchApprovals.render({ approvals: direct }, emitter, view.approvalList);
    var entries = S.safeArray(status.activity), signature = JSON.stringify(entries);
    if (view.activitySignature === signature) return;
    view.activitySignature = signature; S.clear(view.recentList);
    if (!entries.length) view.recentList.appendChild(S.node("p", "hint lightweight-empty-note", "暂无请求活动记录。"));
    entries.forEach(function (item) {
      var row = S.node("div", "lightweight-activity-row"), main = S.node("div", "lightweight-activity-main");
      var titleRow = S.node("div", "plugin-card-title-row");
      titleRow.appendChild(S.node("strong", "plugin-card-title", item.model || item.title || "请求"));
      var outcome = { completed: "已完成", failed: "失败", cancelled: "已取消", running: "运行中", queued: "排队中" }[item.state] || item.state;
      var tone = item.state === "completed" ? "success" : item.state === "failed" ? "error" : item.state === "running" ? "running" : "neutral";
      titleRow.appendChild(S.badge(outcome, tone));
      main.appendChild(titleRow);
      var duration = typeof item.durationMS === "number" ? (item.durationMS / 1000).toFixed(1) + " 秒" : "";
      var usage = item.usage || {}, usageText = "";
      if (item.state !== "queued" && item.state !== "running") {
        if (usage.status === "unavailable") usageText = "Token 用量读取失败";
        else if (usage.status !== "provided" && usage.status !== "partial") usageText = "Token 用量未提供";
        else {
          var missingUsage = usage.status === "partial" ? "未能读取" : "未提供";
          usageText = (usage.status === "partial" ? "部分用量读取失败 · " : "")
            + "输入 " + (usage.inputTokens == null ? missingUsage : usage.inputTokens)
            + " · 输出 " + (usage.outputTokens == null ? missingUsage : usage.outputTokens) + " Token";
          if (usage.totalTokens != null) usageText += " · 合计 " + usage.totalTokens;
          if (usage.cacheReadTokens != null) usageText += " · 缓存读取 " + usage.cacheReadTokens;
          if (usage.cacheWriteTokens != null) usageText += " · 缓存写入 " + usage.cacheWriteTokens;
          if (usage.reasoningTokens != null) usageText += " · 推理 " + usage.reasoningTokens;
        }
      }
      main.appendChild(S.node("span", "hint", [item.clientID, item.providerID, usageText].filter(Boolean).join(" · ")));
      row.appendChild(main);
      var meta = S.node("span", "lightweight-activity-meta mono", [duration, item.date].filter(Boolean).join(" · "));
      row.appendChild(meta);
      view.recentList.appendChild(row);
    });
  }
  function render(state) {
    if (!view) view = createView();
    var pageContainer = document.getElementById && document.getElementById("lightweight-page");
    if (pageContainer && pageContainer.dataset) {
      pageContainer.dataset.tab = status && status.onboardingRequired ? "onboarding" : current;
    }
    var message = failure || statusError || (current === "activity" && status && status.activityError) || "";
    view.notice.textContent = message; view.notice.hidden = !message;
    view.loadingPanel.hidden = !!status; view.retry.hidden = !statusError;
    [view.onboarding, view.service, view.suppliers, view.clients, view.activity].forEach(function (node) { node.hidden = true; });
    var onSuppliers = !!status && !status.onboardingRequired && current === "suppliers";
    if (view.supplierEditor) view.supplierEditor.setActive(onSuppliers);
    if (!status) return;
    if (status.onboardingRequired) {
      view.onboarding.hidden = false;
      view.onboardingActions.forEach(function (action) { action.disabled = mutating; });
      return;
    }
    if (current === "service") { view.service.hidden = false; updateService(); }
    if (onSuppliers) {
      view.suppliers.hidden = false;
      if (!view.supplierEditor) {
        view.supplierEditor = global.CodexBridgeDesktopEmbeddedDSHSettings.create(function () {
          return refreshModels().then(function (next) { return S.safeArray(next && next.models).length; });
        }, null, null, { providersOnly: true, transport: T.supplierTransport() });
        view.suppliers.insertBefore(view.supplierEditor.root, view.suppliers.firstChild); view.supplierEditor.setActive(true);
      }
      view.pluginEditor.update(status);
    }
    if (current === "clients") { view.clients.hidden = false; view.clientEditor.update(status, state); }
    if (current === "activity") { view.activity.hidden = false; updateActivity(); }
    updateModeCards();
  }
  function deactivate() { if (view && view.supplierEditor) view.supplierEditor.setActive(false); }
  if (document.addEventListener) document.addEventListener("visibilitychange", function () {
    if (document.visibilityState !== "hidden") {
      if (isPreferencesSurface()) {
        if (needsModePoll()) void pollMode();
      } else {
        void poll();
      }
    } else if (timer) { global.clearTimeout(timer); timer = null; }
  });
  global.CodexBridgeDesktopLightweight = { configure: configure, refresh: refresh, run: run,
    select: select, leave: leave, isOverlay: isOverlay, render: render, deactivate: deactivate,
    modeCard: modeCard, mode: function () { var active = currentMode(); return active && active.mode; }, tab: function () { return current; },
    title: function () { return status && status.onboardingRequired ? "欢迎使用" : titles[current]; } };
}(window));
