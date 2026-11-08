(function (global) {
  "use strict";
  // Shared composer parts for the web workbench: the new-task composer and the session
  // composer use the same layout as the conversation workbench (permission at the bottom
  // left, model and effort at the bottom right, one round send/stop button).
  var S = global.CodexBridgeDesktopPageSupport;
  var settings = null;

  function forms() { return global.CodexBridgeDesktopFormDraft; }
  function localizeEfforts(choices) {
    var composer = global.CodexBridgeDesktopDSHComposerView;
    return composer && composer.localizeEfforts ? composer.localizeEfforts(choices) : choices;
  }

  function agents() {
    var value = settings || {}, list = [];
    if (S.safeArray(value.models).length) {
      list.push({ key: "codex", providerID: "codex", installationID: null, title: "Codex",
        models: S.safeArray(value.models), model: value.executionModel || "", effort: value.executionEffort || "",
        effortOptions: S.safeArray(value.effortOptions), readOnly: true });
    }
    S.safeArray(value.agentDefaults).forEach(function (item) {
      if (!item.installationID || item.providerID === "codex") return;
      list.push({ key: item.providerID + ":" + item.installationID, providerID: item.providerID,
        installationID: item.installationID, title: item.providerName || item.providerID,
        models: S.safeArray(item.modelOptions), model: item.model || "", effort: item.effort || "",
        effortOptions: S.safeArray(item.effortOptions), errorMessage: item.errorMessage || "",
        readOnly: S.safeArray(item.permissionOptions).some(function (choice) { return choice.id === "read-only"; }) });
    });
    return list;
  }
  function agentFor(providerID, installationID) {
    return agents().find(function (agent) {
      return agent.providerID === providerID && (providerID === "codex" || agent.installationID === installationID);
    }) || null;
  }

  function choice(label, onChange, className) {
    var field = S.selectField(label, "", [], onChange, "workbench-composer-choice " + (className || ""));
    field.wrapper.querySelector("label").hidden = true;
    field.control.setAttribute("aria-label", label);
    S.autoFitSelect(field.control);
    return field;
  }

  // Builds the composer frame. `options.onSend`, `options.onStop`, `options.onPermission`
  // and `options.onModel`/`options.onEffort` receive user actions.
  function create(options) {
    var root = S.node("div", "message-composer workbench-agent-composer " + (options.className || ""));
    var surface = S.node("div", "message-composer-surface");
    var inputRow = S.node("div", "message-composer-input-row");
    var input = S.textAreaField(options.label || "消息", options.value || "", options.placeholder || "", "message-composer-input");
    input.control.id = options.inputID;
    input.control.classList.add("workbench-message-input");
    input.control.setAttribute("aria-label", options.label || "消息");
    input.wrapper.querySelector("label").htmlFor = input.control.id;
    input.wrapper.querySelector("label").hidden = true;
    inputRow.appendChild(input.wrapper); surface.appendChild(inputRow);
    var toolbar = S.node("div", "message-composer-toolbar");
    var leading = S.node("div", "message-composer-tools workbench-composer-leading");
    var trailing = S.node("div", "message-composer-tools workbench-composer-trailing");
    var permission = choice("Agent 权限", function (value) { if (options.onPermission) options.onPermission(value); },
      "workbench-composer-permission");
    forms().selectOptions(permission.control, [{ id: "full", title: "完整权限" }, { id: "read-only", title: "只读权限" }], false);
    leading.appendChild(permission.wrapper);
    var model = choice("模型", function (value) { if (options.onModel) options.onModel(value); }, "workbench-composer-model");
    var effort = choice("推理强度", function (value) { if (options.onEffort) options.onEffort(value); });
    trailing.appendChild(model.wrapper); trailing.appendChild(effort.wrapper);
    var action = S.button("", null, {}, null, "small primary message-composer-send dsh-composer-send workbench-composer-action");
    var symbol = S.node("span", null, "↑"); symbol.setAttribute("aria-hidden", "true"); action.appendChild(symbol);
    action.addEventListener("click", function () {
      if (action.disabled) return;
      if (action.__mode === "stop") { if (options.onStop) options.onStop(); } else if (options.onSend) options.onSend();
    });
    input.control.addEventListener("keydown", function (event) {
      if (event.key === "Enter" && !event.shiftKey && !global.CodexBridgeDesktopPageSupport.isIMEKeyEvent(event)) {
        event.preventDefault();
        if (action.__mode === "send" && !action.disabled && options.onSend) options.onSend();
      }
    });
    toolbar.appendChild(leading); toolbar.appendChild(trailing); toolbar.appendChild(action);
    surface.appendChild(toolbar); root.appendChild(surface);
    var hint = S.node("p", "hint message-composer-hint"); hint.setAttribute("role", "status"); hint.hidden = true;
    root.appendChild(hint);
    var view = { root: root, input: input.control, leading: leading, trailing: trailing,
      permission: permission.control, permissionWrapper: permission.wrapper,
      model: model.control, modelWrapper: model.wrapper, effort: effort.control, effortWrapper: effort.wrapper,
      action: action, symbol: symbol, hint: hint };
    setAction(view, "send", true);
    return view;
  }

  function setAction(view, mode, disabled, title) {
    var stop = mode === "stop";
    view.action.__mode = mode;
    view.action.disabled = !!disabled;
    view.action.classList.toggle("is-stop", stop);
    view.symbol.textContent = stop ? "■" : "↑";
    var label = title || (stop ? "停止" : "发送");
    view.action.title = label + (stop ? "" : "（Enter）");
    view.action.setAttribute("aria-label", label);
  }
  function setHint(view, text) {
    text = text || "";
    if (view.hint.textContent !== text) view.hint.textContent = text;
    view.hint.hidden = !text;
  }
  function setPermission(view, mode, allowReadOnly) {
    var value = mode === "read-only" ? "read-only" : "full";
    view.permission.value = value;
    view.permission.title = value === "read-only" ? "Agent 允许读取，禁止写入和联网" : "Agent 允许读取、写入和联网";
    var readOnly = Array.prototype.find.call(view.permission.options || [], function (item) { return item.value === "read-only"; });
    if (readOnly) readOnly.disabled = allowReadOnly === false && value !== "read-only";
  }
  // Fills the model and effort pickers for an Agent; returns the effective selection.
  function setModels(view, agent, modelID, effort, fallbackModel) {
    var D = forms();
    var models = agent ? agent.models.map(function (item) {
      return { id: item.modelID, title: item.displayName || item.modelID };
    }) : [];
    var current = modelID || fallbackModel || (agent && agent.model) || "";
    if (current && !models.some(function (item) { return item.id === current; })) {
      models.unshift({ id: current, title: current });
    }
    if (!current) models.unshift({ id: "", title: "默认模型" });
    D.selectOptions(view.model, models, false);
    view.model.value = current;
    view.modelWrapper.hidden = models.length === 0 || (models.length === 1 && !models[0].id);
    var chosen = agent && agent.models.find(function (item) {
      return current ? item.modelID === current : item.isDefaultModel === true;
    });
    var efforts = chosen ? S.safeArray(chosen.reasoningEfforts) : agent ? S.safeArray(agent.effortOptions) : [];
    var effortChoices = localizeEfforts(efforts.filter(function (item) { return item.id; }));
    var selectedEffort = effortChoices.some(function (item) { return item.id === effort; }) ? effort
      : effortChoices.some(function (item) { return item.id === (agent && agent.effort); }) ? agent.effort : "";
    if (!selectedEffort) effortChoices = [{ id: "", title: "默认强度" }].concat(effortChoices);
    D.selectOptions(view.effort, effortChoices, false);
    view.effort.value = selectedEffort;
    view.effortWrapper.hidden = efforts.length === 0;
    return { modelID: current || null, effort: selectedEffort || null };
  }

  global.CodexBridgeDesktopWorkbenchComposer = {
    setSettings: function (value) { settings = value || null; },
    agents: agents, agentFor: agentFor, choice: choice, create: create,
    setAction: setAction, setHint: setHint, setPermission: setPermission, setModels: setModels
  };
}(window));
