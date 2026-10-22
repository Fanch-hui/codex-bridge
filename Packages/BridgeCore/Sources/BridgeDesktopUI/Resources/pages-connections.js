(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  var E = global.CodexBridgeDesktopConnectionsEditors;
  var active = false, timer = null, currentPage = null, currentEmit = null;
  var pendingDetail = null, permissionErrorSignature = "";
  function setActive(value, emit) {
    currentEmit = emit;
    if (active === value) return;
    active = value;
    if (!active && timer) { global.clearTimeout(timer); timer = null; }
    if (active) {
      global.setTimeout(function () { if (active) currentEmit("refreshAgentSetups", {}); }, 0);
      schedule();
    }
  }
  function schedule() {
    var setupsRunning = currentPage && S.safeArray(currentPage.setupOperations).some(
      global.CodexBridgeDesktopAgentSetup.running);
    var cloud = currentPage && currentPage.geminiCloud;
    var cloudPending = cloud && cloud.enabled && cloud.hosting === "sites" &&
      (cloud.lifecycle === "connecting" || cloud.lifecycle === "failed");
    if (timer || !active || !currentPage || (!setupsRunning && !cloudPending)) return;
    timer = global.setTimeout(function () {
      timer = null;
      if (active) {
        if (setupsRunning) currentEmit("refreshAgentSetups", {});
        if (cloudPending) currentEmit("refreshGeminiCloud", {});
        schedule();
      }
    }, setupsRunning ? 1500 : 3000);
  }

  function render(page, emit) {
    currentPage = page; currentEmit = emit; schedule();
    var container = document.getElementById("connections-content");
    if (!container.__connectionsPage) container.__connectionsPage = create(container, emit);
    container.__connectionsPage.update(page, emit);
    if (pendingDetail) deliverDetail(container);
  }

  function create(container, emit) {
    S.clear(container);
    var context = { emit: emit };
    var header = S.node("div"), content = S.node("div"), unavailable = S.node("div");
    container.appendChild(header); container.appendChild(content); container.appendChild(unavailable);
    var navigation = global.CodexBridgeDesktopDetailPages.create(content);
    var openDetail = navigation.open;
    navigation.open = function (id, options) {
      if (id === "agent:deepseek-harness" && global.CodexBridgeDesktopDSHWorkbench) {
        global.CodexBridgeDesktopDSHWorkbench.openSettings();
      } else {
        if (connectors && id.indexOf("agent:") === 0) connectors.locate(id.slice(6), options);
        openDetail(id, options);
      }
    };
    var N = global.CodexBridgeDesktopConnectionsNavigation;
    var T = global.CodexBridgeDesktopConnectionsTunnel;
    var clientsSection = S.section(navigation.overview, "聊天客户端");
    var clientsList = S.node("div", "page-card connection-list detail-list"); clientsSection.appendChild(clientsList);
    var chat = createChatGPT(context), qwen = createQwen(), gemini = createGemini();
    var chatEntry = navigation.register("chatgpt", "ChatGPT", chat.root);
    var qwenEntry = navigation.register("qwen", "Qwen Studio", qwen.root);
    var geminiEntry = navigation.register("gemini", "Gemini", gemini.root);
    clientsList.appendChild(chatEntry.root); clientsList.appendChild(qwenEntry.root);
    clientsList.appendChild(geminiEntry.root);

    var agentsSection = S.section(navigation.overview, "Agent");
    var agentsHeading = S.node("div", "section-heading-row");
    agentsHeading.appendChild(agentsSection.querySelector("h3"));
    var scanAgents = S.button("扫描 Agent", null, {}, null, "small", false);
    scanAgents.addEventListener("click", function () {
      if (scanAgents.disabled) return;
      scanAgents.disabled = true; context.emit("scanAgents");
    });
    var addMenu = S.node("details", "connection-add-menu");
    addMenu.appendChild(S.node("summary", null, "添加"));
    var addActions = S.node("div", "connection-menu-actions");
    addActions.appendChild(scanAgents); addMenu.appendChild(addActions);
    agentsHeading.appendChild(addMenu); agentsSection.appendChild(agentsHeading);
    var agentsList = S.node("div", "page-card connection-list detail-list"); agentsSection.appendChild(agentsList);
    var codex = global.CodexBridgeDesktopCodexConnection.create(emit);
    var codexEntry = navigation.register("codex", "Codex", codex.root);
    agentsList.appendChild(codexEntry.root);
    var connectors = global.CodexBridgeDesktopAgentConnectors.create(emit, navigation);
    agentsList.appendChild(connectors.root);
    var agentMCP = global.CodexBridgeDesktopDeepSeekHarnessMCP.create(emit, {
      excludedScopes: ["deepseek-harness"]
    });
    var mcpEntry = navigation.register("agent-mcp", "Agent MCP 服务", agentMCP.root);
    var advancedEntries = S.node("div"); advancedEntries.hidden = true;
    advancedEntries.appendChild(mcpEntry.root); content.appendChild(advancedEntries);
    mcpEntry.returnFocus = navigation.overview;
    var agentEditor = E.createAgentRegistration(emit);
    var manualEntry = navigation.register("agent-registration", "登记已有安装", agentEditor.root);
    addActions.appendChild(manualEntry.root);
    manualEntry.returnFocus = addMenu.querySelector("summary");
    manualEntry.root.addEventListener("click", function () { addMenu.open = false; });
    scanAgents.addEventListener("click", function () { addMenu.open = false; });
    var dshSettings = S.button("DSH ACP 开发台", null, {}, null, "small", false);
    dshSettings.addEventListener("click", function () { navigation.open("agent:deepseek-harness"); });
    agentsSection.appendChild(dshSettings);
    var status = S.node("div", "page-message"); content.appendChild(status);

    return {
      details: navigation,
      update: function (page, nextEmit) {
        context.emit = nextEmit;
        content.hidden = !page; unavailable.hidden = !!page;
        if (!page) {
          S.pageHeader(header, { title: "连接", symbol: "point.3.connected.trianglepath.dotted" });
          S.empty(unavailable, "连接页暂不可用", "连接后台服务后管理客户端与 Agent。");
          return;
        }
        context.statusMessage = page.statusMessage;
        if (global.CodexBridgeDesktopSettingsPage) global.CodexBridgeDesktopSettingsPage.updateClients(page.clients, nextEmit);
        S.pageHeader(header, Object.assign({}, page.header, { subtitle: "" }));
        chat.update(page, nextEmit); qwen.update(page, nextEmit); gemini.update(page, nextEmit);
        codex.update(page.codex, nextEmit);
        var tunnel = page.tunnel || {};
        var tunnelState = T.state(tunnel);
        N.update(chatEntry, "ChatGPT", "Secure MCP Tunnel", tunnelState.label, tunnelState.tone);
        var qwenClient = S.safeArray(page.clients).find(function (item) { return item.clientID === "qwen.studio"; });
        var localReady = page.localMCPState === "ready";
        N.update(qwenEntry, "Qwen Studio", "本机 MCP", !localReady ? "本机地址不可用"
          : qwenClient && qwenClient.enabled ? "已启用" : "未启用",
          !localReady ? "warning" : qwenClient && qwenClient.enabled ? "success" : "neutral");
        var geminiClient = S.safeArray(page.clients).find(function (item) { return item.clientID === "google.gemini"; });
        var geminiConnected = geminiClient && geminiClient.activeSessionCount > 0;
        var geminiCloud = page.geminiCloud;
        var cloudStatus = global.CodexBridgeDesktopGeminiCloud.status(geminiCloud || {});
        var cloudEnabled = geminiCloud && geminiCloud.enabled;
        N.update(geminiEntry, "Gemini", "网页版 / 同机客户端", !localReady ? "服务不可用"
          : cloudEnabled ? cloudStatus.label
          : geminiConnected ? "本地已连接" : geminiClient && geminiClient.enabled ? "等待连接" : "未启用",
          !localReady ? "warning" : cloudEnabled ? cloudStatus.tone : geminiConnected ? "success" : "neutral");
        var engine = page.codex || {};
        var connected = typeof engine.isConnected === "boolean" ? engine.isConnected
          : engine.modelCount > 0 && !engine.modelError;
        N.update(codexEntry, "Codex", engine.resolvedExecutablePath || "自动发现",
          engine.modelError ? "连接检查失败" : engine.isRefreshing ? "连接中" : connected ? "已连接" : "未连接",
          engine.modelError ? "error" : engine.isRefreshing ? "running" : connected ? "success" : "neutral");
        var providers = S.safeArray(page.providers).filter(function (provider) {
          return provider.providerID !== "codex" && provider.providerID !== "deepseek-harness";
        });
        connectors.update(providers, page.installations, {
          canConnect: page.canRegisterAgent, busy: page.isManagingAgents === true,
          revision: page.agentOperationRevision, setupOperations: page.setupOperations, acceptReplacement: true
        }, nextEmit);
        agentEditor.update(providers, page.canRegisterAgent && !page.isManagingAgents, nextEmit);
        agentMCP.update(page, nextEmit);
        mcpEntry.update({ value: page.selectedAgentMCPScope === "deepseek-harness"
          ? "选择 Agent" : S.safeArray(page.deepSeekHarnessMCPServers).length + " 个服务" });
        manualEntry.update({ value: "按路径或选择文件" });
        scanAgents.disabled = !page.canScanAgents || !!page.isManagingAgents;
        status.textContent = page.statusMessage || ""; status.hidden = !page.statusMessage;
      }
    };
  }

  function createChatGPT(context) {
    var T = global.CodexBridgeDesktopConnectionsTunnel;
    var root = S.node("div", "connection-detail");
    var section = S.section(root, "Secure MCP Tunnel");
    var card = S.node("div", "page-card connection-card"); section.appendChild(card);
    var badge = S.node("span"); card.appendChild(badge);
    var diagnostics = S.node("div", "connection-diagnostics"); card.appendChild(diagnostics);
    var editor = E.createTunnelForm(context.emit); card.appendChild(editor.root);
    var actions = S.node("div", "form-actions"); card.appendChild(actions);
    var proxy = E.createTunnelHTTPProxyForm(context.emit);
    var proxyOptions = S.node("details", "connection-advanced");
    proxyOptions.appendChild(S.node("summary", null, "HTTP(S) 代理"));
    proxyOptions.appendChild(proxy.root); card.appendChild(proxyOptions);
    var clients = E.createClients(context.emit, { mode: "connection" }); S.section(root, "连接").appendChild(clients.root);
    var help = S.node("details", "connection-help"); help.appendChild(S.node("summary", null, "接入帮助"));
    help.appendChild(S.node("p", null,
      "ChatGPT 需要 Plus 及以上或团队订阅。在“插件 → 添加 → 创建自定义 MCP 服务器”添加 Codex Bridge，再填写 Tunnel ID 和 Runtime Key。"));
    root.appendChild(help);
    return { root: root, update: function (page, emit) {
      T.render(badge, diagnostics, editor, actions, page.tunnel || {}, context);
      proxy.update(page.tunnel || {}, emit);
      clients.update(S.safeArray(page.clients).filter(function (item) { return item.clientID === "openai.chatgpt"; }), emit);
    } };
  }

  function createQwen() {
    var context = { emit: currentEmit };
    var root = S.node("div", "connection-detail"), local = S.node("div", "page-card connection-card connection-endpoint");
    S.section(root, "本机地址").appendChild(local);
    var clients = E.createClients(currentEmit, { mode: "connection" }); S.section(root, "连接").appendChild(clients.root);
    var help = S.node("details", "connection-help"); help.appendChild(S.node("summary", null, "接入帮助"));
    help.appendChild(S.node("p", null, "启用 Qwen Studio 并复制 JSON 配置，将配置粘贴到 Qwen Studio 的 MCP 设置中。"));
    root.appendChild(help);
    return { root: root, update: function (page, emit) {
      context.emit = emit;
      context.statusMessage = page.statusMessage;
      global.CodexBridgeDesktopConnectionsTunnel.recoverPending(local, context, {
        rotateLocalMCPEndpoint: page.canRotateLocalMCPEndpoint
      });
      var renderLocal = function () {
        global.CodexBridgeDesktopConnectionsTunnel.renderLocal(local, page, context);
      };
      var signature = JSON.stringify([page.localMCPURL, page.localMCPState,
        page.canCopyLocalMCPURL, page.canRotateLocalMCPEndpoint]);
      var stable = global.CodexBridgeDesktopStableRender;
      if (stable) stable(local, signature, renderLocal); else renderLocal();
      clients.update(S.safeArray(page.clients).filter(function (item) { return item.clientID === "qwen.studio"; }), emit);
    } };
  }

  function createGemini() {
    var context = { emit: currentEmit, routeChosen: false, client: null };
    var root = S.node("div", "connection-detail");
    var route = S.selectField("使用方式", "web", [
      { id: "web", title: "网页版" }, { id: "local", title: "同机客户端" }
    ], function () { context.routeChosen = true; showRoute(); });
    root.appendChild(route.wrapper);
    var clients = E.createClients(currentEmit, { mode: "connection", hideCopy: true });
    S.section(root, "连接").appendChild(clients.root);
    var local = S.node("div", "connection-route"); root.appendChild(local);
    var copy = S.button("复制本地启动命令", null, {}, null, "small primary", true);
    copy.addEventListener("click", function () {
      if (!copy.disabled) context.emit("copyMCPClientConfiguration", { clientID: "google.gemini" });
    });
    local.appendChild(copy);
    var help = S.node("details", "connection-help");
    help.appendChild(S.node("summary", null, "接入帮助"));
    var steps = S.node("ol");
    [
      "确认同机客户端提供本地程序启动入口，再启用 Gemini 连接并复制本地启动命令。",
      "在客户端的 MCP 配置中选择本地 stdio，将服务器名称设为 Codex Bridge，粘贴启动命令。",
      "保存后启用 Codex Bridge，调用 bridge_status 和 list_projects 检查连接。",
      "使用期间保持后台服务运行；App 安装位置改变后重新复制启动命令。"
    ].forEach(function (text) { steps.appendChild(S.node("li", null, text)); });
    help.appendChild(steps); local.appendChild(help);
    var web = S.node("div", "connection-route"); root.appendChild(web);
    var cloud = global.CodexBridgeDesktopGeminiCloud.create(currentEmit); web.appendChild(cloud.root);
    function showRoute() { local.hidden = route.control.value !== "local"; web.hidden = !local.hidden; }
    showRoute();
    return { root: root, update: function (page, emit) {
      context.emit = emit;
      context.client = S.safeArray(page.clients).find(function (item) { return item.clientID === "google.gemini"; });
      if (!context.routeChosen && context.client && context.client.activeSessionCount > 0
        && !(page.geminiCloud && page.geminiCloud.enabled)) route.control.value = "local";
      clients.update(context.client ? [context.client] : [], emit);
      copy.disabled = !context.client || !context.client.enabled || !context.client.canCopyConfiguration;
      cloud.update(page.geminiCloud, emit); showRoute();
    } };
  }

  function openDetail(id, emit, options) {
    pendingDetail = { id: id, options: options };
    (emit || currentEmit)("selectPage", { navigation: "connections" });
    var container = document.getElementById("connections-content");
    if (active && container && container.__connectionsPage) {
      deliverDetail(container);
    }
  }
  function deliverDetail(container) {
    var details = container.__connectionsPage.details;
    details.open(pendingDetail.id, pendingDetail.options);
    if (details.selectedID() === pendingDetail.id || pendingDetail.id === "agent:deepseek-harness") pendingDetail = null;
  }
  function updateSettings(page, emit, updateState) {
    if (global.CodexBridgeDesktopSettingsPage && page) {
      global.CodexBridgeDesktopSettingsPage.render(page, emit, updateState);
      var policy = page.nativePermissionPolicy;
      var signature = policy && policy.errorMessage
        ? [policy.providerID, policy.installationID, policy.errorMessage].join(":") : "";
      if (signature && signature !== permissionErrorSignature) pendingDetail = { id: "agent:" + policy.providerID };
      permissionErrorSignature = signature;
    }
  }

  global.CodexBridgeDesktopConnectionsPage = { render: render, setActive: setActive, openDetail: openDetail, updateSettings: updateSettings };
}(window));
