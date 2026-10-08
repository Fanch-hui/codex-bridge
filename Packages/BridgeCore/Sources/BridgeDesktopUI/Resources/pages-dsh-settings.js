(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  var providerID = "deepseek-harness";

  function acp(item) { return item.providerID === providerID; }

  function catalog(item, emit) {
    var context = { item: item, emit: emit };
    var root = S.node("div", "dsh-model-catalog");
    var title = S.node("h4"); root.appendChild(title);
    var list = S.node("ul", "dsh-model-list"); root.appendChild(list);
    var empty = S.node("p", "hint", "暂无模型。"); root.appendChild(empty);
    var actions = S.node("div", "form-actions");
    var refresh = S.button("刷新模型列表", null, {}, null, "small");
    actions.appendChild(refresh); root.appendChild(actions);
    var error = S.node("p", "hint"); error.setAttribute("role", "status"); root.appendChild(error);
    refresh.addEventListener("click", function () {
      if (!refresh.disabled) context.emit("refreshAgentModels", {
        providerID: providerID, installationID: context.item.installationID
      });
    });
    function update(next, nextEmit) {
      context = { item: next, emit: nextEmit };
      title.textContent = next.installationName || ""; title.hidden = !title.textContent;
      S.clear(list);
      var models = S.safeArray(next.modelOptions);
      models.forEach(function (model) {
        var row = S.node("li"), name = model.displayName || model.modelID;
        row.appendChild(S.node("span", null, name));
        if (model.modelID !== name) row.appendChild(S.node("code", null, model.modelID));
        list.appendChild(row);
      });
      empty.hidden = models.length > 0;
      refresh.hidden = !next.canRefreshModels; refresh.disabled = !!next.isRefreshingModels;
      refresh.textContent = next.isRefreshingModels ? "刷新中…" : "刷新模型列表";
      error.textContent = next.errorMessage || ""; error.hidden = !error.textContent;
    }
    update(item, emit);
    return { root: root, update: update };
  }

  function create(emit) {
    var context = { emit: emit, page: null, active: false, timer: null };
    var root = S.node("div", "settings-stack dsh-engine-settings-content");
    root.dataset.providerID = providerID;
    var unavailable = S.node("p", "page-message", "连接本机 Service 后配置 DSH ACP 引擎。");
    root.appendChild(unavailable);
    var connection = S.section(root, "引擎连接");
    var actions = S.node("div", "form-actions");
    var scan = S.button("扫描安装", null, {}, null, "small", true);
    actions.appendChild(scan); connection.appendChild(actions);
    var connectors = global.CodexBridgeDesktopAgentConnectors.create(emit);
    connection.appendChild(connectors.root);
    var registration = global.CodexBridgeDesktopConnectionsEditors.createAgentRegistration(emit);
    var manual = S.node("details", "agent-details");
    manual.appendChild(S.node("summary", null, "登记已有安装"));
    manual.appendChild(registration.root); connection.appendChild(manual);
    var defaults = S.section(root, "模型目录");
    var preferences = S.node("div", "settings-stack"); defaults.appendChild(preferences);
    var empty = S.node("p", "hint", "连接 DSH ACP 后获取模型目录。");
    defaults.appendChild(empty);
    var editors = new Map();
    var mcp = global.CodexBridgeDesktopDeepSeekHarnessMCP.create(emit, {
      allowedScopes: [providerID]
    });
    S.section(root, "MCP 服务").appendChild(mcp.root);
    var status = S.node("p", "page-message"); status.setAttribute("role", "status");
    root.appendChild(status);

    scan.addEventListener("click", function () {
      if (!scan.disabled) { scan.disabled = true; context.emit("scanAgents", {}); }
    });

    function schedule() {
      if (!context.active || context.timer || !context.page) return;
      var operations = S.safeArray(context.page.setupOperations).filter(acp);
      if (!operations.some(global.CodexBridgeDesktopAgentSetup.running)) return;
      context.timer = global.setTimeout(function () {
        context.timer = null;
        if (context.active) { context.emit("refreshAgentSetups", {}); schedule(); }
      }, 1500);
    }

    function setActive(value, nextEmit) {
      if (nextEmit) context.emit = nextEmit;
      if (context.active === value) return;
      context.active = value;
      if (!value && context.timer) { global.clearTimeout(context.timer); context.timer = null; }
      if (value) { context.emit("refreshAgentSetups", {}); schedule(); }
    }

    function update(connectionsPage, settingsPage, nextEmit) {
      context.emit = nextEmit;
      context.page = connectionsPage;
      unavailable.hidden = !!connectionsPage;
      connection.hidden = !connectionsPage;
      var providers = S.safeArray(connectionsPage && connectionsPage.providers).filter(acp);
      if (connectionsPage) {
        connectors.update(providers, S.safeArray(connectionsPage.installations).filter(acp), {
          canConnect: connectionsPage.canRegisterAgent,
          busy: connectionsPage.isManagingAgents === true,
          revision: connectionsPage.agentOperationRevision,
          setupOperations: S.safeArray(connectionsPage.setupOperations).filter(acp),
          acceptReplacement: true
        }, nextEmit);
        registration.update(providers, connectionsPage.canRegisterAgent && !connectionsPage.isManagingAgents, nextEmit);
        scan.disabled = !connectionsPage.canScanAgents || !!connectionsPage.isManagingAgents;
        mcp.update(connectionsPage, nextEmit);
      } else {
        scan.disabled = true;
        registration.update([], false, nextEmit);
        mcp.update({}, nextEmit);
      }
      manual.hidden = !providers.length;
      var visible = new Set();
      S.safeArray(settingsPage && settingsPage.agentDefaults).filter(acp).forEach(function (item) {
        var key = item.installationID || "default", editor = editors.get(key);
        if (!editor) {
          editor = catalog(item, nextEmit);
          editors.set(key, editor); preferences.appendChild(editor.root);
        }
        editor.root.hidden = false;
        editor.update(item, nextEmit);
        visible.add(key);
      });
      editors.forEach(function (editor, key) { editor.root.hidden = !visible.has(key); });
      empty.hidden = visible.size > 0;
      status.textContent = connectionsPage && connectionsPage.statusMessage
        || settingsPage && settingsPage.statusMessage || "";
      status.hidden = !status.textContent;
      schedule();
    }

    return { root: root, update: update, setActive: setActive };
  }

  global.CodexBridgeDesktopDSHSettings = { create: create };
}(window));
