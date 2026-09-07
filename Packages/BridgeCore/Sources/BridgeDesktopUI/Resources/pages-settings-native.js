(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  var D = global.CodexBridgeDesktopFormDraft;
  var N = global.CodexBridgeDesktopNativePermissions;

  function ruleEditor(policy, rule, emit) {
    var context = { policy: policy, rule: rule, emit: emit };
    var root = S.node("div", "page-message");
    var heading = S.node("h4");
    root.appendChild(heading);
    var initial = rule || { effect: "allow", action: N.defaultAction(policy), target: "" };
    var fields = N.ruleFields(policy, initial);
    root.appendChild(fields.grid);
    var draft = D.bind({ effect: fields.effect, action: fields.action, target: fields.target });
    var readonly = S.node("p", "mono");
    root.appendChild(readonly);
    var actions = S.node("div", "form-actions");
    var save = S.button(rule ? "保存规则" : "添加规则", null, {}, emit, "small primary", false);
    var remove = S.button("删除", null, {}, emit, "small danger", false);
    actions.appendChild(save);
    if (rule) actions.appendChild(remove);
    root.appendChild(actions);
    var submitted;
    save.addEventListener("click", function () {
      if (save.disabled) return;
      N.submitRule(context.rule ? "replaceAgentNativePermissionRule" : "addAgentNativePermissionRule", context.policy, context.rule, fields, function (command, payload) {
        submitted = { effect: payload.effect, action: payload.action, target: payload.target };
        context.emit(command, payload);
      });
    });
    remove.addEventListener("click", function () {
      if (remove.disabled || !global.confirm("删除这条 AGY Global 规则？")) return;
      context.emit("removeAgentNativePermissionRule", { installationID: context.policy.installationID, ruleID: context.rule.ruleID });
    });
    function update(next, nextRule, nextEmit) {
      context.policy = next;
      context.rule = nextRule;
      context.emit = nextEmit;
      var editable = !nextRule || (nextRule.isEditable && !nextRule.isRedacted);
      fields.grid.hidden = !editable;
      actions.hidden = !editable;
      readonly.hidden = editable;
      readonly.textContent = nextRule && nextRule.isRedacted ? "目标已由 Service 隐藏" : nextRule ? nextRule.action + "(" + nextRule.target + ")" : "";
      heading.textContent = nextRule ? nextRule.effect.toUpperCase() + " · " + N.actionTitle(nextRule.action) : "新增规则";
      save.disabled = !next.canEdit;
      remove.disabled = !next.canEdit;
      D.selectOptions(fields.action, S.safeArray(next.availableActions).map(function (action) { return { id: action, title: N.actionTitle(action) }; }));
      if (nextRule && editable) draft.update({ effect: nextRule.effect, action: nextRule.action, target: nextRule.target || "" });
      if (!nextRule && submitted && S.safeArray(next.rules).some(function (item) {
        return item.effect === submitted.effect && item.action === submitted.action && item.target === submitted.target;
      })) {
        draft.update(submitted);
        draft.update({ effect: "allow", action: N.defaultAction(next), target: "" });
        submitted = null;
      }
    }
    update(policy, rule, emit);
    return { root: root, update: update };
  }

  function card(policy, emit) {
    var context = { policy: policy, emit: emit };
    var root = S.node("section", "page-card settings-card");
    var header = S.node("div", "native-permission-header");
    header.appendChild(S.node("h3", null, "AGY CLI Global 工具权限"));
    var refresh = S.button("刷新", null, {}, emit, "small", false);
    refresh.addEventListener("click", function () {
      if (!refresh.disabled) context.emit("refreshAgentNativePermission", { installationID: context.policy.installationID });
    });
    header.appendChild(refresh);
    root.appendChild(header);
    var controls = S.node("div");
    var status = S.node("div", "page-message");
    var warnings = S.node("div");
    root.appendChild(controls);
    root.appendChild(status);
    root.appendChild(warnings);
    root.appendChild(S.node("p", "hint", "规则优先级：Deny > Ask > Allow。修改仅对之后启动的新任务生效。"));
    var create = ruleEditor(policy, null, emit);
    root.appendChild(create.root);
    var rules = new Map();
    var error = S.node("div", "page-message");
    root.appendChild(error);
    function update(next, nextEmit) {
      context.policy = next;
      context.emit = nextEmit;
      refresh.textContent = next.isLoading ? "刷新中…" : "刷新";
      refresh.disabled = next.isLoading || next.isSaving;
      S.clear(controls);
      controls.appendChild(N.installationField(next, nextEmit));
      if (next.toolPermission) controls.appendChild(N.modeField(next, nextEmit));
      status.hidden = !!next.toolPermission;
      status.textContent = next.isLoading ? "正在读取 AGY Global 权限…" : "尚未读取 AGY Global 权限。";
      S.clear(warnings);
      S.safeArray(next.warnings).forEach(function (warning) { warnings.appendChild(S.node("p", "hint", "⚠ " + warning)); });
      create.root.hidden = !next.toolPermission;
      create.update(next, null, nextEmit);
      var visible = new Set();
      S.safeArray(next.rules).forEach(function (rule) {
        visible.add(rule.ruleID);
        var editor = rules.get(rule.ruleID);
        if (!editor) {
          editor = ruleEditor(next, rule, nextEmit);
          rules.set(rule.ruleID, editor);
          root.insertBefore(editor.root, error);
        }
        editor.root.hidden = !next.toolPermission;
        editor.update(next, rule, nextEmit);
      });
      rules.forEach(function (editor, id) { if (!visible.has(id)) editor.root.hidden = true; });
      error.textContent = next.errorMessage ? "⚠ " + next.errorMessage : "";
      error.hidden = !next.errorMessage;
    }
    update(policy, emit);
    return { root: root, update: update };
  }

  function create() {
    var root = S.node("div");
    var cards = new Map();
    return {
      root: root,
      update: function (policy, emit) {
        cards.forEach(function (item, id) { item.root.hidden = !policy || id !== policy.installationID; });
        if (!policy) return;
        var editor = cards.get(policy.installationID);
        if (!editor) {
          editor = card(policy, emit);
          cards.set(policy.installationID, editor);
          root.appendChild(editor.root);
        }
        editor.root.hidden = false;
        editor.update(policy, emit);
      }
    };
  }
  global.CodexBridgeDesktopSettingsNative = { create: create, card: card };
}(window));
