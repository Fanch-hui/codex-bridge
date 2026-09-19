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
    model.control.addEventListener("change", function () {
      M.chooseEffort(effort.control, [{ id: "", title: "Provider 默认" }], true, "");
      model.control.disabled = true;
      effort.control.disabled = true;
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
      var efforts = sameModel ? S.safeArray(next.effortOptions).filter(function (item) { return item.id !== ""; }) : [];
      var options = [{ id: "", title: "Provider 默认" }].concat(efforts);
      M.chooseEffort(
        effort.control,
        options,
        false,
        M.defaultEffort(model.control.value, next.modelOptions)
      );
      permission.control.disabled = next.supportsWorkspaceWrite === false;
      permissionHint.textContent = next.supportsWorkspaceWrite === false
        ? "当前安装的有效能力不包含工作区写入，将按只读执行。" : "";
      permissionHint.hidden = next.supportsWorkspaceWrite !== false;
      model.control.disabled = !next.canSave || next.isRefreshingModels || next.canSelectModel === false;
      effort.control.disabled = !next.canSave || next.isRefreshingModels || next.canSelectEffort === false || efforts.length === 0;
      refresh.hidden = !next.canRefreshModels;
      refresh.disabled = !!next.isRefreshingModels;
      refresh.textContent = next.isRefreshingModels ? "刷新中…" : "刷新模型列表";
      error.textContent = next.errorMessage || (next.isRefreshingModels ? "正在读取所选模型的推理强度…" : efforts.length === 0 ? "当前模型不提供可选推理强度，使用 Provider 默认。" : "选择后自动保存。");
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
