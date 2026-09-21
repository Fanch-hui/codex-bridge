(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  var D = global.CodexBridgeDesktopFormDraft;
  var M = global.CodexBridgeDesktopSettingsModels;

  function editor(item, emit) {
    var context = { item: item, emit: emit };
    var root = S.node("div", "agent-preferences");
    var title = S.node("h4");
    var installation = S.node("p", "hint");
    root.appendChild(title);
    root.appendChild(installation);
    var grid = S.node("div", "form-grid");
    var model = S.selectField("默认模型", item.model || "", S.choices(item.model || "", modelOptions(item)), function () {}, "");
    var effort = S.selectField("推理强度", item.effort || "", [{ id: "", title: "Provider 默认" }].concat(S.safeArray(item.effortOptions)), function () {}, "");
    var permission = S.selectField("访问权限", item.permissionMode, S.choices(item.permissionMode, item.permissionOptions), function () {}, "");
    var permissionHint = S.node("p", "hint");
    [model, effort, permission].forEach(function (field) { grid.appendChild(field.wrapper); });
    root.appendChild(grid);
    root.appendChild(permissionHint);
    var draft = D.bind({ model: model.control, effort: effort.control, permission: permission.control });
    var actions = S.node("div", "form-actions");
    var refresh = S.button("刷新模型列表", null, {}, emit, "small", false);
    actions.appendChild(refresh);
    root.appendChild(actions);
    var error = S.node("p", "hint");
    root.appendChild(error);
    function persistSelection() {
      var values = draft.values(), state = context.item;
      if (!state.canSave || state.isRefreshingModels) return;
      context.emit("saveAgentDefault", { providerID: state.providerID, installationID: state.installationID,
        modelID: values.model || null, effort: values.effort || null, permissionMode: values.permission });
    }
    function updateEfforts(state, changedModel) {
      var selected = S.safeArray(state.modelOptions).find(function (option) {
        return option.modelID === model.control.value
          || (!model.control.value && option.isDefaultModel === true);
      });
      var known = !selected || selected.reasoningCapabilitiesAvailable !== false;
      var sameModel = model.control.value === (state.model || "");
      var efforts = known && selected && Array.isArray(selected.reasoningEfforts)
        ? selected.reasoningEfforts
        : known && sameModel ? S.safeArray(state.effortOptions) : [];
      efforts = efforts.filter(function (option) { return option.id !== ""; });
      M.chooseEffort(effort.control, [{ id: "", title: "Provider 默认" }].concat(efforts),
        changedModel, selected && selected.defaultReasoningEffort);
      effort.control.disabled = !state.canSave || state.isRefreshingModels
        || state.canSelectEffort === false || !known || efforts.length === 0;
      error.textContent = state.errorMessage || (state.isRefreshingModels || !known
        ? "正在获取模型推理强度…" : efforts.length === 0
          ? "当前模型不提供可选推理强度，使用 Provider 默认。" : state.providerID === "deepseek-harness"
            ? "推理选项由 DSH 适配器提供，可能对不同模型返回相同选项；模型实际支持以 API 为准。"
            : "选择后自动保存。");
      return efforts;
    }
    model.control.addEventListener("change", function () {
      updateEfforts(context.item, true);
      persistSelection();
    });
    effort.control.addEventListener("change", persistSelection);
    permission.control.addEventListener("change", persistSelection);
    refresh.addEventListener("click", function () {
      if (!refresh.disabled) context.emit("refreshAgentModels", { providerID: context.item.providerID, installationID: context.item.installationID });
    });
    function update(next, nextEmit) {
      context.item = next;
      context.emit = nextEmit;
      title.textContent = next.providerName;
      installation.textContent = next.installationName
        ? "安装：" + next.installationName
        : "连接 Agent 后会自动获取模型。";
      installation.hidden = false;
      D.selectOptions(model.control, S.choices(next.model || "", modelOptions(next)));
      D.selectOptions(permission.control, S.choices(next.permissionMode, next.permissionOptions));
      var sameModel = model.control.value === (next.model || "");
      draft.update({ model: next.model || "", effort: sameModel ? next.effort || "" : effort.control.value, permission: next.permissionMode });
      sameModel = model.control.value === (next.model || "");
      updateEfforts(next, false);
      permission.control.disabled = next.supportsWorkspaceWrite === false;
      permissionHint.textContent = next.supportsWorkspaceWrite === false
        ? "当前安装的有效能力不包含工作区写入，将按只读执行。" : "";
      permissionHint.hidden = next.supportsWorkspaceWrite !== false;
      model.control.disabled = !next.canSave || next.isRefreshingModels || next.canSelectModel === false;
      refresh.hidden = !next.canRefreshModels;
      refresh.disabled = !!next.isRefreshingModels;
      refresh.textContent = next.isRefreshingModels ? "刷新中…" : "刷新模型列表";
      error.hidden = false;
    }
    update(item, emit);
    return { root: root, update: update };
  }

  function modelOptions(item) {
    return [{ id: "", title: "Provider 默认" }].concat(M.modelChoices(item.modelOptions));
  }

  function create(page, emit, embedded) {
    var root = S.node(
      embedded ? "div" : "section",
      embedded ? "settings-subsection" : "page-card settings-card"
    );
    if (!embedded) root.appendChild(S.node("h3", null, "Agent模型与权限"));
    var empty = S.node("div", "list-empty", "尚未读取 Agent 默认偏好。");
    root.appendChild(empty);
    var editors = new Map();
    function update(next, nextEmit) {
      var items = S.safeArray(next.agentDefaults);
      var visible = new Set();
      items.forEach(function (item) {
        var key = JSON.stringify([item.providerID, item.installationID]);
        visible.add(key);
        var current = editors.get(key);
        if (!current) {
          current = editor(item, nextEmit);
          editors.set(key, current);
          root.appendChild(current.root);
        }
        current.root.hidden = false;
        current.update(item, nextEmit);
      });
      editors.forEach(function (current, key) { current.root.hidden = !visible.has(key); });
      empty.hidden = items.length > 0;
    }
    update(page, emit);
    return { root: root, update: update };
  }
  global.CodexBridgeDesktopSettingsAgents = { create: create };
}(window));
