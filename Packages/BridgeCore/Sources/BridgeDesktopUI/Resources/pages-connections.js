(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  var E = global.CodexBridgeDesktopConnectionsEditors;
  var active = false, timer = null, currentPage = null, currentEmit = null;
  var verificationUntil = 0, lastClientCheck = 0;
  var pendingDetail = null, permissionErrorSignature = "";
  function visible() { return !global.document || global.document.visibilityState !== "hidden"; }
  function watchClients() {
    verificationUntil = Date.now() + 60000;
    if (active && visible() && typeof currentEmit === "function") {
      currentEmit("refreshMCPClients", {}); lastClientCheck = Date.now(); schedule();
    }
  }
  function setActive(value, emit) {
    currentEmit = emit;
    if (active === value) return;
    active = value;
    if (!active && timer) { global.clearTimeout(timer); timer = null; }
    if (active) {
      global.setTimeout(function () { if (active) currentEmit("refreshAgentSetups", {}); }, 0);
      watchClients();
      schedule();
    }
  }
  function schedule() {
    var setupsRunning = currentPage && S.safeArray(currentPage.setupOperations).some(
      global.CodexBridgeDesktopAgentSetup.running);
    var cloud = currentPage && currentPage.geminiCloud;
    var checkingClients = Date.now() < verificationUntil;
    var cloudPending = checkingClients && cloud && cloud.enabled && cloud.hosting === "sites" &&
      (cloud.lifecycle === "connecting" || cloud.lifecycle === "failed");
    if (timer || !active || !visible() || !currentPage || (!setupsRunning && !cloudPending && !checkingClients)) return;
    timer = global.setTimeout(function () {
      timer = null;
      if (active && visible()) {
        if (setupsRunning) currentEmit("refreshAgentSetups", {});
        if (cloudPending) currentEmit("refreshGeminiCloud", {});
        if (Date.now() < verificationUntil && Date.now() - lastClientCheck >= 3000) {
          currentEmit("refreshMCPClients", {}); lastClientCheck = Date.now();
        }
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
    var content = S.node("div", "connections-page-content"), unavailable = S.node("div", "connections-unavailable");
    container.appendChild(content); container.appendChild(unavailable);
    var N = global.CodexBridgeDesktopConnectionsNavigation;
    var navigation = N.create(content);
    var openDetail = navigation.open;
    navigation.open = function (id, options) {
      if (id === "agent:deepseek-harness" && global.CodexBridgeDesktopDSHWorkbench) {
        global.CodexBridgeDesktopDSHWorkbench.openSettings();
      } else {
        if (connectors && id.indexOf("agent:") === 0) connectors.locate(id.slice(6), options);
        openDetail(id, options);
      }
    };
    var T = global.CodexBridgeDesktopConnectionsTunnel;
    var clientsSection = S.section(navigation.overview, "聊天客户端");
    var clientsList = S.node("div", "connection-list"); clientsSection.appendChild(clientsList);
    var chat = createChatGPT(context), qwen = createQwen(), gemini = createGemini();
    var chatEntry = navigation.register("chatgpt", "ChatGPT", chat.root);
    chatEntry.setActions(chat.primaryActions);
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
    var agentsList = S.node("div", "connection-list"); agentsSection.appendChild(agentsList);
    var dshEntry = S.node("button", "connection-list-item connection-workbench-link"); dshEntry.type = "button";
    var dshCopy = S.node("span", "connection-list-copy");
    dshCopy.appendChild(S.node("span", "connection-list-name", "工作台"));
    dshEntry.appendChild(dshCopy);
    dshEntry.addEventListener("click", function () {
      if (global.CodexBridgeDesktopDSHWorkbench) global.CodexBridgeDesktopDSHWorkbench.showDevelopment();
    });
    agentsList.appendChild(dshEntry);
    var codex = global.CodexBridgeDesktopCodexConnection.create(emit);
    var codexEntry = navigation.register("codex", "Codex", codex.root);
    codexEntry.setActions(codex.primaryActions);
    codexEntry.setStatus(codex.status);
    agentsList.appendChild(codexEntry.root);
    var connectors = global.CodexBridgeDesktopAgentConnectors.create(emit, navigation);
    agentsList.appendChild(connectors.root);
    var agentMCP = global.CodexBridgeDesktopDeepSeekHarnessMCP.create(emit, {
      excludedScopes: ["deepseek-harness"]
    });
    var mcpEntry = navigation.register("agent-mcp", "Agent MCP 服务", agentMCP.root);
    addActions.appendChild(mcpEntry.root);
    mcpEntry.root.addEventListener("click", function () { addMenu.open = false; });
    var agentEditor = E.createAgentRegistration(emit);
    var manualEntry = navigation.register("agent-registration", "登记已有安装", agentEditor.root);
    addActions.appendChild(manualEntry.root);
    manualEntry.root.addEventListener("click", function () { addMenu.open = false; });
    scanAgents.addEventListener("click", function () { addMenu.open = false; });
    var status = S.node("div", "page-message"); content.appendChild(status);
    navigation.open("chatgpt");

    return {
      details: navigation,
      update: function (page, nextEmit) {
        context.emit = nextEmit;
        content.hidden = !page; unavailable.hidden = !!page;
        if (!page) {
          S.empty(unavailable, "连接页暂不可用", "连接后台服务后管理客户端与 Agent。");
          return;
        }
        context.statusMessage = page.statusMessage;
        if (global.CodexBridgeDesktopSettingsPage) global.CodexBridgeDesktopSettingsPage.updateClients(page.clients, nextEmit);
        chat.update(page, nextEmit); qwen.update(page, nextEmit); gemini.update(page, nextEmit);
        codex.update(page.codex, nextEmit);
        var tunnel = page.tunnel || {};
        var tunnelState = T.state(tunnel);
        var chatClient = S.safeArray(page.clients).find(function (item) { return item.clientID === "openai.chatgpt"; });
        if (tunnel.lifecycle === "ready" && chatClient && chatClient.successfulToolCalls
          && chatClient.successfulToolCalls.shared) tunnelState = { label: "已完成调用", tone: "success" };
        N.update(chatEntry, "ChatGPT", "Secure MCP Tunnel", tunnelState.label, tunnelState.tone);
        var qwenClient = S.safeArray(page.clients).find(function (item) { return item.clientID === "qwen.studio"; });
        var localReady = page.localMCPState === "ready";
        var qwenSuccess = qwenClient && qwenClient.successfulToolCalls && qwenClient.successfulToolCalls.local;
        N.update(qwenEntry, "Qwen Studio", "本机 MCP", !localReady ? "本机地址不可用"
          : qwenSuccess && qwenClient.enabled ? "已完成调用"
          : qwenClient && qwenClient.enabled ? "服务就绪" : "未启用",
          !localReady ? "warning" : qwenClient && qwenClient.enabled ? "success" : "neutral");
        var geminiClient = S.safeArray(page.clients).find(function (item) { return item.clientID === "google.gemini"; });
        var geminiCalls = geminiClient && geminiClient.successfulToolCalls || {};
        var geminiConnected = geminiClient && geminiClient.activeSessionCount > 0;
        var geminiCloud = page.geminiCloud;
        var cloudStatus = global.CodexBridgeDesktopGeminiCloud.status(geminiCloud || {});
        var cloudEnabled = geminiCloud && geminiCloud.enabled;
        N.update(geminiEntry, "Gemini", "网页版 / 同机客户端", !localReady ? "服务不可用"
          : geminiClient && geminiClient.enabled && cloudEnabled && geminiCalls.cloud ? "云端已完成调用"
          : geminiClient && geminiClient.enabled && geminiCalls.local ? "本机已完成调用"
          : cloudEnabled ? cloudStatus.label
          : geminiConnected ? "本机服务就绪" : geminiClient && geminiClient.enabled ? "服务就绪" : "未启用",
          !localReady ? "warning" : geminiCalls.cloud || geminiCalls.local ? "success"
            : cloudEnabled ? cloudStatus.tone : geminiConnected ? "success" : "neutral");
        var engine = page.codex || {};
        var connected = typeof engine.isConnected === "boolean" ? engine.isConnected
          : engine.modelCount > 0 && !engine.modelError;
        N.update(codexEntry, "Codex", engine.resolvedExecutablePath || "自动发现",
          engine.isRefreshing ? "连接中" : connected && engine.modelError ? "已连接 · 模型目录异常"
            : connected ? "已连接" : engine.modelError ? "模型目录异常" : "未连接",
          engine.isRefreshing ? "running" : connected && engine.modelError ? "warning"
            : connected ? "success" : engine.modelError ? "error" : "neutral");
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
    var card = S.node("div", "connection-card"); root.appendChild(card);
    var badge = S.node("span");
    var diagnostics = S.node("div", "connection-diagnostics"); card.appendChild(diagnostics);
    var editor = E.createTunnelForm(context.emit);
    var credentialOptions = S.node("details", "connection-advanced connection-credentials");
    credentialOptions.appendChild(S.node("summary", null, "连接信息"));
    credentialOptions.appendChild(editor.root); card.appendChild(credentialOptions);
    var actions = S.node("div", "form-actions"); card.appendChild(actions);
    var advanced = S.node("details", "connection-advanced");
    advanced.appendChild(S.node("summary", null, "高级选项"));
    var diagnosticStats = S.node("div", "connection-diagnostics"); advanced.appendChild(diagnosticStats);
    var maintenance = S.node("div", "form-actions"); advanced.appendChild(maintenance);
    var proxy = E.createTunnelHTTPProxyForm(context.emit);
    var proxyOptions = S.node("details", "connection-advanced");
    proxyOptions.appendChild(S.node("summary", null, "HTTP(S) 代理"));
    proxyOptions.appendChild(proxy.root); advanced.appendChild(proxyOptions); card.appendChild(advanced);
    var clients = E.createClients(context.emit, { mode: "connection" }); S.section(root, "连接").appendChild(clients.root);
    var help = S.node("details", "connection-help"); help.appendChild(S.node("summary", null, "接入帮助"));
    help.appendChild(S.node("p", null,
      "ChatGPT 需要 Plus 及以上或团队订阅。在“插件 → 添加 → 创建自定义 MCP 服务器”添加 Codex Bridge，再填写 Tunnel ID 和 Runtime Key。"));
    root.appendChild(help);
    var configured;
    return { root: root, primaryActions: actions, update: function (page, emit) {
      var nextConfigured = !!(page.tunnel && page.tunnel.configured);
      if (configured !== nextConfigured) credentialOptions.open = !nextConfigured;
      configured = nextConfigured;
      T.render(badge, diagnostics, diagnosticStats, editor, actions, maintenance, page.tunnel || {}, context);
      proxy.update(page.tunnel || {}, emit);
      clients.update(S.safeArray(page.clients).filter(function (item) { return item.clientID === "openai.chatgpt"; }), emit);
    } };
  }

  function createQwen() {
    var context = { emit: currentEmit };
    var root = S.node("div", "connection-detail"), local = S.node("div", "page-card connection-card connection-endpoint");
    var clients = E.createClients(currentEmit, { mode: "connection" }); S.section(root, "连接").appendChild(clients.root);
    S.section(root, "本机地址").appendChild(local);
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
    var routeKey = "codexbridge.connections.gemini.route";
    var savedRoute = null;
    try { savedRoute = global.localStorage && global.localStorage.getItem(routeKey); } catch (_) {}
    if (savedRoute !== "web" && savedRoute !== "local") savedRoute = null;
    context.routeChosen = !!savedRoute;
    var root = S.node("div", "connection-detail");
    var route = S.selectField("使用方式", savedRoute || "web", [
      { id: "web", title: "网页版" }, { id: "local", title: "同机客户端" }
    ], function () {
      context.routeChosen = true;
      try { if (global.localStorage) global.localStorage.setItem(routeKey, route.control.value); } catch (_) {}
      showRoute();
    });
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
    var dispatch = emit || currentEmit;
    if (typeof dispatch !== "function") return false;
    pendingDetail = { id: id, options: Object.assign({ focus: true }, options || {}) };
    dispatch("selectPage", { navigation: "connections" });
    var container = document.getElementById("connections-content");
    if (active && container && container.__connectionsPage) {
      deliverDetail(container);
    }
    return true;
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

  if (global.document && global.document.addEventListener) global.document.addEventListener("visibilitychange", function () {
    if (!active) return;
    if (!visible() && timer) { global.clearTimeout(timer); timer = null; }
    else if (visible()) watchClients();
  });
  global.CodexBridgeDesktopConnectionsPage = { render: render, setActive: setActive, openDetail: openDetail,
    updateSettings: updateSettings, watchClients: watchClients };
}(window));
