(function (global) {
  "use strict";

  var S = global.CodexBridgeDesktopPageSupport;
  var D = global.CodexBridgeDesktopFormDraft;
  var modes = {
    "default": {
      title: "请求批准",
      detail: "Qoder 的敏感操作会通过 Bridge 请求确认。"
    },
    "auto": {
      title: "帮我批准",
      detail: "由 Qoder 自动判断允许或拒绝；安全的工作区编辑可能直接执行。需要在 Qoder 信任的目录中生效。"
    },
    "bypass_permissions": {
      title: "允许完全访问",
      detail: "跳过 Qoder 逐项权限确认；Bridge 仍执行任务权限与项目目录边界。需要在 Qoder 信任的目录中生效。"
    }
  };

  function create() {
    var root = S.node("section", "settings-subsection");
    root.appendChild(S.node("h4", null, "Qoder 执行权限"));
    var context = { policy: null, emit: null };
    var installation = S.selectField("Qoder 安装与地区", "", [], function (installationID) {
      if (installationID !== context.policy.installationID) {
        context.emit("refreshAgentNativePermission", { installationID: installationID });
      }
    }, "");
    var permission = S.selectField("权限模式", "default", [], function (modeID) {
      var policy = context.policy;
      var option = S.safeArray(policy.availableModes).find(function (item) { return item.modeID === modeID; });
      if (!option || modeID === policy.toolPermission) return;
      var confirmed = !option.requiresConfirmation || global.confirm(
        "启用“" + (modes[modeID] ? modes[modeID].title : option.displayName) + "”？\n\n"
          + policyScope(policy) + "\nBridge 的任务权限与项目目录边界仍然生效。"
      );
      if (!confirmed) { permission.control.value = policy.toolPermission; return; }
      context.emit("setAgentNativePermissionMode", {
        installationID: policy.installationID, toolPermission: modeID,
        confirmed: option.requiresConfirmation === true
      });
    }, "");
    var draft = D.bind({ installation: installation.control, permission: permission.control });
    var detail = S.node("p", "hint"), scope = S.node("p", "hint"), error = S.node("p", "hint");
    [installation.wrapper, permission.wrapper, detail, scope, error].forEach(function (node) { root.appendChild(node); });

    function update(page, emit) {
      var policy = page && page.nativePermissionPolicy;
      root.hidden = !policy || policy.providerID !== "qoder";
      if (root.hidden) return;
      var identityChanged = context.policy && context.policy.installationID !== policy.installationID;
      context.policy = policy;
      context.emit = emit;
      var choices = S.safeArray(policy.availableModes).filter(function (mode) {
        return modes[mode.modeID] || mode.modeID === policy.toolPermission;
      }).map(function (mode) {
        return { id: mode.modeID, title: modes[mode.modeID] ? modes[mode.modeID].title : mode.displayName };
      });
      Object.keys(modes).forEach(function (modeID) {
        if (!choices.some(function (choice) { return choice.id === modeID; })) {
          choices.push({ id: modeID, title: modes[modeID].title });
        }
      });
      var installations = S.safeArray(policy.installations);
      D.selectOptions(installation.control, installations);
      D.selectOptions(permission.control, choices);
      var values = { installation: policy.installationID, permission: policy.toolPermission || "default" };
      if (identityChanged) draft.reset(values); else draft.update(values);
      installation.wrapper.hidden = installations.length < 2;
      installation.control.disabled = policy.isLoading || policy.isSaving;
      permission.control.disabled = !policy.canEdit || policy.isLoading || policy.isSaving;
      var selectedMode = modes[policy.toolPermission];
      detail.textContent = selectedMode ? selectedMode.detail : modeDetail(policy.toolPermission);
      if (policy.toolPermission && policy.toolPermission !== "default" && !selectedMode) {
        detail.textContent += " 需要在 Qoder 信任的目录中生效。";
      }
      scope.textContent = policyScope(policy);
      error.textContent = policy.errorMessage || "";
      error.hidden = !policy.errorMessage;
    }

    return { root: root, update: update };
  }

  function modeDetail(modeID) {
    if (modes[modeID]) return modes[modeID].detail;
    var details = {
      accept_edits: "自动接受工作区内编辑；命令和其他敏感操作仍按 Qoder 规则处理。",
      plan: "使用 Qoder 计划模式。",
      dont_ask: "不显示批准请求；需要批准的操作会被拒绝。"
    };
    return details[modeID] || "当前 Qoder 权限模式由地区原生设置提供。";
  }

  function policyScope(policy) {
    return "保存到 " + (policy.installationName || policy.providerName)
      + " 对应地区的 Qoder 设置，只影响该地区的 Qoder 会话。";
  }

  global.CodexBridgeDesktopSettingsQoderPermissions = { create: create };
}(window));
