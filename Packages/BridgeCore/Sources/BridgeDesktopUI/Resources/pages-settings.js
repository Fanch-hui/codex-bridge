(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  var D = global.CodexBridgeDesktopFormDraft;
  var pendingDetail = null, latestEmit = null, agentMounts = new Map();
  var latestClients = [];

  function create(container, page, emit, updateState) {
    S.clear(container);
    var header = S.node("div");
    container.appendChild(header);
    var content = S.node("div", "settings-content-stack");
    container.appendChild(content);
    var navigation = global.CodexBridgeDesktopSettingsNavigation.create(content, page, emit);
    var approvalEditor = approvalCard(page, emit);
    navigation.execution.appendChild(approvalEditor.root);
    var clients = global.CodexBridgeDesktopConnectionsClients
      ? global.CodexBridgeDesktopConnectionsClients.create(emit, { mode: "permissions" }) : null;
    if (clients) {
      var clientSection = S.node("section", "settings-subsection settings-client-permissions");
      clientSection.appendChild(S.node("h3", null, "客户端权限"));
      clientSection.appendChild(S.node("p", "hint", "控制每个客户端可调用的 MCP 工具。"));
      clientSection.appendChild(clients.root);
      navigation.execution.insertBefore(clientSection, navigation.execution.firstChild);
    }
    var serviceEditor = serviceCard(page, emit);
    navigation.application.appendChild(serviceEditor.root);
    navigation.diagnostics.insertBefore(serviceEditor.diagnosticsRoot, navigation.diagnostics.firstChild);
    var appUpdate = global.CodexBridgeDesktopAppUpdate
      ? global.CodexBridgeDesktopAppUpdate.createSettings(updateState, emit) : null;
    if (appUpdate) navigation.application.appendChild(appUpdate.root);
    var status = S.node("div", "page-message");
    status.setAttribute("role", "status");
    container.appendChild(status);
    var unavailable = S.node("div");
    S.empty(unavailable, "设置页暂不可用", "连接后台服务后，可以配置权限、审批与应用。");
    container.appendChild(unavailable);
    return {
      details: navigation.details, mountAgent: navigation.mountAgent,
      updateClients: function (items, nextEmit) { if (clients) clients.update(items, nextEmit); },
      update: function (next, nextEmit, nextUpdateState) {
        content.hidden = !next;
        unavailable.hidden = !!next;
        S.pageHeader(header, next ? Object.assign({}, next.header, { subtitle: "" }) : { title: "设置", symbol: "gearshape" });
        if (appUpdate) appUpdate.update(nextUpdateState, nextEmit);
        if (!next) { status.hidden = true; return; }
        navigation.update(next, nextEmit);
        agentMounts.forEach(function (target, id) { navigation.mountAgent(id, target); });
        if (clients) clients.update(latestClients, nextEmit);
        approvalEditor.update(next, nextEmit);
        serviceEditor.update(next, nextEmit);
        status.textContent = next.statusMessage || "";
        status.hidden = !next.statusMessage;
      }
    };
  }

  function render(page, emit, updateState) {
    latestEmit = emit;
    var container = document.getElementById("settings-content");
    if (!container) return;
    if (!container.__settingsEditor && !page) {
      S.empty(container, "设置页暂不可用", "连接后台服务后，可以配置权限、审批与应用。");
      return;
    }
    if (!container.__settingsEditor) container.__settingsEditor = create(container, page, emit, updateState);
    container.__settingsEditor.update(page, emit, updateState);
    if (pendingDetail) { container.__settingsEditor.details.open(pendingDetail); pendingDetail = null; }
  }

  function approvalCard(page, emit) {
    var context = { page: page, emit: emit };
    var card = S.node("section", "settings-subsection settings-approval");
    card.appendChild(S.node("h3", null, "安全审批策略"));
    var direct = S.selectField("Direct 操作", page.directApprovalMode, S.choices(page.directApprovalMode, page.directApprovalOptions), function (value) {
      context.emit("setDirectApprovalMode", { mode: value });
    }, "");
    var task = S.selectField("远程任务启动", page.taskStartApprovalMode, S.choices(page.taskStartApprovalMode, page.taskStartApprovalOptions), function (value) {
      context.emit("setTaskStartApprovalMode", { mode: value });
    }, "");
    var fields = S.node("div", "form-grid settings-policy-grid");
    fields.appendChild(direct.wrapper);
    fields.appendChild(task.wrapper);
    card.appendChild(fields);
    var draft = D.bind({ direct: direct.control, task: task.control });
    function update(next, nextEmit) {
      context.page = next;
      context.emit = nextEmit;
      D.selectOptions(direct.control, S.choices(next.directApprovalMode, next.directApprovalOptions));
      D.selectOptions(task.control, S.choices(next.taskStartApprovalMode, next.taskStartApprovalOptions));
      draft.update({ direct: next.directApprovalMode || "", task: next.taskStartApprovalMode || "" });
      direct.control.disabled = !next.canSaveApprovalModes;
      task.control.disabled = !next.canSaveApprovalModes;
    }
    update(page, emit);
    return { root: card, update: update };
  }

  function serviceCard(page, emit) {
    var context = { page: page, emit: emit };
    var card = S.node("section", "settings-subsection settings-service");
    card.appendChild(S.node("h3", null, "退出 App 后继续运行服务"));
    var description = S.node("p", "hint");
    var keepRow = S.node("div", "check-field");
    var keep = S.node("button", "switch-toggle");
    keep.type = "button";
    keep.value = page.keepServiceRunningAfterExit ? "true" : "false";
    keep.setAttribute("role", "switch");
    keep.setAttribute("aria-label", "退出 App 后继续运行");
    var thumb = S.node("span", "switch-thumb");
    thumb.setAttribute("aria-hidden", "true");
    keep.appendChild(thumb);
    keepRow.appendChild(keep);
    keepRow.appendChild(S.node("span", null, "继续运行后台服务"));
    var keepDraft = D.bind({ keep: keep });
    function updateSwitch() {
      keep.className = "switch-toggle" + (keep.value === "true" ? " is-active" : "");
      keep.setAttribute("aria-checked", keep.value);
    }
    keep.addEventListener("click", function () {
      keep.value = keep.value === "true" ? "false" : "true";
      updateSwitch();
      context.emit("setKeepServiceRunning", { keepServiceRunningAfterExit: keep.value === "true" });
    });
    card.appendChild(keepRow);
    card.appendChild(description);
    var diagnostics = S.node("section", "settings-subsection settings-service-diagnostics");
    diagnostics.appendChild(S.node("h3", null, "后台服务"));
    var badge = S.badge("未注册", "warning");
    diagnostics.appendChild(badge);
    var serviceStatus = S.node("p", "hint"); diagnostics.appendChild(serviceStatus);
    var actions = S.node("div", "form-actions"); diagnostics.appendChild(actions);
    function update(next, nextEmit) {
      context.page = next;
      context.emit = nextEmit;
      description.textContent = "退出后仍可通过 ChatGPT / Qwen / Gemini 使用本机。无人值守运行需将相关审批设为自动批准。";
      keepDraft.update({ keep: next.keepServiceRunningAfterExit ? "true" : "false" });
      updateSwitch();
      var needsAttention = next.serviceStatus
        ? next.serviceStatus !== "enabled" : !next.serviceRegistered;
      badge.textContent = next.serviceStatusTitle || (next.serviceRegistered ? "已注册" : "未注册");
      badge.className = "status-badge " + serviceTone(next);
      badge.hidden = !needsAttention;
      serviceStatus.textContent = next.serviceStatusMessage || "";
      serviceStatus.hidden = !next.serviceStatusMessage;
      S.clear(actions);
      var availableActions = next.serviceStatus === "requires_approval"
        && Array.isArray(next.serviceActions) ? next.serviceActions : [];
      availableActions.forEach(function (action) {
        if (!action || action.command !== "openSystemSettings" || !action.title) return;
        var control = S.button(action.title, null, {}, null, "small", false);
        control.addEventListener("click", function () {
          context.emit(action.command, {});
        });
        actions.appendChild(control);
      });
      actions.hidden = actions.children.length === 0;
    }
    update(page, emit);
    return { root: card, diagnosticsRoot: diagnostics, update: update };
  }

  function serviceTone(page) {
    if (page.serviceStatusTone) return page.serviceStatusTone;
    if (page.serviceStatus === "not_found") return "error";
    if (page.serviceStatus === "requires_approval") return "warning";
    return page.serviceRegistered ? "success" : "warning";
  }

  function openDetail(id, emit) {
    pendingDetail = id;
    (emit || latestEmit)("selectPage", { navigation: "settings" });
    var container = document.getElementById("settings-content");
    if (container && container.__settingsEditor) {
      container.__settingsEditor.details.open(id); pendingDetail = null;
    }
  }
  function mountAgent(id, target) {
    agentMounts.set(id, target);
    var container = document.getElementById("settings-content");
    if (container && container.__settingsEditor) container.__settingsEditor.mountAgent(id, target);
  }
  function updateClients(items, emit) {
    latestClients = S.safeArray(items);
    var container = document.getElementById("settings-content");
    if (container && container.__settingsEditor) container.__settingsEditor.updateClients(latestClients, emit);
  }
  global.CodexBridgeDesktopSettingsPage = {
    render: render, openDetail: openDetail, mountAgent: mountAgent, updateClients: updateClients
  };
}(window));
