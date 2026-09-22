(function (global) {
  "use strict";

  var busyPhases = {
    checking: true,
    downloading: true,
    waiting: true,
    installing: true
  };

  function node(tag, className, value) {
    var element = document.createElement(tag);
    if (className) element.className = className;
    if (value !== undefined && value !== null) element.textContent = value;
    return element;
  }

  function clear(element) {
    while (element && element.firstChild) element.removeChild(element.firstChild);
  }

  function icon(symbol) {
    var element = node("span", "icon");
    element.dataset.symbol = symbol;
    return element;
  }

  function phaseOf(update) {
    return update && update.phase ? String(update.phase) : "idle";
  }

  function updateSignature(update) {
    if (!update) return "none";
    return [
      update.phase,
      update.currentVersion,
      update.availableVersion,
      update.notes,
      update.progress,
      update.message,
      update.isDeferred
    ].map(function (value) { return String(value === undefined ? "" : value); }).join("\u001f");
  }

  function version(value) {
    if (value === undefined || value === null) return "未知";
    var text = String(value).trim();
    if (!text) return "未知";
    return /^v/i.test(text) ? text : "v" + text;
  }

  function progressValue(update) {
    if (!update || typeof update.progress !== "number" || !isFinite(update.progress)) return null;
    var value = update.progress <= 1 ? update.progress * 100 : update.progress;
    return Math.max(0, Math.min(100, value));
  }

  function isBusy(update) {
    return !!busyPhases[phaseOf(update)];
  }

  function titleFor(update) {
    var phase = phaseOf(update);
    if (phase === "available") return "发现新版本 " + version(update.availableVersion);
    if (phase === "checking") return "正在检查更新";
    if (phase === "upToDate") return "已是最新版本";
    if (phase === "downloading") return "正在下载更新";
    if (phase === "waiting") return "等待任务完成后更新";
    if (phase === "installing") return "正在安装更新";
    if (phase === "failed") return update.availableVersion ? "更新失败" : "检查更新失败";
    return "应用更新";
  }

  function messageFor(update) {
    if (update && update.message) return String(update.message);
    switch (phaseOf(update)) {
      case "available": return "新版已发布，点击立即更新。更新后请在 ChatGPT 刷新一次插件，以防保留旧版缓存。";
      case "checking": return "正在从发布源读取最新版本。";
      case "upToDate": return "当前版本已经是最新版本。";
      case "downloading": return "下载完成后会继续安装。";
      case "waiting": return "当前任务结束后会继续安装。";
      case "installing": return "安装完成后 App 会重新启动。更新后请在 ChatGPT 刷新一次插件，以防保留旧版缓存。";
      case "failed": return update && update.availableVersion
        ? "可以重试下载和安装。" : "可以重试检查更新。";
      default: return "启动 App 时会自动检查更新。";
    }
  }

  function action(title, command, emit, disabled, beforeEmit) {
    var button = node("button", "button small", title);
    var sent = false;
    button.type = "button";
    button.disabled = !!disabled;
    button.addEventListener("click", function () {
      if (sent || button.disabled) return;
      sent = true;
      button.disabled = true;
      if (beforeEmit) beforeEmit();
      emit(command, {});
    });
    return button;
  }

  function appendProgress(copy, update, phase) {
    if (["downloading", "installing"].indexOf(phase) === -1) return;
    var value = progressValue(update);
    var row = node("div", "app-update-progress-row");
    if (value === null) {
      row.appendChild(node("span", "app-update-spinner"));
      row.appendChild(node("span", null, phase === "installing" ? "正在处理安装…" : "正在下载…"));
    } else {
      var progress = node("progress", "app-update-progress");
      progress.max = 100;
      progress.value = value;
      progress.setAttribute("aria-label", "更新进度");
      row.appendChild(progress);
      row.appendChild(node("span", "app-update-progress-label", Math.round(value) + "%"));
    }
    copy.appendChild(row);
  }

  function appendState(container, update, emit, mode) {
    var state = update || { phase: "idle", currentVersion: "" };
    var phase = phaseOf(state);
    var cardClass = mode === "settings" ? "app-update-state" : "app-update-card";
    var card = node("div", cardClass + " app-update-phase-" + phase);
    card.setAttribute("role", "status");
    card.appendChild(icon(phase === "failed" ? "exclamationmark.triangle.fill" : "arrow.down.circle"));

    var copy = node("div", "app-update-copy");
    copy.appendChild(node("h4", "app-update-heading", titleFor(state)));
    if (phase === "available" && state.availableVersion) {
      copy.appendChild(node("p", "app-update-version", "可更新到 " + version(state.availableVersion)));
    }
    if (state.notes) copy.appendChild(node("p", "app-update-notes", String(state.notes)));
    copy.appendChild(node("p", "app-update-message", messageFor(state)));
    appendProgress(copy, state, phase);
    card.appendChild(copy);

    var actions = node("div", "app-update-actions");
    var busy = isBusy(state);
    function lockActions() {
      Array.prototype.forEach.call(actions.children, function (button) { button.disabled = true; });
    }
    if (phase === "available") {
      actions.appendChild(action("立即更新", "installAppUpdate", emit, busy, lockActions));
      if (mode !== "settings" || !state.isDeferred) {
        actions.appendChild(action("稍后", "deferAppUpdate", emit, busy, lockActions));
      }
    } else if (phase === "failed") {
      actions.appendChild(action(
        state.availableVersion ? "重试更新" : "重试检查",
        state.availableVersion ? "installAppUpdate" : "checkAppUpdate",
        emit,
        busy
      ));
      var dismiss = action("×", "deferAppUpdate", emit, false, lockActions);
      dismiss.className = "icon-button app-update-dismiss";
      dismiss.setAttribute("aria-label", "关闭更新提示");
      dismiss.title = "关闭";
      actions.appendChild(dismiss);
    } else if (mode === "settings" && !busy) {
      actions.appendChild(action(phase === "upToDate" ? "再次检查" : "检查更新", "checkAppUpdate", emit, false));
    }
    if (actions.children.length > 0) card.appendChild(actions);
    container.appendChild(card);
  }

  function renderOverview(container, update, emit) {
    if (!container) return;
    var phase = phaseOf(update);
    var visible = update && ["available", "downloading", "waiting", "installing", "failed"].indexOf(phase) !== -1;
    if ((phase === "available" || phase === "failed") && update.isDeferred) visible = false;
    var signature = updateSignature(update) + "\u001e" + String(visible);
    if (container.__appUpdateSignature === signature) return;
    container.__appUpdateSignature = signature;
    container.hidden = !visible;
    clear(container);
    if (visible) appendState(container, update, emit, "overview");
  }

  function createSettings(initial, emit) {
    var root = node("section", "page-card settings-card app-update-settings-card");
    root.appendChild(node("h3", null, "应用更新"));
    var versionLabel = node("p", "app-update-version");
    root.appendChild(versionLabel);
    var stateContainer = node("div", "app-update-settings-state");
    root.appendChild(stateContainer);
    var lastSignature = null;

    function update(next, nextEmit) {
      var state = next || { phase: "idle", currentVersion: "" };
      var signature = updateSignature(state);
      if (signature === lastSignature) return;
      lastSignature = signature;
      versionLabel.textContent = "当前版本：" + version(state.currentVersion);
      clear(stateContainer);
      appendState(stateContainer, state, nextEmit, "settings");
    }

    update(initial, emit);
    return { root: root, update: update };
  }

  global.CodexBridgeDesktopAppUpdate = {
    renderOverview: renderOverview,
    createSettings: createSettings
  };
}(window));
