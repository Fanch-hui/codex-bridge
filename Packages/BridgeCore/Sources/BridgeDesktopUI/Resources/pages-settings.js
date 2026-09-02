(function (global) {
  "use strict";

  var S = global.CodexBridgeDesktopPageSupport;

  function render(page, emit) {
    var container = document.getElementById("settings-content");
    S.clear(container);
    if (!page) {
      var unavailableHeader = S.node("div");
      S.pageHeader(unavailableHeader, { title: "设置", subtitle: "正在从本机 Service 读取偏好设置。", symbol: "gearshape" });
      container.appendChild(unavailableHeader);
      var unavailable = S.node("div");
      S.empty(unavailable, "设置页暂不可用", "连接本机 Service 后，可以配置模型、安全审批与后台服务。");
      container.appendChild(unavailable);
      return;
    }
    var header = S.node("div");
    S.pageHeader(header, page.header);
    container.appendChild(header);
    var grid = S.node("div", "settings-grid");
    grid.appendChild(preferencesCard(page, emit));
    if (page.supervisorAvailable) grid.appendChild(supervisorCard(page, emit));
    grid.appendChild(approvalCard(page, emit));
    grid.appendChild(instructionsCard(page, emit));
    grid.appendChild(agentDefaultsCard(page, emit));
    grid.appendChild(serviceCard(page, emit));
    container.appendChild(grid);
    if (page.statusMessage) container.appendChild(S.node("div", "page-message", page.statusMessage));
  }

  function preferencesCard(page, emit) {
    var card = S.node("section", "page-card settings-card");
    card.appendChild(S.node("h3", null, "模型与执行默认偏好"));
    var grid = S.node("div", "form-grid");
    var executionModel = modelSelect("执行模型", page.executionModel, page.models);
    var executionEffort = S.selectField("执行推理强度", page.executionEffort, S.choices(page.executionEffort, page.effortOptions), function () {}, "");
    var access = S.selectField("访问模式", page.accessMode, S.choices(page.accessMode, page.accessOptions), function () {}, "");
    grid.appendChild(executionModel.wrapper);
    grid.appendChild(executionEffort.wrapper);
    grid.appendChild(access.wrapper);
    var fast = check("快速模式", page.fastModeEnabled);
    grid.appendChild(fast.wrapper);
    card.appendChild(grid);
    var actions = S.node("div", "form-actions");
    var save = S.button("保存模型偏好", null, {}, emit, "small primary", !page.canSavePreferences);
    save.addEventListener("click", function () {
      emit("saveSettings", { executionModel: executionModel.control.value, executionEffort: executionEffort.control.value, accessMode: access.control.value, fastModeEnabled: fast.control.checked, supervisorModel: page.supervisorModel, supervisorEffort: page.supervisorEffort, supervisorEnabled: page.supervisorEnabled });
    });
    actions.appendChild(save);
    card.appendChild(actions);
    return card;
  }

  function supervisorCard(page, emit) {
    var card = S.node("section", "page-card settings-card");
    card.appendChild(S.node("h3", null, "Supervisor 监督"));
    var grid = S.node("div", "form-grid");
    var model = modelSelect("Supervisor 模型", page.supervisorModel, page.models);
    var effort = S.selectField("Supervisor 推理强度", page.supervisorEffort, S.choices(page.supervisorEffort, page.supervisorEffortOptions.length ? page.supervisorEffortOptions : page.effortOptions), function () {}, "");
    var enabled = check("启用 Supervisor", page.supervisorEnabled);
    grid.appendChild(model.wrapper);
    grid.appendChild(effort.wrapper);
    grid.appendChild(enabled.wrapper);
    card.appendChild(grid);
    var actions = S.node("div", "form-actions");
    actions.appendChild(settingButton("保存 Supervisor", null, {}, emit, !page.canSavePreferences));
    actions.lastChild.addEventListener("click", function () {
      emit("saveSettings", { supervisorModel: model.control.value, supervisorEffort: effort.control.value, supervisorEnabled: enabled.control.checked });
    });
    card.appendChild(actions);
    return card;
  }

  function approvalCard(page, emit) {
    var card = S.node("section", "page-card settings-card");
    card.appendChild(S.node("h3", null, "安全审批策略"));
    var direct = S.selectField("Direct 操作", page.directApprovalMode, S.choices(page.directApprovalMode, page.directApprovalOptions), function (value) {
      emit("setDirectApprovalMode", { mode: value });
    }, "");
    var task = S.selectField("远程任务启动", page.taskStartApprovalMode, S.choices(page.taskStartApprovalMode, page.taskStartApprovalOptions), function (value) {
      emit("setTaskStartApprovalMode", { mode: value });
    }, "");
    card.appendChild(direct.wrapper);
    card.appendChild(task.wrapper);
    card.appendChild(S.node("p", "hint", "策略仍由本机 Service 和项目权限强制执行。"));
    return card;
  }

  function instructionsCard(page, emit) {
    var card = S.node("section", "page-card settings-card");
    card.appendChild(S.node("h3", null, "全局自定义指令"));
    var field = S.node("div", "field");
    field.appendChild(S.node("label", null, "发送给 Provider 的全局指令"));
    var text = S.node("textarea");
    text.value = page.customInstructions || "";
    text.placeholder = "可选。保存后由本机 Service 应用。";
    field.appendChild(text);
    card.appendChild(field);
    var actions = S.node("div", "form-actions");
    var save = S.button("保存指令", null, {}, emit, "small primary", !page.canSaveInstructions);
    save.addEventListener("click", function () { emit("saveCustomInstructions", { text: text.value }); });
    actions.appendChild(save);
    card.appendChild(actions);
    return card;
  }

  function agentDefaultsCard(page, emit) {
    var card = S.node("section", "page-card settings-card");
    card.appendChild(S.node("h3", null, "外部 Agent 默认偏好"));
    if (!page.agentDefaults || !page.agentDefaults.length) {
      card.appendChild(S.node("div", "list-empty", "尚未读取 Agent 默认偏好。"));
      return card;
    }
    page.agentDefaults.forEach(function (item) { card.appendChild(agentDefault(item, emit)); });
    return card;
  }

  function agentDefault(item, emit) {
    var wrapper = S.node("div", "page-message");
    wrapper.appendChild(S.node("h4", null, item.providerName));
    if (item.installationName) wrapper.appendChild(S.node("p", "hint", "安装：" + item.installationName));
    var grid = S.node("div", "form-grid");
    var models = item.modelOptions.map(function (model) { return { id: model.modelID, title: model.displayName }; });
    var model = S.selectField("默认模型", item.model || "", S.choices(item.model || "", models, "Provider 默认"), function () {}, "");
    var effort = S.selectField("推理强度", item.effort || "", S.choices(item.effort || "", item.effortOptions, "Provider 默认"), function () {}, "");
    var permission = S.selectField("访问权限", item.permissionMode, S.choices(item.permissionMode, item.permissionOptions), function () {}, "");
    grid.appendChild(model.wrapper);
    grid.appendChild(effort.wrapper);
    grid.appendChild(permission.wrapper);
    wrapper.appendChild(grid);
    var actions = S.node("div", "form-actions");
    var save = S.button("保存 Agent 默认", null, {}, emit, "small primary", !item.canSave);
    save.addEventListener("click", function () {
      emit("saveAgentDefault", { providerID: item.providerID, installationID: item.installationID, modelID: model.control.value || null, effort: effort.control.value || null, permissionMode: permission.control.value });
    });
    actions.appendChild(save);
    if (item.canRefreshModels) actions.appendChild(S.button(item.isRefreshingModels ? "刷新中…" : "刷新模型列表", "refreshAgentModels", { providerID: item.providerID, installationID: item.installationID }, emit, "small", item.isRefreshingModels));
    wrapper.appendChild(actions);
    if (item.errorMessage) wrapper.appendChild(S.node("p", "hint", item.errorMessage));
    return wrapper;
  }

  function serviceCard(page, emit) {
    var card = S.node("section", "page-card settings-card");
    card.appendChild(S.node("h3", null, "后台服务"));
    card.appendChild(S.node("p", "hint", page.serviceDescription));
    card.appendChild(S.node("p", "hint", "平台：" + page.servicePlatform));
    var keep = check("退出 App 后继续运行", page.keepServiceRunningAfterExit);
    keep.wrapper.querySelector("input").disabled = !page.canChangeService;
    keep.wrapper.querySelector("input").addEventListener("change", function () {
      emit("setKeepServiceRunning", { keepServiceRunningAfterExit: keep.control.checked });
    });
    card.appendChild(keep.wrapper);
    card.appendChild(S.badge(page.serviceRegistered ? "已注册" : "未注册", page.serviceRegistered ? "success" : "warning"));
    var actions = S.node("div", "form-actions");
    if (page.canChangeService) actions.appendChild(S.button(page.serviceRegistered ? "注销后台服务" : "注册后台服务", page.serviceRegistered ? "unregisterService" : "registerService", {}, emit, page.serviceRegistered ? "small danger" : "small primary", false));
    card.appendChild(actions);
    return card;
  }

  function modelSelect(label, value, models) {
    var choices = S.safeArray(models).map(function (model) { return { id: model.modelID, title: model.displayName }; });
    return S.selectField(label, value, S.choices(value, choices), function () {}, "");
  }

  function check(label, value) {
    var wrapper = S.node("label", "check-field");
    var control = S.node("input");
    control.type = "checkbox";
    control.checked = !!value;
    wrapper.appendChild(control);
    wrapper.appendChild(S.node("span", null, label));
    return { wrapper: wrapper, control: control };
  }

  function settingButton(title, command, payload, emit, disabled) {
    return S.button(title, command, payload, emit, "small primary", disabled);
  }

  global.CodexBridgeDesktopSettingsPage = { render: render };
}(window));
