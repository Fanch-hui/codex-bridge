(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  var D = global.CodexBridgeDesktopFormDraft;
  var M = global.CodexBridgeDesktopSettingsModels;

  function editor(item, emit) {
    var context = { item: item, emit: emit };
    var root = S.node("div", "page-message");
    var title = S.node("h4");
    var installation = S.node("p", "hint");
    root.appendChild(title);
    root.appendChild(installation);
    var grid = S.node("div", "form-grid");
    var model = S.selectField("默认模型", item.model || "", S.choices(item.model || "", modelOptions(item)), function () {}, "");
    var effort = S.selectField("推理强度", item.effort || "", S.choices(item.effort || "", M.effortOptions(item.model, item.modelOptions, item.effortOptions, true)), function () {}, "");
    var permission = S.selectField("访问权限", item.permissionMode, S.choices(item.permissionMode, item.permissionOptions), function () {}, "");
    var permissionHint = S.node("p", "hint");
    [model, effort, permission].forEach(function (field) { grid.appendChild(field.wrapper); });
    root.appendChild(grid);
    root.appendChild(permissionHint);
    var draft = D.bind({ model: model.control, effort: effort.control, permission: permission.control });
    var actions = S.node("div", "form-actions");
    var save = S.button("保存 Agent 默认", null, {}, emit, "small primary", !item.canSave);
    var refresh = S.button("刷新模型列表", null, {}, emit, "small", false);
    actions.appendChild(save);
    actions.appendChild(refresh);
    root.appendChild(actions);
    var error = S.node("p", "hint");
    root.appendChild(error);
    model.control.addEventListener("change", function () {
      var state = context.item;
      M.chooseEffort(effort.control, M.effortOptions(model.control.value, state.modelOptions, state.effortOptions, true), true);
    });
    save.addEventListener("click", function () {
      if (save.disabled) return;
      var values = draft.values();
      var state = context.item;
      context.emit("saveAgentDefault", { providerID: state.providerID, installationID: state.installationID, modelID: values.model || null, effort: values.effort || null, permissionMode: values.permission });
    });
    refresh.addEventListener("click", function () {
      if (!refresh.disabled) context.emit("refreshAgentModels", { providerID: context.item.providerID, installationID: context.item.installationID });
    });
    function update(next, nextEmit) {
      context.item = next;
      context.emit = nextEmit;
      title.textContent = next.providerName;
      installation.textContent = next.installationName
        ? "安装：" + next.installationName
        : "尚未登记可用安装，可先保存权限默认值；模型列表需先登记并 Probe。";
      installation.hidden = false;
      D.selectOptions(model.control, S.choices(next.model || "", modelOptions(next)));
      D.selectOptions(effort.control, S.choices(next.effort || "", M.effortOptions(model.control.value, next.modelOptions, next.effortOptions, true)));
      D.selectOptions(permission.control, S.choices(next.permissionMode, next.permissionOptions));
      draft.update({ model: next.model || "", effort: next.effort || "", permission: next.permissionMode });
      M.chooseEffort(effort.control, S.choices(next.effort || "", M.effortOptions(model.control.value, next.modelOptions, next.effortOptions, true)), false);
      permission.control.disabled = next.supportsWorkspaceWrite === false;
      permissionHint.textContent = next.supportsWorkspaceWrite === false
        ? "当前安装的有效能力不包含工作区写入，将按只读执行。" : "";
      permissionHint.hidden = next.supportsWorkspaceWrite !== false;
      save.disabled = !next.canSave;
      refresh.hidden = !next.canRefreshModels;
      refresh.disabled = !!next.isRefreshingModels;
      refresh.textContent = next.isRefreshingModels ? "刷新中…" : "刷新模型列表";
      error.textContent = next.errorMessage || "";
      error.hidden = !next.errorMessage;
    }
    update(item, emit);
    return { root: root, update: update };
  }

  function modelOptions(item) {
    return [{ id: "", title: "Provider 默认" }].concat(M.modelChoices(item.modelOptions));
  }

  function create(page, emit) {
    var root = S.node("section", "page-card settings-card");
    root.appendChild(S.node("h3", null, "外部 Agent 默认偏好"));
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
