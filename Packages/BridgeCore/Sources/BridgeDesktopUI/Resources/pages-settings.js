(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  var D = global.CodexBridgeDesktopFormDraft;

  function create(container, page, emit, updateState) {
    S.clear(container);
    var header = S.node("div");
    container.appendChild(header);
    var content = S.node("div", "settings-content-stack");
    container.appendChild(content);
    var navigation = global.CodexBridgeDesktopSettingsNavigation.create(content, page, emit);
    var approvalEditor = approvalCard(page, emit);
    navigation.execution.appendChild(approvalEditor.root);
    var serviceEditor = serviceCard(page, emit);
    navigation.application.appendChild(serviceEditor.root);
    var appUpdate = global.CodexBridgeDesktopAppUpdate
      ? global.CodexBridgeDesktopAppUpdate.createSettings(updateState, emit) : null;
    if (appUpdate) navigation.application.appendChild(appUpdate.root);
    var status = S.node("div", "page-message");
    status.setAttribute("role", "status");
    container.appendChild(status);
    var unavailable = S.node("div");
    S.empty(unavailable, "设置页暂不可用", "连接本机 Service 后，可以配置模型、安全审批与后台服务。");
    container.appendChild(unavailable);
    return {
      details: navigation.details,
      update: function (next, nextEmit, nextUpdateState) {
        content.hidden = !next;
        unavailable.hidden = !!next;
        S.pageHeader(header, next ? next.header : { title: "设置", symbol: "gearshape" });
        if (appUpdate) appUpdate.update(nextUpdateState, nextEmit);
        if (!next) { status.hidden = true; return; }
        navigation.update(next, nextEmit);
        approvalEditor.update(next, nextEmit);
        serviceEditor.update(next, nextEmit);
        status.textContent = next.statusMessage || "";
        status.hidden = !next.statusMessage;
      }
    };
  }

  function render(page, emit, updateState) {
    var container = document.getElementById("settings-content");
    if (!container.__settingsEditor && !page) {
      S.empty(container, "设置页暂不可用", "连接本机 Service 后，可以配置模型、安全审批与后台服务。");
      return;
    }
    if (!container.__settingsEditor) container.__settingsEditor = create(container, page, emit, updateState);
    container.__settingsEditor.update(page, emit, updateState);
  }

  function approvalCard(page, emit) {
    var context = { page: page, emit: emit };
    var card = S.node("section", "page-card settings-card");
    card.appendChild(S.node("h3", null, "安全审批策略"));
    var direct = S.selectField("Direct 操作", page.directApprovalMode, S.choices(page.directApprovalMode, page.directApprovalOptions), function (value) {
      context.emit("setDirectApprovalMode", { mode: value });
    }, "");
    var task = S.selectField("远程任务启动", page.taskStartApprovalMode, S.choices(page.taskStartApprovalMode, page.taskStartApprovalOptions), function (value) {
      context.emit("setTaskStartApprovalMode", { mode: value });
    }, "");
    card.appendChild(direct.wrapper);
    card.appendChild(task.wrapper);
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
    var card = S.node("section", "settings-subsection");
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
    keepRow.appendChild(S.node("span", null, "退出 App 后继续运行"));
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
    var badge = S.badge("未注册", "warning");
    card.appendChild(badge);
    var serviceStatus = S.node("p", "hint");
    card.appendChild(serviceStatus);
    var actions = S.node("div", "form-actions");
    card.appendChild(actions);
    function update(next, nextEmit) {
      context.page = next;
      context.emit = nextEmit;
      description.textContent = "退出后仍可通过 ChatGPT / Qwen 使用本机。无人值守运行需将相关审批设为自动批准。";
      keepDraft.update({ keep: next.keepServiceRunningAfterExit ? "true" : "false" });
      updateSwitch();
      var needsAttention = next.serviceStatus
        ? next.serviceStatus !== "enabled" : !next.serviceRegistered;
      badge.textContent = next.serviceStatusTitle || (next.serviceRegistered ? "已注册" : "未注册");
      badge.className = "status-badge " + serviceTone(next);
      badge.hidden = !needsAttention;
      serviceStatus.textContent = next.serviceStatusMessage || "";
      serviceStatus.hidden = !needsAttention || !next.serviceStatusMessage;
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
    return { root: card, update: update };
  }

  function serviceTone(page) {
    if (page.serviceStatusTone) return page.serviceStatusTone;
    if (page.serviceStatus === "not_found") return "error";
    if (page.serviceStatus === "requires_approval") return "warning";
    return page.serviceRegistered ? "success" : "warning";
  }

  global.CodexBridgeDesktopSettingsPage = { render: render };
}(window));
