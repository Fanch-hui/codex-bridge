(function (global) {
  "use strict";

  var S = global.CodexBridgeDesktopPageSupport;

  function create(emit) {
    var context = { emit: emit, connected: false };
    var section = S.node("section", "connection-detail");
    var card = S.node("div", "connection-card");
    section.appendChild(card);
    var badge = S.badge("未知", "neutral");
    card.appendChild(badge);
    var subtitle = S.node(
      "p",
      "card-subtitle",
      "连接已安装的 Codex 后即可在工作台使用。"
    );
    card.appendChild(subtitle);
    var facts = S.node("div", "detail-grid connection-runtime");
    var advanced = S.node("details", "connection-advanced");
    advanced.appendChild(S.node("summary", null, "高级配置"));
    advanced.appendChild(facts);
    var path = S.textField(
      "可执行文件路径（可选）",
      "",
      "留空自动发现，或填写可执行文件的绝对路径"
    );
    var draft = global.CodexBridgeDesktopFormDraft.bind({ path: path.control });
    var pathActions = S.node("div", "form-actions");
    var savePath = S.node("button", "button small", "保存路径");
    savePath.type = "button";
    var clearPath = S.node("button", "button small", "恢复自动发现");
    clearPath.type = "button";
    pathActions.appendChild(savePath);
    pathActions.appendChild(clearPath);
    advanced.appendChild(path.wrapper);
    advanced.appendChild(pathActions);
    var reconnect = S.button("重新连接", null, {}, null, "small", false);
    advanced.appendChild(reconnect);
    var diagnostics = S.node("div", "connection-diagnostics");
    card.appendChild(diagnostics);
    var actions = S.node("div", "form-actions");
    var refresh = S.button("连接 Codex", null, {}, null, "small primary", true);
    actions.appendChild(refresh);
    card.appendChild(actions);

    function executableEditable(codex) {
      return codex.canEditExecutable === true;
    }

    function update(page, nextEmit) {
      context.emit = nextEmit;
      var codex = page || {};
      var count = typeof codex.modelCount === "number" ? Math.max(0, codex.modelCount) : 0;
      context.connected = isConnected(codex, count);
      S.updateStatus(badge, statusLabel(codex, count), statusTone(codex, count));
      subtitle.hidden = context.connected;
      S.clear(facts);
      addFact(facts, "当前使用", resolvedLabel(codex));
      draft.update({ path: typeof codex.executablePath === "string" ? codex.executablePath : "" });
      var editable = executableEditable(codex);
      path.control.disabled = !editable;
      savePath.disabled = !editable;
      clearPath.disabled = !editable || !codex.executablePath;
      S.clear(diagnostics);
      if (codex.executablePath && !codex.resolvedExecutablePath) {
        diagnostics.appendChild(
          S.node(
            "div",
            "page-message error",
            "指定的路径当前不可用，请重新选择或恢复自动发现。"
          )
        );
      }
      if (codex.modelError) {
        diagnostics.appendChild(S.node("div", "page-message error", "模型目录读取失败：" + codex.modelError));
      }
      refresh.textContent = context.connected ? "打开工作台" : codex.isRefreshing ? "连接中…" : "连接";
      refresh.disabled = !context.connected && (codex.isRefreshing === true || codex.canRefresh !== true);
      reconnect.hidden = !context.connected;
      reconnect.disabled = codex.isRefreshing === true || codex.canRefresh !== true;
    }

    function emitPath(value) {
      context.emit("setCodexExecutable", { path: value });
    }

    savePath.addEventListener("click", function () {
      if (!savePath.disabled) emitPath(path.control.value.trim());
    });
    clearPath.addEventListener("click", function () {
      if (!clearPath.disabled) emitPath("");
    });
    refresh.addEventListener("click", function () {
      if (refresh.disabled) return;
      if (context.connected && global.CodexBridgeDesktopDSHWorkbench) {
        global.CodexBridgeDesktopDSHWorkbench.openCollaboration();
      } else context.emit("refreshModels", {});
    });
    reconnect.addEventListener("click", function () {
      if (!reconnect.disabled) context.emit("refreshModels", {});
    });
    var defaults = S.section(section, "任务默认设置");
    var defaultsBody = S.node("div", "agent-defaults-slot"); defaults.appendChild(defaultsBody);
    if (global.CodexBridgeDesktopSettingsPage) global.CodexBridgeDesktopSettingsPage.mountAgent("codex", defaultsBody);
    section.appendChild(advanced);
    update(null, emit);
    return { root: section, primaryActions: actions, status: badge, update: update };
  }

  function isConnected(codex, count) {
    return typeof codex.isConnected === "boolean" ? codex.isConnected : count > 0 && !codex.modelError;
  }

  function resolvedLabel(codex) {
    if (typeof codex.resolvedExecutablePath === "string" && codex.resolvedExecutablePath) {
      return codex.resolvedExecutablePath;
    }
    return codex.executablePath ? "未找到" : "自动发现";
  }

  function statusLabel(codex, count) {
    if (codex.modelError) return "模型目录失败";
    if (codex.isRefreshing) return "刷新中…";
    return isConnected(codex, count) ? "已连接" : "未连接";
  }

  function statusTone(codex, count) {
    if (codex.modelError) return "error";
    if (codex.isRefreshing) return "running";
    if (isConnected(codex, count)) return "success";
    return "neutral";
  }

  function addFact(container, title, value) {
    var item = S.node("div", "detail-item");
    item.appendChild(S.node("dt", null, title));
    item.appendChild(S.node("dd", null, value));
    container.appendChild(item);
  }

  global.CodexBridgeDesktopCodexConnection = { create: create };
}(window));
