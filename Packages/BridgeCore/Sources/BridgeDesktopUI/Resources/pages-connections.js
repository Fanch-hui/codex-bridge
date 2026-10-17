(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  var E = global.CodexBridgeDesktopConnectionsEditors;
  var active = false, timer = null, currentPage = null, currentEmit = null;
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
  }

  function create(container, emit) {
    S.clear(container);
    var context = { emit: emit };
    var header = S.node("div"), content = S.node("div"), unavailable = S.node("div");
    container.appendChild(header); container.appendChild(content); container.appendChild(unavailable);
    var navigation = global.CodexBridgeDesktopDetailPages.create(content);
    var openDetail = navigation.open;
    navigation.open = function (id) {
      if (id === "agent:deepseek-harness" && global.CodexBridgeDesktopDSHWorkbench) {
        global.CodexBridgeDesktopDSHWorkbench.openSettings();
      } else openDetail(id);
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

    var agentsSection = S.section(navigation.overview, "Agent 引擎");
    var agentsHeading = S.node("div", "section-heading-row");
    agentsHeading.appendChild(agentsSection.querySelector("h3"));
    var scanAgents = S.button("扫描 Agent", null, {}, null, "small", false);
    scanAgents.addEventListener("click", function () {
      if (scanAgents.disabled) return;
      scanAgents.disabled = true; context.emit("scanAgents");
    });
    agentsHeading.appendChild(scanAgents); agentsSection.appendChild(agentsHeading);
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
    agentsList.appendChild(mcpEntry.root);
    var agentEditor = E.createAgentRegistration(emit);
    var manualEntry = navigation.register("agent-registration", "登记已有安装", agentEditor.root);
    agentsList.appendChild(manualEntry.root);
    var status = S.node("div", "page-message"); content.appendChild(status);

    return {
      details: navigation,
      update: function (page, nextEmit) {
        context.emit = nextEmit;
        content.hidden = !page; unavailable.hidden = !!page;
        if (!page) {
          S.pageHeader(header, { title: "连接", symbol: "point.3.connected.trianglepath.dotted" });
          S.empty(unavailable, "连接页暂不可用", "连接本机 Service 后管理客户端与 Agent。");
          return;
        }
        context.statusMessage = page.statusMessage;
        S.pageHeader(header, Object.assign({}, page.header, { subtitle: "" }));
        chat.update(page, nextEmit); qwen.update(page, nextEmit); gemini.update(page, nextEmit);
        codex.update(page.codex, nextEmit);
        var tunnel = page.tunnel || {};
        var tunnelState = T.state(tunnel);
        N.update(chatEntry, "ChatGPT", "Secure MCP Tunnel", tunnelState.label, tunnelState.tone);
        var qwenClient = S.safeArray(page.clients).find(function (item) { return item.clientID === "qwen.studio"; });
        var localReady = page.localMCPState === "ready";
        N.update(qwenEntry, "Qwen Studio", "本机 MCP", !localReady ? "Endpoint 不可用"
          : qwenClient && qwenClient.enabled ? "已启用" : "未启用",
          !localReady ? "warning" : qwenClient && qwenClient.enabled ? "success" : "neutral");
        var geminiClient = S.safeArray(page.clients).find(function (item) { return item.clientID === "google.gemini"; });
        var geminiConnected = geminiClient && geminiClient.activeSessionCount > 0;
        var geminiCloud = page.geminiCloud;
        var cloudStatus = global.CodexBridgeDesktopGeminiCloud.status(geminiCloud || {});
        var cloudEnabled = geminiCloud && geminiCloud.enabled;
        N.update(geminiEntry, "Gemini", "本地 / 云 MCP", !localReady ? "服务不可用"
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
    var clients = E.createClients(context.emit); S.section(root, "连接与权限").appendChild(clients.root);
    var help = S.node("details", "connection-help"); help.appendChild(S.node("summary", null, "接入说明"));
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
    S.section(root, "本机 MCP Endpoint").appendChild(local);
    var clients = E.createClients(currentEmit); S.section(root, "连接与权限").appendChild(clients.root);
    var help = S.node("details", "connection-help"); help.appendChild(S.node("summary", null, "接入说明"));
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
    var root = S.node("div", "connection-detail");
    root.appendChild(S.node("p", "card-subtitle",
      "Gemini 网页版（包括 Bridge 内置浏览器）必须使用云 MCP，选择 Sites 或 ngrok。本地 MCP 仅用于与 Bridge 位于同一台电脑、能启动本机程序的 Gemini 桌面 App。"));
    root.appendChild(S.node("p", "card-subtitle",
      "Gemini 只有在“任务模式”下才能使用已添加的自定义 MCP。本地 MCP、Sites 和 ngrok 均适用。完成关联后，在任务模式中启用 Codex Bridge 应用，再发送请求。"));
    root.appendChild(S.node("p", "hint",
      "Gemini 的本地与云 MCP 均无需配置 OpenAI Platform、Tunnel ID 或 OpenAI Runtime API Key，也无需启用 ChatGPT 的 Tunnel 连接。委派 Agent 任务时，另行完成所选 Agent 的登录或 API 配置。"));
    var clients = E.createClients(currentEmit);
    S.section(root, "连接与权限").appendChild(clients.root);
    var help = S.node("details", "connection-help");
    help.appendChild(S.node("summary", null, "本地 MCP 接入说明（Gemini 桌面 App）"));
    var steps = S.node("ol");
    [
      "先在上方启用 Gemini 连接，再点击“复制本地启动命令”。",
      "打开与 Bridge 同机的 Gemini 桌面 App，依次进入“更多 → 自定义 → 关联应用”，点击右上角“＋自定义”，选择“本地 MCP”。",
      "服务器名称填写 Codex Bridge，说明可选；将复制的本地启动命令粘贴到“命令”。",
      "点击“下一步”，核对工具列表后完成关联。在 Gemini 中切换到“任务模式”，启用 Codex Bridge 应用，再调用 bridge_status 和 list_projects 检查连接。"
    ].forEach(function (text) { steps.appendChild(S.node("li", null, text)); });
    help.appendChild(steps);
    help.appendChild(S.node("p", "hint",
      "使用期间请保持本机 Codex Bridge 后台服务运行。更新 App 的安装位置后，请重新复制启动命令。"));
    root.appendChild(help);
    var cloud = global.CodexBridgeDesktopGeminiCloud.create(currentEmit);
    S.section(root, "云 MCP").appendChild(cloud.root);
    return { root: root, update: function (page, emit) {
      clients.update(S.safeArray(page.clients).filter(function (item) {
        return item.clientID === "google.gemini";
      }), emit);
      cloud.update(page.geminiCloud, emit);
    } };
  }

  global.CodexBridgeDesktopConnectionsPage = { render: render, setActive: setActive };
}(window));
