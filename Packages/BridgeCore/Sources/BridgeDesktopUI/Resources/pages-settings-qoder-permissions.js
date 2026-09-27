(function (global) {
  "use strict";

  var S = global.CodexBridgeDesktopPageSupport;
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
      detail: "跳过 Qoder 逐项权限确认；Bridge 仍执行项目读写与网络限制。需要在 Qoder 信任的目录中生效。"
    }
  };

  function create() {
    var root = S.node("section", "settings-subsection");
    root.appendChild(S.node("h4", null, "Qoder 执行权限"));
    var installation = S.node("div");
    var permission = S.node("div");
    var detail = S.node("p", "hint");
    var scope = S.node("p", "hint");
    var error = S.node("p", "hint");
    root.appendChild(installation);
    root.appendChild(permission);
    root.appendChild(detail);
    root.appendChild(scope);
    root.appendChild(error);

    function update(page, emit) {
      var policy = page && page.nativePermissionPolicy;
      root.hidden = !policy || policy.providerID !== "qoder";
      if (root.hidden) return;

      S.clear(installation);
      S.clear(permission);
      var choices = S.safeArray(policy.availableModes).filter(function (mode) {
        return modes[mode.modeID] || mode.modeID === policy.toolPermission;
      }).map(function (mode) {
        return {
          id: mode.modeID,
          title: modes[mode.modeID] ? modes[mode.modeID].title : mode.displayName
        };
      });
      Object.keys(modes).forEach(function (modeID) {
        if (!choices.some(function (choice) { return choice.id === modeID; })) {
          choices.push({ id: modeID, title: modes[modeID].title });
        }
      });

      var qoderInstallations = S.safeArray(policy.installations);
      if (qoderInstallations.length > 1) {
        var selectedInstallation = S.selectField(
          "Qoder 安装与地区",
          policy.installationID,
          qoderInstallations,
          function (installationID) {
            if (installationID !== policy.installationID) {
              emit("refreshAgentNativePermission", { installationID: installationID });
            }
          },
          ""
        );
        selectedInstallation.control.disabled = policy.isLoading || policy.isSaving;
        installation.appendChild(selectedInstallation.wrapper);
      }

      var selectedMode = modes[policy.toolPermission];
      var modeField = S.selectField(
        "权限模式",
        policy.toolPermission || "default",
        choices,
        function (modeID) {
          var option = S.safeArray(policy.availableModes).find(function (item) {
            return item.modeID === modeID;
          });
          if (!option || modeID === policy.toolPermission) return;
          var confirmed = !option.requiresConfirmation || global.confirm(
            "启用“" + (modes[modeID] ? modes[modeID].title : option.displayName) + "”？\n\n"
              + policyScope(policy)
              + "\nBridge 的项目只读、写入和网络限制仍然生效。"
          );
          if (!confirmed) {
            modeField.control.value = policy.toolPermission;
            return;
          }
          emit("setAgentNativePermissionMode", {
            installationID: policy.installationID,
            toolPermission: modeID,
            confirmed: option.requiresConfirmation === true
          });
        },
        ""
      );
      modeField.control.disabled = !policy.canEdit;
      permission.appendChild(modeField.wrapper);
      detail.textContent = selectedMode ? selectedMode.detail : modeDetail(policy.toolPermission);
      if (policy.toolPermission && policy.toolPermission !== "default"
        && !selectedMode) {
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
