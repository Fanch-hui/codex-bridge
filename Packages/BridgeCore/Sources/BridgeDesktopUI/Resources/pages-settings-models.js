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
    return S.safeArray(models).map(function (item) { return { id: item.modelID, title: item.displayName }; });
  }

  function effortOptions(model, models, fallback, includeDefault) {
    var selected = S.safeArray(models).find(function (item) { return item.modelID === model; });
    var hasCatalog = S.safeArray(models).length > 0;
    var options = selected ? S.safeArray(selected.reasoningEfforts)
      : hasCatalog ? [] : S.safeArray(fallback);
    return includeDefault ? [{ id: "", title: "Provider 默认" }].concat(options) : options;
  }

  function defaultEffort(model, models) {
    var selected = S.safeArray(models).find(function (item) { return item.modelID === model; });
    return selected && selected.defaultReasoningEffort ? selected.defaultReasoningEffort : "";
  }

  function chooseEffort(control, options, changedModel, preferred) {
    var current = control.value;
    D.selectOptions(control, options, false);
    var valid = options.find(function (item) { return item.id === current && item.enabled !== false; });
    if (valid) { control.value = current; return; }
    var selected = options.find(function (item) { return item.id === preferred && item.enabled !== false; })
      || options.find(function (item) { return item.enabled !== false; });
    control.value = selected ? selected.id : "";
  }

  function create(page, emit, supervisor) {
    var context = { page: page, emit: emit };
    var card = S.node("section", "page-card settings-card");
    card.appendChild(S.node("h3", null, supervisor ? "Supervisor 监督" : "模型与执行默认偏好"));
    var grid = S.node("div", "form-grid");
    var modelKey = supervisor ? "supervisorModel" : "executionModel";
    var effortKey = supervisor ? "supervisorEffort" : "executionEffort";
    var model = S.selectField(supervisor ? "Supervisor 模型" : "执行模型", page[modelKey], S.choices(page[modelKey], modelChoices(page.models)), function () {}, "");
    var effort = S.selectField(supervisor ? "Supervisor 推理强度" : "执行推理强度", page[effortKey], S.choices(page[effortKey], page.effortOptions), function () {}, "");
    var toggle = check(supervisor ? "启用 Supervisor" : "快速模式", supervisor ? page.supervisorEnabled : page.fastModeEnabled);
    var controls = { model: model.control, effort: effort.control, enabled: toggle.control };
    grid.appendChild(model.wrapper);
    grid.appendChild(effort.wrapper);
    var access;
    if (!supervisor) {
      access = S.selectField("访问模式", page.accessMode, S.choices(page.accessMode, page.accessOptions), function () {}, "");
      controls.access = access.control;
      grid.appendChild(access.wrapper);
    }
    grid.appendChild(toggle.wrapper);
    card.appendChild(grid);
    var hint = S.node("p", "hint", "当前选中的默认模型不支持快速模式。");
    hint.hidden = true;
    card.appendChild(hint);
    var draft = D.bind(controls);
    var actions = S.node("div", "form-actions");
    var modelStatus, refreshModels;
    if (!supervisor) {
      modelStatus = S.node("p", "hint model-refresh-status");
      card.appendChild(modelStatus);
      refreshModels = S.button("获取模型", "refreshModels", {}, emit, "small", false);
      actions.appendChild(refreshModels);
    }
    var save = S.button(supervisor ? "保存 Supervisor" : "保存模型偏好", null, {}, emit, "small primary", !page.canSavePreferences);
    actions.appendChild(save);
    card.appendChild(actions);
    function updateDependent(changedModel) {
      var state = context.page;
      var fallback = supervisor && S.safeArray(state.supervisorEffortOptions).length ? state.supervisorEffortOptions : state.effortOptions;
      var options = effortOptions(model.control.value, state.models, fallback, false);
      var selected = S.safeArray(state.models).find(function (item) { return item.modelID === model.control.value; });
      chooseEffort(
        effort.control,
        options,
        changedModel,
        selected && selected.defaultReasoningEffort
      );
      effort.control.disabled = !state.canSavePreferences || options.length === 0;
      if (supervisor) return;
      var supported = selected && selected.supportsFastMode === true;
      toggle.control.disabled = !state.canSavePreferences || !supported;
      hint.hidden = !!supported;
      if (!supported) toggle.control.checked = false;
    }
    model.control.addEventListener("change", function () {
      updateDependent(true);
      context.emit(supervisor ? "setSupervisorModel" : "setExecutionModel", supervisor
        ? { supervisorModel: model.control.value } : { modelID: model.control.value });
    });
    effort.control.addEventListener("change", function () {
      if (!effort.control.disabled) context.emit(supervisor ? "setSupervisorEffort" : "setExecutionEffort",
        supervisor ? { supervisorEffort: effort.control.value } : { effort: effort.control.value });
    });
    save.addEventListener("click", function () {
      if (save.disabled) return;
      var values = draft.values();
      var payload = supervisor
        ? { supervisorModel: values.model, supervisorEffort: values.effort, supervisorEnabled: values.enabled }
        : { executionModel: values.model, executionEffort: values.effort, accessMode: values.access, fastModeEnabled: values.enabled };
      context.emit("saveSettings", payload);
    });
    function update(next, nextEmit) {
      context.page = next;
      context.emit = nextEmit;
      D.selectOptions(model.control, S.choices(next[modelKey], modelChoices(next.models)));
      D.selectOptions(effort.control, effortOptions(model.control.value, next.models, next.effortOptions, false), false);
      if (access) D.selectOptions(access.control, S.choices(next.accessMode, next.accessOptions));
      var values = { model: next[modelKey], effort: next[effortKey], enabled: supervisor ? next.supervisorEnabled : next.fastModeEnabled };
      if (access) values.access = next.accessMode;
      draft.update(values);
      save.disabled = !next.canSavePreferences;
      if (modelStatus) {
        modelStatus.textContent = modelRefreshStatus(next);
        modelStatus.hidden = false;
      }
      if (refreshModels) {
        var count = modelCount(next);
        refreshModels.textContent = next.isRefreshingModels ? "获取中…" : count > 0 ? "刷新模型" : "获取模型";
        refreshModels.disabled = next.isRefreshingModels === true || next.canRefreshModels === false;
      }
      if (supervisor) toggle.control.disabled = !next.canSavePreferences;
      updateDependent(false);
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
    preferences: function (page, emit) { return create(page, emit, false); },
    supervisor: function (page, emit) { return create(page, emit, true); },
    check: check, modelChoices: modelChoices, effortOptions: effortOptions,
    chooseEffort: chooseEffort, defaultEffort: defaultEffort
  };
}(window));
