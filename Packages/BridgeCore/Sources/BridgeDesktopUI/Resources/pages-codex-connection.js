(function (global) {
  "use strict";

  var S = global.CodexBridgeDesktopPageSupport;

  function create(emit) {
    var context = { emit: emit };
    var section = S.node("section", "page-section");
    section.appendChild(S.node("h3", null, "Codex 执行引擎"));
    var card = S.node("div", "page-card connection-card");
    section.appendChild(card);
    var titleRow = S.node("div", "section-heading-row");
    var title = S.node("h3", null, "Codex");
    var badge = S.badge("未知", "neutral");
    titleRow.appendChild(title);
    titleRow.appendChild(badge);
    card.appendChild(titleRow);
    var subtitle = S.node(
      "p",
      "card-subtitle",
      "Codex 由 Bridge 自动发现；安装在非常规位置时，可在此指定可执行文件。"
    );
    card.appendChild(subtitle);
    var facts = S.node("div", "detail-grid");
    card.appendChild(facts);
    var path = S.textField(
      "可执行文件路径（可选）",
      "",
      "留空自动发现；也可填写 codex.exe 或 npm 的 codex.cmd 绝对路径"
    );
    var pathActions = S.node("div", "form-actions");
    var savePath = S.node("button", "button small", "保存路径");
    savePath.type = "button";
    var clearPath = S.node("button", "button small", "恢复自动发现");
    clearPath.type = "button";
    pathActions.appendChild(savePath);
    pathActions.appendChild(clearPath);
    card.appendChild(path.wrapper);
    card.appendChild(pathActions);
    var diagnostics = S.node("div");
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
      var state = codex.connectionState || "未知";
      badge.textContent = statusLabel(codex, count);
      badge.className = "status-badge " + statusTone(codex, count);
      S.clear(facts);
      addFact(facts, "Service", state);
      addFact(facts, "模型目录", count + " 个");
      addFact(facts, "当前使用", resolvedLabel(codex));
      if (document.activeElement !== path.control) {
        var value = typeof codex.executablePath === "string" ? codex.executablePath : "";
        if (path.control.value !== value) path.control.value = value;
      }
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
        if (!codex.executablePath) {
          diagnostics.appendChild(
            S.node(
              "div",
              "page-message",
              "若 Codex 装在非常规位置，请在路径输入框填写 codex.exe 或 codex.cmd 的绝对路径后重试。"
            )
          );
        }
      }
      refresh.textContent = codex.isRefreshing ? "刷新中…" : isConnected(codex, count) ? "刷新模型" : "连接";
      refresh.disabled = codex.isRefreshing === true || codex.canRefresh !== true;
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
      if (!refresh.disabled) context.emit("refreshModels", {});
    });
    update(null, emit);
    return { root: section, update: update };
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
