(function (global) {
  "use strict";

  var S = global.CodexBridgeDesktopPageSupport;

  function create(emit) {
    var context = { emit: emit };
    var section = S.node("section", "page-section");
    section.appendChild(S.node("h3", null, "Codex 执行引擎"));
    var card = S.node("div", "page-card connection-card");
    var titleRow = S.node("div", "section-heading-row");
    var title = S.node("h3", null, "连接本机 Codex");
    var badge = S.badge("未知", "neutral");
    titleRow.appendChild(title);
    titleRow.appendChild(badge);
    card.appendChild(titleRow);
    var subtitle = S.node(
      "p",
      "card-subtitle",
      "Codex 由 Bridge 自动管理，无需选择路径或配置文件。"
    );
    card.appendChild(subtitle);
    var facts = S.node("div", "detail-grid");
    card.appendChild(facts);
    var diagnostics = S.node("div");
    card.appendChild(diagnostics);
    var actions = S.node("div", "form-actions");
    var refresh = S.button("连接 Codex", null, {}, null, "small primary", true);
    actions.appendChild(refresh);
    card.appendChild(actions);
    section.appendChild(card);

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
      S.clear(diagnostics);
      if (codex.modelError) {
        diagnostics.appendChild(S.node("div", "page-message error", "模型目录读取失败：" + codex.modelError));
      }
      refresh.textContent = codex.isRefreshing ? "刷新中…" : count > 0 ? "刷新模型" : "连接 Codex";
      refresh.disabled = codex.isRefreshing === true || codex.canRefresh !== true;
    }

    refresh.addEventListener("click", function () {
      if (!refresh.disabled) context.emit("refreshModels", {});
    });
    update(null, emit);
    return { root: section, update: update };
  }

  function statusLabel(codex, count) {
    if (codex.modelError) return "模型目录失败";
    if (codex.isRefreshing) return "刷新中…";
    return count > 0 ? "模型目录可用" : "待连接";
  }

  function statusTone(codex, count) {
    if (codex.modelError) return "error";
    if (codex.isRefreshing) return "running";
    if (count > 0) return "success";
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
