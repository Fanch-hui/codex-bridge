(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  var D = global.CodexBridgeDesktopFormDraft;
  var M = global.CodexBridgeDesktopSettingsModels;

  function group(container, title) {
    var section = S.section(container, title);
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
    var models = group(content, "模型与执行默认偏好");
    var preferences = M.preferences(page, emit);
    var supervisor = M.supervisor(page, emit);
    var agents = global.CodexBridgeDesktopSettingsAgents.create(page, emit);
    models.appendChild(preferences.root);
    models.appendChild(supervisor.root);
    models.appendChild(agents.root);
    var native = global.CodexBridgeDesktopSettingsNative.create();
    models.appendChild(native.root);
    var direct = global.CodexBridgeDesktopDirect.create();
    content.appendChild(direct.root);
    var safety = group(content, "安全策略与全局指令");
    var approvals = S.node("div");
    safety.appendChild(approvals);
    var approvalEditor = approvalCard(page, emit);
    approvals.appendChild(approvalEditor.root);
    var instructions = global.CodexBridgeDesktopSettingsInstructions.create(page, emit);
    safety.appendChild(instructions.root);
    var service = group(content, "后台运行与远程授权");
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
        supervisor.root.hidden = !next.supervisorAvailable;
        supervisor.update(next, nextEmit);
        agents.update(next, nextEmit);
        instructions.update(next, nextEmit);
        native.update(next.nativePermissionPolicy, nextEmit);
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
    var card = S.node("section", "page-card settings-card");
    card.appendChild(S.node("h3", null, "后台服务"));
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
    var actions = S.node("div", "form-actions");
    card.appendChild(actions);
    function update(next, nextEmit) {
      context.page = next;
      context.emit = nextEmit;
      description.textContent = next.serviceDescription || "";
      platform.textContent = "平台：" + (next.servicePlatform || "未知");
      keepDraft.update({ keep: next.keepServiceRunningAfterExit == null
        ? false : next.keepServiceRunningAfterExit });
      keep.control.disabled = !next.canChangeService;
      badge.textContent = next.serviceRegistered ? "已注册" : "未注册";
      badge.className = "status-badge " + (next.serviceRegistered ? "success" : "warning");
      S.clear(actions);
      if (!next.canChangeService) return;
      if (next.serviceRegistered) {
        var unregister = S.button("注销后台服务", null, {}, null, "small danger", false);
        unregister.addEventListener("click", function () {
          if (global.confirm("停用后台 Service？退出 App 后将无法继续响应远程请求。")) {
            context.emit("unregisterService", {});
          }
        });
        actions.appendChild(unregister);
      } else {
        var register = S.button("注册后台服务", null, {}, null, "small primary", false);
        register.addEventListener("click", function () { context.emit("registerService", {}); });
        actions.appendChild(register);
      }
    }
    update(page, emit);
    return { root: card, update: update };
  }

  global.CodexBridgeDesktopSettingsPage = { render: render };
}(window));
