(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  var D = global.CodexBridgeDesktopFormDraft;
  var M = global.CodexBridgeDesktopSettingsModels;

  function group(container, title, className) {
    var section = S.section(container, title);
    if (className) section.className += " " + className;
    var stack = S.node("div", "settings-stack");
    section.appendChild(stack);
    return stack;
  }

  function create(container, page, emit) {
    S.clear(container);
    var header = S.node("div");
    container.appendChild(header);
    var content = S.node("div", "settings-content-stack");
    container.appendChild(content);
    var models = group(content, "Agent模型与权限", "page-card settings-card");
    var preferences = M.preferences(page, emit, true);
    var agents = global.CodexBridgeDesktopSettingsAgents.create(page, emit, true);
    models.appendChild(preferences.root);
    models.appendChild(agents.root);
    var direct = global.CodexBridgeDesktopDirect.create();
    content.appendChild(direct.root);
    var safety = group(content, "GPT/Qwen的mcp插件权限与指令");
    var approvals = S.node("div");
    safety.appendChild(approvals);
    var approvalEditor = approvalCard(page, emit);
    approvals.appendChild(approvalEditor.root);
    var instructions = global.CodexBridgeDesktopSettingsInstructions.create(page, emit);
    safety.appendChild(instructions.root);
    var service = group(content, "退出 App 后继续运行服务", "page-card settings-card");
    var status = S.node("div", "page-message");
    content.appendChild(status);
    var serviceEditor = serviceCard(page, emit);
    service.appendChild(serviceEditor.root);
    var unavailable = S.node("div");
    S.empty(unavailable, "设置页暂不可用", "连接本机 Service 后，可以配置模型、安全审批与后台服务。");
    container.appendChild(unavailable);
    return {
      update: function (next, nextEmit) {
        content.hidden = !next;
        unavailable.hidden = !!next;
        S.pageHeader(header, next ? next.header : { title: "设置", subtitle: "正在从本机 Service 读取偏好设置。", symbol: "gearshape" });
        if (!next) return;
        direct.update(next.direct, nextEmit);
        preferences.update(next, nextEmit);
        agents.update(next, nextEmit);
        instructions.update(next, nextEmit);
        approvalEditor.update(next, nextEmit);
        serviceEditor.update(next, nextEmit);
        status.textContent = next.statusMessage || "";
        status.hidden = !next.statusMessage;
      }
    };
  }

  function render(page, emit) {
    var container = document.getElementById("settings-content");
    if (!container.__settingsEditor && !page) {
      S.empty(container, "设置页暂不可用", "连接本机 Service 后，可以配置模型、安全审批与后台服务。");
      return;
    }
    if (!container.__settingsEditor) container.__settingsEditor = create(container, page, emit);
    container.__settingsEditor.update(page, emit);
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
    card.appendChild(S.node("p", "hint", "策略仍由本机 Service 和项目权限强制执行。"));
    function update(next, nextEmit) {
      context.page = next;
      context.emit = nextEmit;
      D.selectOptions(direct.control, S.choices(next.directApprovalMode, next.directApprovalOptions));
      D.selectOptions(task.control, S.choices(next.taskStartApprovalMode, next.taskStartApprovalOptions));
      direct.control.value = next.directApprovalMode || "";
      task.control.value = next.taskStartApprovalMode || "";
      direct.control.disabled = !next.canSaveApprovalModes;
      task.control.disabled = !next.canSaveApprovalModes;
    }
    update(page, emit);
    return { root: card, update: update };
  }

  function serviceCard(page, emit) {
    var context = { page: page, emit: emit };
    var card = S.node("div", "settings-subsection");
    var description = S.node("p", "hint");
    var platform = S.node("p", "hint");
    card.appendChild(description);
    card.appendChild(platform);
    var keep = M.check("退出 App 后继续运行", page.keepServiceRunningAfterExit);
    var keepDraft = D.bind({ keep: keep.control });
    keep.wrapper.querySelector("input").addEventListener("change", function () {
      context.emit("setKeepServiceRunning", { keepServiceRunningAfterExit: keep.control.checked });
    });
    card.appendChild(keep.wrapper);
    var badge = S.badge("未注册", "warning");
    card.appendChild(badge);
    var serviceStatus = S.node("p", "hint");
    card.appendChild(serviceStatus);
    var actions = S.node("div", "form-actions");
    card.appendChild(actions);
    function update(next, nextEmit) {
      context.page = next;
      context.emit = nextEmit;
      description.textContent = next.serviceDescription
        || "开启后可在退出 App 后继续运行后台 Service，远程给本机发送任务时需同时将“远程任务启动”设为“自动批准”。";
      platform.textContent = "平台：" + (next.servicePlatform || "未知");
      keepDraft.update({ keep: next.keepServiceRunningAfterExit == null
        ? false : next.keepServiceRunningAfterExit });
      keep.control.disabled = false;
      badge.textContent = next.serviceStatusTitle || (next.serviceRegistered ? "已注册" : "未注册");
      badge.className = "status-badge " + serviceTone(next);
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
