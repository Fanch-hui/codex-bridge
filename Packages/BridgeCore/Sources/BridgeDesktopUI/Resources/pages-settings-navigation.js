(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  var M = global.CodexBridgeDesktopSettingsModels;

  function group(container, title) {
    var section = S.section(container, title);
    section.className += " shared-settings-group";
    var stack = S.node("div", "settings-stack");
    section.appendChild(stack);
    return stack;
  }

  function choiceTitle(value, choices) {
    var choice = S.safeArray(choices).find(function (item) { return item.id === value; });
    return choice ? choice.title : value || "默认";
  }

  function modelTitle(value, options) {
    var option = S.safeArray(options).find(function (item) { return item.modelID === value; });
    return option ? option.displayName : value || "Provider 默认";
  }

  function effortTitle(value, choices) {
    return value ? choiceTitle(value, choices) : "默认强度";
  }

  function agentSummary(item) {
    if (!item.installationID) return "";
    var parts = [modelTitle(item.model, item.modelOptions)];
    if (item.providerID !== "antigravity" && item.canSelectEffort !== false) {
      parts.push(effortTitle(item.effort, item.effortOptions));
    }
    parts.push(choiceTitle(item.permissionMode, item.permissionOptions));
    return parts.join(" · ");
  }

  function agentStatus(status, item) {
    var label = "就绪", tone = "success";
    var desktopNotRunning = global.CodexBridgeDesktopSettingsAgents.desktopNotRunning(item);
    if (desktopNotRunning) { label = "DSH 桌面版未打开"; tone = "neutral"; }
    else if (!item.installationID) { label = "未连接"; tone = "warning"; }
    else if (item.isRefreshingModels) { label = "正在获取模型"; tone = "running"; }
    else if (item.errorMessage) { label = "设置异常"; tone = "error"; }
    status.hidden = tone === "success";
    S.updateStatus(status, label, tone);
    if (item.errorMessage && tone !== "running" && !desktopNotRunning) status.title = item.errorMessage;
  }

  function create(container, page, emit) {
    var details = global.CodexBridgeDesktopDetailPages.create(container);
    var openDetail = details.open;
    details.open = function (id) {
      if (id === "agent:deepseek-harness" && global.CodexBridgeDesktopDSHWorkbench) {
        global.CodexBridgeDesktopDSHWorkbench.openSettings();
      } else openDetail(id);
    };
    var agentsGroup = group(details.overview, "Agent");
    var execution = group(details.overview, "执行策略");
    var clients = group(details.overview, "客户端指令");
    var application = group(details.overview, "应用运行");
    var codex = M.preferences(page, emit, true);
    var codexEntry = details.register("codex", "Codex", codex.root);
    agentsGroup.appendChild(codexEntry.root);
    var codexStatus = S.status("就绪", "success");
    codexEntry.accessory.appendChild(codexStatus);
    var direct = global.CodexBridgeDesktopDirect.create();
    var directEntry = details.register("direct", "Direct 命令规则", direct.root);
    execution.appendChild(directEntry.root);
    var instructions = global.CodexBridgeDesktopSettingsInstructions.create(page, emit);
    var instructionsEntry = details.register("instructions", "全局自定义指令", instructions.root);
    clients.appendChild(instructionsEntry.root);
    var qoder = global.CodexBridgeDesktopSettingsQoderPermissions.create();
    var providers = new Map();

    function provider(id, title) {
      var current = providers.get(id);
      if (current) return current;
      var body = S.node("div", "settings-stack");
      current = { body: body, editors: new Map(), keys: new Set(), entry: details.register("agent:" + id, title, body) };
      current.status = S.status("就绪", "success");
      current.entry.accessory.appendChild(current.status);
      providers.set(id, current);
      agentsGroup.appendChild(current.entry.root);
      if (id === "qoder") body.appendChild(qoder.root);
      return current;
    }

    function update(next, nextEmit) {
      codex.update(next, nextEmit);
      codexStatus.hidden = !next.modelError && !next.isRefreshingModels;
      S.updateStatus(codexStatus, next.modelError ? "模型获取失败" : "正在获取模型", next.modelError ? "error" : "running");
      codexEntry.update({ value: [modelTitle(next.executionModel, next.models),
        effortTitle(next.executionEffort, next.effortOptions), choiceTitle(next.accessMode, next.accessOptions)].join(" · ") });
      direct.update(next.direct, nextEmit);
      directEntry.update({ available: !!next.direct, value: next.direct
        ? choiceTitle(next.direct.commandMode, [{ id: "denied", title: "关闭" }, { id: "safe", title: "安全模式" }, { id: "full", title: "完整模式" }]) : "" });
      instructions.update(next, nextEmit);
      instructionsEntry.update({ value: next.customInstructions ? "已设置" : "未设置" });
      var visible = new Set(), keys = new Map();
      S.safeArray(next.agentDefaults).forEach(function (item) {
        if (item.providerID === "deepseek-harness") return;
        visible.add(item.providerID);
        var current = provider(item.providerID, item.providerName);
        var key = item.installationID || "default";
        if (!keys.has(item.providerID)) keys.set(item.providerID, new Set());
        keys.get(item.providerID).add(key);
        var editor = current.editors.get(key);
        if (!editor) {
          editor = global.CodexBridgeDesktopSettingsAgents.editor(item, nextEmit);
          current.editors.set(key, editor);
          current.body.appendChild(editor.root);
        }
        editor.root.hidden = false;
        editor.update(item, nextEmit);
        agentStatus(current.status, item);
        current.entry.update({ title: item.providerName, value: agentSummary(item) });
      });
      var nativePolicy = next.nativePermissionPolicy;
      if (nativePolicy && nativePolicy.providerID === "qoder") {
        visible.add("qoder");
        provider("qoder", nativePolicy.providerName || "Qoder");
      }
      qoder.update(next, nextEmit);
      providers.forEach(function (current, id) {
        var nextKeys = keys.get(id) || new Set();
        var removed = Array.from(current.keys).some(function (key) { return key !== "default" && !nextKeys.has(key); });
        if (removed) current.entry.update({ available: false });
        current.editors.forEach(function (editor, key) { editor.root.hidden = !nextKeys.has(key); });
        current.keys = nextKeys;
        current.entry.update({ available: visible.has(id) });
      });
    }
    return { details: details, execution: execution, application: application, update: update };
  }

  global.CodexBridgeDesktopSettingsNavigation = { create: create };
}(window));
