(function (global) {
  "use strict";

  var S = global.CodexBridgeDesktopPageSupport;
  var E = global.CodexBridgeDesktopConnectionsEditors;

  function render(page, emit) {
    var container = document.getElementById("connections-content");
    if (!container.__connectionsPage) container.__connectionsPage = create(container, emit);
    container.__connectionsPage.update(page, emit);
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

    var agentsSection = S.section(content, "本机 Agent 引擎连接");
    var agentsCard = S.node("div", "page-card connection-card");
    agentsCard.appendChild(S.node("h3", null, "已登记安装"));
    var installations = S.node("div");
    agentsCard.appendChild(installations);
    var agentEditor = E.createAgentRegistration(emit);
    agentsCard.appendChild(agentEditor.root);
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
          S.empty(unavailable, "连接页暂不可用", "连接本机 Service 后，可以管理 MCP 客户端、Secure Tunnel 与 Agent。");
          return;
        }
        S.pageHeader(header, page.header);
        renderSummary(summary, page);
        renderLocalMCP(localCard, page, context);
        renderTunnel(
          tunnelBadge,
          tunnelSubtitle,
          tunnelFacts,
          tunnelDiagnostics,
          tunnelEditor,
          tunnelActions,
          page.tunnel,
          context
        );
        clientsEditor.update(page.clients, nextEmit);
        renderAgents(installations, agentEditor, page, nextEmit);
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
    addFact(facts, "绑定 Tunnel ID", tunnel.tunnelID || "未配置");
    addFact(facts, "Helper", tunnel.helperAvailable ? "就绪" : "未打包");
    addFact(facts, "远程任务接收", tunnel.acceptsRemoteSubmissions ? "允许" : "关闭");
    addFact(facts, "配置状态", tunnel.configured ? "已配置" : "未配置");
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

  function renderAgents(container, editor, page, emit) {
    S.clear(container);
    S.safeArray(page.installations).forEach(function (installation) {
      container.appendChild(agentRow(installation, emit));
    });
    if (!page.installations || page.installations.length === 0) {
      container.appendChild(S.node("div", "list-empty", "尚未登记本机 Agent。"));
    }
    editor.update(page.providers, page.canRegisterAgent, emit);
  }

  function agentRow(installation, emit) {
    var row = S.node("div", "agent-row");
    row.appendChild(S.icon("cpu.fill", "service-icon"));
    var main = S.node("div", "row-main");
    var heading = S.node("div", "client-heading");
    heading.appendChild(S.node("div", "row-title", installation.displayName));
    heading.appendChild(S.badge(
      availabilityLabel(installation.availability),
      availabilityTone(installation.availability)
    ));
    main.appendChild(heading);
    main.appendChild(S.node("div", "row-detail mono", installation.providerID + " · " + installation.executablePath));
    main.appendChild(S.node("div", "row-detail", (installation.version || "未识别")
      + " · ACP " + (installation.protocolRevision || "未协商")
      + " · Adapter r" + installation.adapterRevision));
    main.appendChild(S.node("div", "row-detail", "状态：" + availabilityLabel(installation.availability)
      + " · 有效能力：" + (installation.effectiveCapabilities || []).length + " 项"));
    if (installation.lastProbeError) main.appendChild(S.node("div", "row-detail", installation.lastProbeError));
    row.appendChild(main);
    var actions = S.node("div", "client-controls");
    var enabled = S.node("label", "check-field");
    var checkbox = S.node("input");
    checkbox.type = "checkbox";
    checkbox.checked = installation.enabled;
    checkbox.disabled = !installation.canToggle;
    checkbox.addEventListener("change", function () {
      emit("setAgentEnabled", { installationID: installation.installationID, enabled: checkbox.checked });
    });
    enabled.appendChild(checkbox);
    enabled.appendChild(S.node("span", null, "启用"));
    actions.appendChild(enabled);
    actions.appendChild(S.button("重新 Probe", "reprobeAgent", {
      installationID: installation.installationID,
      acceptReplacement: false
    }, emit, "small", !installation.canReprobe));
    if (installation.availability === "needs_review" && installation.canReprobe) {
      var accept = S.button("接受替换并 Probe", null, {}, null, "small primary", false);
      accept.addEventListener("click", function () {
        if (global.confirm("接受新的 Agent 可执行文件并重新 Probe？")) {
          emit("reprobeAgent", { installationID: installation.installationID, acceptReplacement: true });
        }
      });
      actions.appendChild(accept);
    }
    var remove = S.button("移除登记", null, {}, null, "small danger", !installation.canRemove);
    remove.addEventListener("click", function () {
      if (global.confirm("移除这个 Agent 登记？本机可执行文件不会被删除。")) {
        emit("removeAgent", { installationID: installation.installationID });
      }
    });
    actions.appendChild(remove);
    row.appendChild(actions);
    return row;
  }

  function availabilityLabel(value) {
    if (value === "available") return "可用";
    if (value === "needs_review") return "需复核";
    if (value === "unavailable") return "不可用";
    return "未知";
  }

  function availabilityTone(value) {
    if (value === "available") return "success";
    if (value === "needs_review") return "warning";
    if (value === "unavailable") return "error";
    return "neutral";
  }

  function addFact(container, title, value) {
    var item = S.node("div", "detail-item");
    item.appendChild(S.node("dt", null, title));
    item.appendChild(S.node("dd", null, value));
    container.appendChild(item);
  }

  function tunnelTone(tunnel) {
    if (tunnel.actionRequired) return "warning";
    if (tunnel.lifecycle === "ready") return "success";
    if (tunnel.enabled) return "running";
    return "neutral";
  }

  global.CodexBridgeDesktopConnectionsPage = { render: render };
}(window));
