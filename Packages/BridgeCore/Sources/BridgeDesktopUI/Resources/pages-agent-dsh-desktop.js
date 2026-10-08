(function (global) {
  "use strict";
  function create(S, emit) {
    var state = null, provider = null, busy = false, installationID = null, needsReview = false;
    var desktopProvider = false, pending = null, lastBusy = false;
    var root = S.node("div", "agent-config-panel");
    var panel = S.node("div", "agent-desktop-connection");
    var status = S.node("p", "hint"); status.setAttribute("role", "status");
    var code = S.node("p", "mono");
    var actions = S.node("div", "form-actions");
    var refresh = S.button("检测桌面连接", null, {}, null, "small", false);
    var revoke = S.button("撤销配对", null, {}, null, "small danger", false);
    actions.appendChild(refresh); actions.appendChild(revoke);
    panel.appendChild(status); panel.appendChild(code);
    panel.appendChild(S.node("p", "hint", "原生桌面当前支持完整权限和文本任务。"));
    var download = S.button("下载 DSH 桌面版", "openExternalURL",
      { value: "https://github.com/deepseek-ai/deepseek-harness/releases" }, emit, "small", false);
    panel.appendChild(download); root.appendChild(panel);
    function send(action) {
      if (busy || pending || (!installationID && action !== "installConnector")) return;
      var payload = { action: action };
      if (installationID) payload.installationID = installationID;
      else payload.providerID = "deepseek-harness-desktop";
      pending = action;
      emit("manageDeepSeekHarnessDesktop", payload);
    }
    refresh.addEventListener("click", function () { if (!refresh.disabled) send("status"); });
    revoke.addEventListener("click", function () { if (!revoke.disabled) send("revoke"); });
    function hasDesktop() {
      return !!(state && state.executablePath || installationID || provider.discoveredExecutablePath
        || provider.discoveryState === "discovered");
    }
    function connected() { return !!(state && state.connected && state.paired && !needsReview); }
    function waitingPairing() { return !!(state && !state.paired && state.pairingCode); }
    function notRunning() { return !!(state && state.errorCode === "desktop_not_running"); }
    function failed() {
      return !!(state && state.errorCode && state.errorCode !== "desktop_connector_not_ready"
        && state.errorCode !== "desktop_pairing_required" && !notRunning());
    }
    function label() {
      if (needsReview) return "需确认更新";
      if (connected()) return "已连接";
      if (failed()) return "连接失败";
      if (waitingPairing()) return "等待配对";
      if (pending === "installConnector") return "正在安装连接器";
      if (pending === "connect") return "正在连接";
      if (hasDesktop() && state && state.connectorInstalled && notRunning()) return "DSH 桌面版未打开";
      if (!hasDesktop()) return provider.discoveryState === "failed" ? "查找失败"
        : provider.discoveryState === "not_found" ? "未发现" : "正在查找";
      return state && state.connectorInstalled ? "待连接" : "待安装连接器";
    }
    function update(nextProvider, installations, nextBusy) {
      provider = nextProvider;
      desktopProvider = provider.providerID === "deepseek-harness-desktop";
      root.hidden = !desktopProvider; actions.hidden = !desktopProvider;
      if (root.hidden) return;
      busy = !!nextBusy;
      if (lastBusy && !busy) pending = null;
      lastBusy = busy;
      state = provider.desktop || null;
      installationID = state && state.installationID || (installations[0] && installations[0].installationID);
      needsReview = installations.some(function (item) {
        return item.installationID === installationID && item.availability === "needs_review";
      });
      if (connected() || waitingPairing() || failed() || pending === "installConnector" && state && state.connectorInstalled) pending = null;
      download.hidden = hasDesktop();
      code.hidden = !waitingPairing();
      code.textContent = waitingPairing() ? "配对确认码：" + state.pairingCode : "";
      refresh.hidden = !state || !state.paired || connected();
      refresh.disabled = busy || !!pending || !installationID;
      revoke.hidden = !state || !state.paired;
      revoke.disabled = busy || !!pending;
      status.textContent = needsReview ? "DSH 桌面安装已更新，请确认更新后重新连接。"
        : connected() ? "原生桌面已连接。任务与会话将显示在 DSH 桌面中。"
        : failed() ? state.message || "桌面连接失败，请重新连接。"
        : waitingPairing() ? "在 DSH 桌面的 Bridge Connector 中核对确认码并确认配对，完成后将自动连接。"
        : !hasDesktop() ? provider.discoveryMessage || "本机未发现 DSH 桌面版。安装后扫描 Agent。"
        : !state || !state.connectorInstalled ? "请完全退出 DSH 桌面，然后安装连接器。"
        : notRunning() ? "DSH 桌面版未打开。打开后保持在后台运行即可连接。"
        : "点击连接打开 DSH 桌面，在 Bridge Connector 中确认配对。";
    }
    function presentation() {
      var isConnected = connected(), waiting = waitingPairing();
      var install = !state || !state.connectorInstalled;
      return { label: label(), tone: needsReview ? "warning" : isConnected ? "success" : failed() ? "error" : "neutral",
        actionTitle: waiting ? "等待配对" : pending ? "处理中…" : install ? "安装连接器"
          : notRunning() ? "打开并连接" : "连接",
        actionHidden: isConnected || !hasDesktop(),
        canAct: !busy && !pending && !waiting && !needsReview && hasDesktop()
          && (install ? !state || state.canInstallConnector : !!installationID),
        actionHint: waiting ? "配对成功后自动更新连接状态。" : install ? "安装时需要完全退出 DSH 桌面。"
          : "使用 DSH 桌面的账号和原生会话。",
        waiting: !isConnected && !failed() && !needsReview,
        error: failed() ? state.message || "桌面连接失败，请重新连接。" : "" };
    }
    return { root: root, maintenanceRoot: actions, update: update, isDesktop: function () { return desktopProvider; },
      presentation: presentation, connected: connected, connect: function () {
        if (!presentation().canAct) return;
        send(!state || !state.connectorInstalled ? "installConnector" : "connect");
      } };
  }
  global.CodexBridgeDesktopDSHDesktop = { create: create };
}(window));
