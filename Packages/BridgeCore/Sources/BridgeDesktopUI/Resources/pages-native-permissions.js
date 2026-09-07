(function (global) {
  "use strict";

  var S = global.CodexBridgeDesktopPageSupport;
  var effects = [{ id: "allow", title: "Allow" }, { id: "ask", title: "Ask" }, { id: "deny", title: "Deny" }];

  function installationField(policy, emit) {
    var installations = S.safeArray(policy.installations);
    if (installations.length <= 1) {
      return S.node("p", "hint", "安装：" + policy.installationName);
    }
    var field = S.selectField(
      "安装",
      policy.installationID,
      installations,
      function (installationID) {
        if (installationID === policy.installationID) return;
        emit("refreshAgentNativePermission", { installationID: installationID });
      },
      ""
    );
    field.control.disabled = policy.isLoading || policy.isSaving;
    return field.wrapper;
  }

  function modeField(policy, emit) {
    var choices = S.safeArray(policy.availableModes).map(function (mode) {
      return { id: mode.modeID, title: mode.displayName };
    });
    var field = S.selectField("工具执行策略", policy.toolPermission, choices, function (value) {
      var option = S.safeArray(policy.availableModes).find(function (mode) {
        return mode.modeID === value;
      });
      if (!option || value === policy.toolPermission) return;
      var confirmed = !option.requiresConfirmation || global.confirm(
        "启用 “" + option.displayName + "”？\n\n这会修改当前用户的 AGY Global 配置，并影响使用同一 HOME 的其他 AGY CLI 任务。Bridge 的项目 Read Only/Write 硬策略保持不变。"
      );
      if (!confirmed) {
        field.control.value = policy.toolPermission;
        return;
      }
      emit("setAgentNativePermissionMode", {
        installationID: policy.installationID,
        toolPermission: value,
        confirmed: option.requiresConfirmation === true
      });
    }, "");
    field.control.disabled = !policy.canEdit;
    return field.wrapper;
  }

  function ruleFields(policy, value) {
    var grid = S.node("div", "form-grid three");
    var effect = S.selectField("效果", value.effect, effects, function () {}, "");
    var actionChoices = S.safeArray(policy.availableActions).map(function (item) {
      return { id: item, title: actionTitle(item) };
    });
    var action = S.selectField("动作", value.action, actionChoices, function () {}, "");
    var target = S.textField("目标", value.target || "", targetPlaceholder(value.action), "full");
    target.control.maxLength = 4096;
    action.control.addEventListener("change", function () {
      target.control.placeholder = targetPlaceholder(action.control.value);
    });
    grid.appendChild(effect.wrapper);
    grid.appendChild(action.wrapper);
    grid.appendChild(target.wrapper);
    return { grid: grid, effect: effect.control, action: action.control, target: target.control };
  }

  function submitRule(command, policy, rule, editor, emit) {
    var target = editor.target.value.trim();
    if (!target) {
      editor.target.focus();
      return;
    }
    var action = editor.action.value;
    var risky = (rule && rule.requiresConfirmation) || requiresRuleConfirmation(action, target);
    if (risky && !global.confirm(
      "保存高风险 AGY Global 规则？\n\n该规则会影响使用同一 HOME 的其他 AGY CLI 任务。Bridge 的项目 Read Only/Write 硬策略保持不变。"
    )) return;
    emit(command, {
      installationID: policy.installationID,
      ruleID: rule ? rule.ruleID : null,
      effect: editor.effect.value,
      action: action,
      target: target,
      confirmed: !!risky
    });
  }

  function remediationCard(detail, emit) {
    var remediation = detail && detail.permissionRemediation;
    if (!remediation) return null;
    var card = S.node("article", "approval-card");
    card.appendChild(S.node("h4", null, "AGY 工具权限被拒绝"));
    var entry = S.safeArray(detail.conversation).find(function (item) {
      return item.id === remediation.messageKey;
    });
    if (entry && entry.toolName) card.appendChild(S.node("p", null, entry.toolName));
    if (entry && entry.toolArguments) card.appendChild(S.node("pre", "mono", entry.toolArguments));

    if (remediation.didApply) {
      card.appendChild(S.node("p", null, "AGY Global 权限已更新，仅对新任务生效。请重新提交或续接任务。"));
      return card;
    }
    if (remediation.errorMessage) card.appendChild(errorMessage(remediation.errorMessage));

    var actions = S.node("div", "approval-actions");
    if (!remediation.candidateID) {
      actions.appendChild(S.button(
        remediation.isLoading ? "正在准备…" : "生成允许规则",
        "prepareAgentPermissionRemediation",
        { taskID: detail.taskID, messageKey: remediation.messageKey },
        emit,
        "small primary",
        remediation.isLoading || remediation.isApplying
      ));
    } else {
      card.appendChild(S.node("pre", "mono", remediation.displayRule || "待确认规则"));
      var apply = S.button(
        remediation.isApplying ? "正在保存…" : "允许此工具并写入 AGY Global 配置",
        null,
        {},
        emit,
        "small primary",
        remediation.isLoading || remediation.isApplying
      );
      apply.addEventListener("click", function () {
        if (!global.confirm(
          "写入 AGY Global 允许规则？\n\n将写入：" + (remediation.displayRule || "待确认规则") + "\n\n这会影响使用同一 HOME 的其他 AGY CLI 任务。"
        )) return;
        emit("applyAgentPermissionRemediation", {
          taskID: detail.taskID,
          messageKey: remediation.messageKey,
          confirmed: true
        });
      });
      actions.appendChild(apply);
    }
    card.appendChild(actions);
    return card;
  }

  function oneTimeApprovalButton(approval, emit) {
    if (!approval || approval.kind !== "task_start" || approval.oneTimeToolAutoApprovalAvailable !== true) {
      return null;
    }
    var button = S.button("本次自动批准 AGY 工具并允许网络", null, {}, emit, "small primary", approval.resolving || !approval.canAllow);
    button.addEventListener("click", function () {
      if (!global.confirm(
        "本次自动批准 AGY 工具并允许网络？\n\n它仍受项目 Read Only/Write 硬策略约束，不会修改 AGY Global 配置。"
      )) return;
      emit("resolveApproval", {
        approvalID: approval.approvalID,
        taskID: approval.taskID,
        decision: "allow",
        oneTimeToolAutoApproval: true,
        confirmed: true
      });
    });
    return button;
  }

  function defaultAction(policy) { return S.safeArray(policy.availableActions)[0] || "command"; }

  function requiresRuleConfirmation(action, target) {
    if (action === "unsandboxed" || target.indexOf("*") >= 0) return true;
    if (action === "mcp" && target.indexOf("/") < 0) return true;
    if (action === "command" && target.trim().split(/\s+/).length <= 1) return true;
    if (action === "read_url" || action === "execute_url") {
      return target.split(":", 1)[0].indexOf(".") < 0;
    }
    return false;
  }

  function actionTitle(value) {
    var titles = {
      command: "命令", read_url: "读取网页", execute_url: "操作网页", mcp: "MCP 工具",
      read_file: "读取文件", write_file: "写入文件",
      unsandboxed: "脱离沙箱"
    };
    return titles[value] || value;
  }

  function targetPlaceholder(action) {
    var values = {
      command: "例如：swift test", read_url: "例如：example.com", execute_url: "例如：example.com",
      mcp: "例如：server/tool", read_file: "例如：/path/to/project/*",
      write_file: "例如：/path/to/project/*",
      unsandboxed: "需要脱离沙箱的目标"
    };
    return values[action] || "权限目标";
  }

  function errorMessage(message) { return S.node("div", "page-message", "⚠ " + message); }

  global.CodexBridgeDesktopNativePermissions = {
    settingsCard: function (policy, emit) {
      return policy ? global.CodexBridgeDesktopSettingsNative.card(policy, emit).root : null;
    },
    installationField: installationField,
    modeField: modeField,
    ruleFields: ruleFields,
    submitRule: submitRule,
    defaultAction: defaultAction,
    actionTitle: actionTitle,
    remediationCard: remediationCard,
    oneTimeApprovalButton: oneTimeApprovalButton
  };
}(window));
