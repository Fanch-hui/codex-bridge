(function (global) {
  "use strict";
  function create(S, emit) {
    var state = null, busy = false, installationID = null, needsReview = false, desktopProvider = false;
    var root = S.node("div", "agent-config-panel");
    var panel = S.node("div", "agent-desktop-connection");
    var status = S.node("p", "hint"); status.setAttribute("role", "status");
    var code = S.node("p", "mono");
    var actions = S.node("div", "form-actions");
    var install = S.button("安装 Connector", null, {}, null, "small", false);
    var refresh = S.button("检测桌面连接", null, {}, null, "small", false);
    var revoke = S.button("撤销配对", null, {}, null, "small danger", false);
    [install, refresh, revoke].forEach(function (button) { actions.appendChild(button); });
    panel.appendChild(status); panel.appendChild(code); panel.appendChild(actions);
    panel.appendChild(S.node("p", "hint", "原生桌面当前支持完整权限和文本任务。"));
    var download = S.button("下载 DSH 桌面版", "openExternalURL",
      { value: "https://github.com/deepseek-ai/deepseek-harness/releases" }, emit, "small", false);
    panel.appendChild(download); root.appendChild(panel);
    function send(action) {
      if (!installationID || busy) return;
      emit("manageDeepSeekHarnessDesktop", { installationID: installationID, action: action });
    }
    install.addEventListener("click", function () { send("installConnector"); });
    refresh.addEventListener("click", function () { send("status"); });
    revoke.addEventListener("click", function () { send("revoke"); });
    function update(provider, installations, nextBusy) {
      desktopProvider = provider.providerID === "deepseek-harness-desktop";
      root.hidden = !desktopProvider;
      if (root.hidden) return;
      busy = nextBusy;
      state = provider.desktop || null;
      installationID = state && state.installationID || (installations[0] && installations[0].installationID);
      needsReview = installations.some(function (item) {
        return item.installationID === installationID && item.availability === "needs_review";
      });
      download.hidden = !!(state && state.executablePath);
      code.hidden = !(state && state.pairingCode);
      code.textContent = state && state.pairingCode ? "配对确认码：" + state.pairingCode : "";
      install.hidden = !!(state && state.connectorInstalled);
      install.disabled = busy || !state || !state.canInstallConnector;
      refresh.disabled = busy || !installationID;
      revoke.hidden = !state || !state.paired;
      revoke.disabled = busy;
      status.textContent = needsReview ? "DSH 桌面安装已更新，请点击连接重新验证。" : state && state.message || (!state || !state.executablePath
        ? "本机未发现 DSH 桌面版。安装后扫描 Agent。"
        : !state.connectorInstalled ? "请完全退出 DSH 桌面后安装 Connector，再启动桌面。"
        : state.pairingCode ? "在 DSH 桌面的 Bridge Connector 中核对确认码并确认配对，然后检测连接。"
        : state.paired && state.connected ? "原生桌面已连接。任务与会话将显示在 DSH 桌面中。"
        : state.paired ? "已配对，请启动 DSH 桌面后检测连接。"
        : "启动 DSH 桌面，点击连接并在桌面中确认配对。");
    }
    return { root: root, update: update, isDesktop: function () { return desktopProvider; },
      connect: function () {
        if (!state) emit("manageDeepSeekHarnessDesktop", { providerID: "deepseek-harness-desktop", action: "discover" });
        else send("connect");
      },
      connected: function () { return !!(state && state.connected && state.paired && !needsReview); },
      canConnect: function () { return !state || (!!installationID && state.connectorInstalled); } };
  }
  global.CodexBridgeDesktopDSHDesktop = { create: create };
}(window));
