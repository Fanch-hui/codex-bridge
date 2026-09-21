(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  var D = global.CodexBridgeDesktopFormDraft;

  function check(label, value) {
    var wrapper = S.node("label", "check-field");
    var control = S.node("input");
    control.type = "checkbox";
    control.checked = !!value;
    wrapper.appendChild(control);
    wrapper.appendChild(S.node("span", null, label));
    return { wrapper: wrapper, control: control };
  }

  function modelChoices(models) {
    return S.safeArray(models).map(function (item) {
      return { id: item.modelID, title: item.displayName };
    });
  }

  function chooseEffort(control, options, changedModel, preferred) {
    var current = control.value;
    D.selectOptions(control, options, false);
    var valid = options.find(function (item) {
      return item.id === current && item.enabled !== false;
    });
    if (valid) {
      control.value = current;
      return;
    }
    var selected = options.find(function (item) {
      return item.id === preferred && item.enabled !== false;
    }) || options.find(function (item) {
      return item.enabled !== false;
    });
    control.value = selected ? selected.id : "";
  }

  function defaultEffort(model, models) {
    var selected = S.safeArray(models).find(function (item) {
      return item.modelID === model;
    });
    return selected && selected.defaultReasoningEffort ? selected.defaultReasoningEffort : "";
  }

  function create(page, emit, embedded) {
    var context = { page: page, emit: emit };
    var card = S.node(
      embedded ? "div" : "section",
      embedded ? "settings-subsection" : "page-card settings-card"
    );
    card.appendChild(S.node(embedded ? "h4" : "h3", null, "Codex"));
    var grid = S.node("div", "form-grid codex-preferences-grid");
    var model = S.selectField(
      "执行模型", page.executionModel,
      S.choices(page.executionModel, modelChoices(page.models)), function () {}, "");
    var effort = S.selectField(
      "执行推理强度", page.executionEffort,
      S.safeArray(page.effortOptions), function () {}, "");
    var toggle = check("快速模式", page.fastModeEnabled);
    var access = S.selectField(
      "访问模式", page.accessMode,
      S.choices(page.accessMode, page.accessOptions), function () {}, "");
    var controls = {
      model: model.control,
      effort: effort.control,
      enabled: toggle.control,
      access: access.control
    };
    grid.appendChild(model.wrapper);
    grid.appendChild(effort.wrapper);
    grid.appendChild(access.wrapper);
    grid.appendChild(toggle.wrapper);
    card.appendChild(grid);
    var hint = S.node("p", "hint", "当前选中的默认模型不支持快速模式。");
    hint.hidden = true;
    card.appendChild(hint);
    var draft = D.bind(controls);
    var modelStatus = S.node("p", "hint model-refresh-status");
    card.appendChild(modelStatus);
    var refreshModels = S.button("获取模型", "refreshModels", {}, emit, "small", false);
    var actions = S.node("div", "form-actions");
    actions.appendChild(refreshModels);
    var save = S.button(
      "保存模型偏好", null, {}, emit, "small primary", !page.canSavePreferences);
    actions.appendChild(save);
    card.appendChild(actions);

    function updateDependent() {
      var state = context.page;
      var selected = S.safeArray(state.models).find(function (item) {
        return item.modelID === model.control.value;
      });
      var options = selected ? S.safeArray(selected.reasoningEfforts) : S.safeArray(state.effortOptions);
      chooseEffort(effort.control, options, false, selected && selected.defaultReasoningEffort);
      effort.control.disabled = !state.canSavePreferences || options.length === 0;
      var supported = selected && selected.supportsFastMode === true;
      toggle.control.disabled = !state.canSavePreferences || !supported;
      hint.hidden = !!supported;
      if (!supported) toggle.control.checked = false;
    }

    model.control.addEventListener("change", function () {
      updateDependent();
      context.emit("setExecutionModel", { modelID: model.control.value });
    });
    effort.control.addEventListener("change", function () {
      if (!effort.control.disabled) {
        context.emit("setExecutionEffort", { effort: effort.control.value });
      }
    });
    access.control.addEventListener("change", function () {
      context.emit("setAccessMode", { accessMode: access.control.value });
    });
    toggle.control.addEventListener("change", function () {
      if (!toggle.control.disabled) {
        context.emit("setFastMode", { fastModeEnabled: toggle.control.checked });
      }
    });
    save.addEventListener("click", function () {
      if (save.disabled) return;
      var values = draft.values();
      context.emit("saveSettings", {
        executionModel: values.model,
        executionEffort: values.effort,
        accessMode: values.access,
        fastModeEnabled: values.enabled
      });
    });

    function update(next, nextEmit) {
      context.page = next;
      context.emit = nextEmit;
      D.selectOptions(model.control, S.choices(next.executionModel, modelChoices(next.models)));
      D.selectOptions(effort.control, S.choices(next.executionEffort, next.effortOptions), false);
      D.selectOptions(access.control, S.choices(next.accessMode, next.accessOptions));
      draft.update({
        model: next.executionModel,
        effort: next.executionEffort,
        access: next.accessMode,
        enabled: next.fastModeEnabled
      });
      save.disabled = !next.canSavePreferences;
      modelStatus.textContent = modelRefreshStatus(next);
      modelStatus.hidden = false;
      var count = modelCount(next);
      refreshModels.textContent = next.isRefreshingModels ? "获取中…" : count > 0 ? "刷新模型" : "获取模型";
      refreshModels.disabled = next.isRefreshingModels === true || next.canRefreshModels === false;
      updateDependent();
    }

    update(page, emit);
    return { root: card, update: update };
  }

  function modelCount(page) {
    if (!page) return 0;
    return typeof page.modelCount === "number" ? Math.max(0, page.modelCount) : S.safeArray(page.models).length;
  }

  function modelRefreshStatus(page) {
    if (page.isRefreshingModels) return "正在获取 Codex 模型…";
    if (page.modelError) return "模型获取失败：" + page.modelError;
    return "已获取 " + modelCount(page) + " 个 Codex 模型。";
  }

  global.CodexBridgeDesktopSettingsModels = {
    preferences: create,
    check: check,
    modelChoices: modelChoices,
    chooseEffort: chooseEffort,
    defaultEffort: defaultEffort
  };
}(window));
