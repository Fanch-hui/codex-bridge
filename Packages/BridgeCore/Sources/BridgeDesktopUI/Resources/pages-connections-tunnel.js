(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;

  function sendPending(button, label, command, context) {
    button.__pendingCommand = command;
    button.__pendingLabel = label;
    button.__pendingStatusMessage = context.statusMessage || "";
    button.disabled = true;
    button.textContent = "请求中…";
    context.emit(command, {});
  }

  function recoverPending(container, context, allowed) {
    var message = context.statusMessage || "";
    container.querySelectorAll("button").forEach(function (button) {
      var command = button.__pendingCommand;
      if (!command) return;
      if (!message) { button.__pendingStatusMessage = ""; return; }
      if (message === button.__pendingStatusMessage) return;
      button.disabled = !allowed[command];
      button.textContent = button.__pendingLabel;
      button.__pendingCommand = null;
    });
  }

  function renderLocalMCP(card, page, context) {
    S.clear(card);
    card.appendChild(S.node("div", "page-message mono", page.localMCPURL || "Endpoint 尚未就绪"));
    if (page.localMCPState === "local_port_unavailable") {
      card.appendChild(S.node("div", "page-message warning", "本地 MCP 端口被占用；不会静默更换地址，请主动生成新的 Endpoint。"));
    }
    var state = S.node("div", "inline-status");
    state.appendChild(S.status(page.localMCPState === "ready" ? "已就绪" : page.localMCPState,
      page.localMCPState === "ready" ? "success" : "neutral"));
    if (page.canCopyLocalMCPURL) {
      var copy = S.button("复制 Endpoint", null, {}, null, "small", false);
      copy.addEventListener("click", function () {
        context.emit("copyLocalMCPEndpoint", {});
      });
      state.appendChild(copy);
    }
    if (page.canRotateLocalMCPEndpoint) {
      var rotate = S.button("重新生成 Endpoint", null, {}, null, "small danger", false);
      rotate.addEventListener("click", function () {
        if (global.confirm("重新生成本地 MCP Endpoint？现有客户端地址将立即失效。")) {
          sendPending(rotate, "重新生成 Endpoint", "rotateLocalMCPEndpoint", context);
        }
      });
      state.appendChild(rotate);
    }
    card.appendChild(state);
  }

  function renderTunnel(
    badge,
    diagnostics,
    editor,
    actions,
    tunnel,
    context
  ) {
    var currentState = state(tunnel);
    S.updateStatus(badge, currentState.label, currentState.tone);
    S.clear(diagnostics);
    if (!tunnel.helperAvailable) {
      diagnostics.appendChild(S.node("div", "page-message warning", "Helper 辅助工具缺失，本地 MCP 仍可用，但远程隧道不能启动。"));
    }
    if (tunnel.actionRequired) {
      diagnostics.appendChild(S.node("div", "page-message warning", "Tunnel 需要检查凭据，请核对 Tunnel ID、Runtime Key 以及当前工作区权限。"));
    }
    editor.update(tunnel, context.emit);
    recoverPending(actions, context, {
      connectTunnel: tunnel.canConnect, disconnectTunnel: tunnel.canDisconnect, clearTunnel: tunnel.canClear
    });
    var renderActions = function () {
      S.clear(actions);
      if (tunnel.canConnect) {
        var connect = S.button("连接", null, {}, null, "small primary", false);
        connect.addEventListener("click", function () {
          sendPending(connect, "连接", "connectTunnel", context);
        });
        actions.appendChild(connect);
      }
      if (tunnel.canDisconnect) {
        var disconnect = S.button("断开", null, {}, null, "small", false);
        disconnect.addEventListener("click", function () {
          sendPending(disconnect, "断开", "disconnectTunnel", context);
        });
        actions.appendChild(disconnect);
      }
      if (tunnel.canClear) {
        var clear = S.button("清除配置", null, {}, null, "small danger", false);
        clear.addEventListener("click", function () {
          if (global.confirm("清除 Secure Tunnel 配置？\n这会移除已保存的 Runtime Key 并重置 Tunnel 绑定。")) {
            editor.clearRuntimeKey();
            sendPending(clear, "清除配置", "clearTunnel", context);
          }
        });
        actions.appendChild(clear);
      }
    };
    var stable = global.CodexBridgeDesktopStableRender;
    var signature = JSON.stringify([
      tunnel.lifecycle, tunnel.actionRequired, tunnel.enabled, tunnel.configured,
      tunnel.helperAvailable, tunnel.canConnect, tunnel.canDisconnect, tunnel.canClear
    ]);
    if (stable) stable(actions, signature, renderActions); else renderActions();
  }

  function state(tunnel) {
    if (!tunnel.helperAvailable) return { label: "Helper 不可用", tone: "warning" };
    if (tunnel.actionRequired) return { label: "需要处理", tone: "warning" };
    var states = {
      ready: { label: "已连接", tone: "success" },
      stopped: { label: "未连接", tone: "neutral" },
      starting: { label: "启动中", tone: "running" },
      authenticating: { label: "认证中", tone: "running" },
      connecting: { label: "连接中", tone: "running" },
      degraded: { label: "连接异常", tone: "warning" },
      failed: { label: "连接失败", tone: "error" }
    };
    return states[tunnel.lifecycle] || { label: "未知", tone: "neutral" };
  }

  global.CodexBridgeDesktopConnectionsTunnel = {
    renderLocal: renderLocalMCP, render: renderTunnel, state: state, recoverPending: recoverPending
  };
}(window));
