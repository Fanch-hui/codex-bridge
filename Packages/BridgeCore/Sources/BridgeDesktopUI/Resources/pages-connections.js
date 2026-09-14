(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  var E = global.CodexBridgeDesktopConnectionsEditors;

  function render(page, emit) {
    var container = document.getElementById("connections-content");
    if (!container.__connectionsPage) container.__connectionsPage = create(container, emit);
    container.__connectionsPage.update(page, emit);
  }

  function createDeepSeekSearch(emit) {
    var root = S.node("details", "page-card connection-card");
    root.appendChild(S.node("summary", null, "DeepSeek Harness 搜索服务"));
    root.appendChild(S.node("p", "card-subtitle",
      "搜索地址独立于聊天地址，复用 DSH API key。修改后对新任务和继续对话生效。"));
    var field = S.textField("搜索 Base URL", "", "https://api.deepseek.com/anthropic/v1");
    root.appendChild(field.wrapper);
    root.appendChild(S.node("p", "card-subtitle",
      "填写支持搜索工具的 Anthropic Messages API 基础地址，不包含 /messages。留空沿用已有配置或 DSH 默认地址。"));
    var draft = global.CodexBridgeDesktopFormDraft.bind({ baseURL: field.control });
    var save = S.button("保存搜索配置", null, {}, null, "small primary", true);
    var actions = S.node("div", "form-actions");
    actions.appendChild(save);
    root.appendChild(actions);
    var context = { emit: emit };
    save.addEventListener("click", function () {
      context.emit("saveDeepSeekSearchConfiguration", { baseURL: field.control.value.trim() });
    });
    return {
      root: root,
      update: function (page, nextEmit) {
        context.emit = nextEmit;
        draft.update({ baseURL: page.deepSeekSearchBaseURL || "" });
        save.disabled = page.canManageDeepSeekHarnessMCP !== true;
      }
    };
  }

  function create(container, emit) {
    S.clear(container);
    var context = { emit: emit };
    var header = S.node("div");
    var content = S.node("div");
    var unavailable = S.node("div");
    container.appendChild(header);
    container.appendChild(content);
    container.appendChild(unavailable);

    var summary = S.node("div", "connection-summary");
    content.appendChild(summary);
    var codex = global.CodexBridgeDesktopCodexConnection.create(emit);
    content.appendChild(codex.root);
    var localSection = S.section(content, "本地 MCP 客户端通道");
    var localCard = S.node("div", "page-card connection-card");
    localSection.appendChild(localCard);
    var tunnelSection = S.section(content, "远程 AI 客户端 (OpenAI Secure Tunnel)");
    var tunnelCard = S.node("div", "page-card connection-card");
    var tunnelTitle = S.node("div", "section-heading-row");
    var tunnelHeading = S.node("h3", null, "Secure MCP 隧道");
    var tunnelBadge = S.badge("unknown", "neutral");
    tunnelTitle.appendChild(tunnelHeading);
    tunnelTitle.appendChild(tunnelBadge);
    tunnelCard.appendChild(tunnelTitle);
    var tunnelSubtitle = S.node("p", "card-subtitle");
    tunnelCard.appendChild(tunnelSubtitle);
    var tunnelFacts = S.node("div", "detail-grid");
    tunnelCard.appendChild(tunnelFacts);
    var tunnelIDBlock = S.node("div");
    tunnelCard.appendChild(tunnelIDBlock);
    var tunnelDiagnostics = S.node("div");
    tunnelCard.appendChild(tunnelDiagnostics);
    var tunnelEditor = E.createTunnelForm(emit);
    tunnelCard.appendChild(tunnelEditor.root);
    var tunnelActions = S.node("div", "form-actions");
    tunnelCard.appendChild(tunnelActions);
    tunnelSection.appendChild(tunnelCard);

    var clientsSection = S.section(content, "本地 MCP 客户端");
    var clientsEditor = E.createClients(emit);
    clientsSection.appendChild(clientsEditor.root);
    var search = createDeepSeekSearch(emit);
    content.appendChild(search.root);
    var dshMCPSection = S.section(content, "DeepSeek Harness MCP");
    var dshMCP = global.CodexBridgeDesktopDeepSeekHarnessMCP.create(emit);
    dshMCPSection.appendChild(dshMCP.root);
    var agentsSection = S.section(content, "本机 Agent 引擎连接");
    var agentsCard = S.node("div", "page-card connection-card");
    agentsCard.appendChild(S.node("h3", null, "连接本机 Agent"));
    agentsCard.appendChild(S.node(
      "p",
      "card-subtitle",
      "Bridge 会自动查找本机安装；点击连接后才会启用。"
    ));
    var agentConnectors = global.CodexBridgeDesktopAgentConnectors.create(emit);
    agentsCard.appendChild(agentConnectors.root);
    var agentEditor = E.createAgentRegistration(emit);
    var manual = S.node("details", "agent-manual-registration");
    manual.appendChild(S.node("summary", null, "高级：按路径登记已有安装"));
    manual.appendChild(agentEditor.root);
    agentsCard.appendChild(manual);
    agentsSection.appendChild(agentsCard);

    var status = S.node("div", "page-message");
    content.appendChild(status);

    return {
      update: function (page, nextEmit) {
        context.emit = nextEmit;
        content.hidden = !page;
        unavailable.hidden = !!page;
        if (!page) {
          S.pageHeader(header, {
            title: "连接",
            subtitle: "正在从本机 Service 读取连接状态。",
            symbol: "point.3.connected.trianglepath.dotted"
          });
          S.empty(unavailable, "连接页暂不可用", "连接本机 Service 后，可以管理 MCP 客户端、Codex、Secure Tunnel 与 Agent。");
          return;
        }
        S.pageHeader(header, page.header);
        renderSummary(summary, page);
        codex.update(page.codex, nextEmit);
        renderLocalMCP(localCard, page, context);
        renderTunnel(
          tunnelBadge,
          tunnelSubtitle,
          tunnelFacts,
          tunnelIDBlock,
          tunnelDiagnostics,
          tunnelEditor,
          tunnelActions,
          page.tunnel,
          context
        );
        clientsEditor.update(page.clients, nextEmit);
        search.update(page, nextEmit);
        dshMCP.update(page, nextEmit);
        renderAgents(agentConnectors, agentEditor, page, nextEmit);
        status.textContent = page.statusMessage || "";
        status.hidden = !page.statusMessage;
      }
    };
  }

  function renderSummary(container, page) {
    S.clear(container);
    S.safeArray(page.summaryRows).forEach(function (row) {
      var card = S.node("div", "summary-card");
      card.appendChild(S.node("div", "summary-title", row.title));
      card.appendChild(S.node("div", "summary-value", row.value));
      container.appendChild(card);
    });
    if (!page.summaryRows || page.summaryRows.length === 0) {
      container.appendChild(S.node("div", "page-message", "暂无连接摘要。"));
    }
  }

  function renderLocalMCP(card, page, context) {
    S.clear(card);
    card.appendChild(S.node("h3", null, "本机 MCP Endpoint"));
    card.appendChild(S.node("p", "card-subtitle", "服务地址与客户端凭证由本机 Service 管理。"));
    card.appendChild(S.node("div", "page-message mono", page.localMCPURL || "Endpoint 尚未就绪"));
    card.appendChild(S.node("p", "hint", "仅监听 127.0.0.1；凭证由本机安全存储管理，不进明文状态或 SQLite。"));
    if (page.localMCPState === "local_port_unavailable") {
      card.appendChild(S.node("div", "page-message warning", "本地 MCP 端口被占用；不会静默更换地址，请主动生成新的 Endpoint。"));
    }
    var state = S.node("div", "inline-status");
    state.appendChild(S.badge(page.localMCPState, page.localMCPState === "ready" ? "success" : "neutral"));
    if (page.canCopyLocalMCPURL) {
      var copy = S.button("复制 Endpoint", null, {}, null, "small", false);
      copy.addEventListener("click", function () { context.emit("copyLocalMCPEndpoint", {}); });
      state.appendChild(copy);
    }
    if (page.canRotateLocalMCPEndpoint) {
      var rotate = S.button("重新生成 Endpoint", null, {}, null, "small danger", false);
      rotate.addEventListener("click", function () {
        if (global.confirm("重新生成本地 MCP Endpoint？现有客户端地址将立即失效。")) {
          context.emit("rotateLocalMCPEndpoint", {});
        }
      });
      state.appendChild(rotate);
    }
    card.appendChild(state);
  }

  function renderTunnel(
    badge,
    subtitle,
    facts,
    tunnelIDBlock,
    diagnostics,
    editor,
    actions,
    tunnel,
    context
  ) {
    badge.textContent = tunnel.lifecycle || "unknown";
    badge.className = "status-badge " + tunnelTone(tunnel);
    subtitle.textContent = tunnel.helperAvailable
      ? "Helper 已就绪，可按需连接远程通道。"
      : "当前环境没有可用 Helper，远程隧道不能启动。";
    S.clear(facts);
    addFact(facts, "Helper", tunnel.helperAvailable ? "就绪" : "未打包");
    addFact(facts, "远程任务接收", tunnel.acceptsRemoteSubmissions ? "允许" : "关闭");
    addFact(facts, "配置状态", tunnel.configured ? "已配置" : "未配置");
    renderTunnelID(tunnelIDBlock, tunnel, context);
    S.clear(diagnostics);
    if (!tunnel.helperAvailable) {
      diagnostics.appendChild(S.node("div", "page-message warning", "Helper 辅助工具缺失，本地 MCP 仍可用，但远程隧道不能启动。"));
    }
    if (tunnel.actionRequired) {
      diagnostics.appendChild(S.node("div", "page-message warning", "Tunnel 需要检查凭据，请核对 Tunnel ID、Runtime Key 以及当前工作区权限。"));
    }
    editor.update(tunnel, context.emit);
    S.clear(actions);
    if (tunnel.canConnect) {
      var connect = S.button("连接", null, {}, null, "small primary", false);
      connect.addEventListener("click", function () { context.emit("connectTunnel", {}); });
      actions.appendChild(connect);
    }
    if (tunnel.canDisconnect) {
      var disconnect = S.button("断开", null, {}, null, "small", false);
      disconnect.addEventListener("click", function () { context.emit("disconnectTunnel", {}); });
      actions.appendChild(disconnect);
    }
    if (tunnel.canClear) {
      var clear = S.button("清除配置", null, {}, null, "small danger", false);
      clear.addEventListener("click", function () {
        if (global.confirm("清除 Secure Tunnel 配置？\n这会移除已保存的 Runtime Key 并重置 Tunnel 绑定。")) {
          editor.clearRuntimeKey();
          context.emit("clearTunnel", {});
        }
      });
      actions.appendChild(clear);
    }
  }

  function renderAgents(connectors, editor, page, emit) {
    var providers = S.safeArray(page.providers).filter(function (provider) { return provider.providerID !== "codex"; });
    connectors.update(providers, page.installations, {
      canConnect: page.canRegisterAgent,
      busy: page.isManagingAgents === true,
      revision: page.agentOperationRevision,
      acceptReplacement: true
    }, emit);
    editor.update(providers, page.canRegisterAgent, emit);
  }

  function addFact(container, title, value) {
    var item = S.node("div", "detail-item");
    item.appendChild(S.node("dt", null, title));
    item.appendChild(S.node("dd", null, value));
    container.appendChild(item);
  }

  function renderTunnelID(container, tunnel, context) {
    S.clear(container);
    var tunnelID = typeof tunnel.tunnelID === "string" ? tunnel.tunnelID.trim() : "";
    if (!tunnelID) return;

    var block = S.node("div", "page-message");
    var heading = S.node("div", "section-heading-row");
    heading.appendChild(S.node("span", "muted", "已绑定的 Tunnel ID"));
    var copy = S.button("复制", null, {}, null, "small", false);
    copy.addEventListener("click", function () { context.emit("copyTunnelID", {}); });
    heading.appendChild(copy);
    block.appendChild(heading);
    block.appendChild(S.node("div", "mono", tunnelID));
    container.appendChild(block);
  }

  function tunnelTone(tunnel) {
    if (tunnel.actionRequired) return "warning";
    if (tunnel.lifecycle === "ready") return "success";
    if (tunnel.enabled) return "running";
    return "neutral";
  }

  global.CodexBridgeDesktopConnectionsPage = { render: render };
}(window));
