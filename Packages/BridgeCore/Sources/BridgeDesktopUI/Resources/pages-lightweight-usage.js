(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  var providerNames = { "codex-official": "官方 Codex" };

  // Records keep stable model IDs; current gateway models supply the readable names.
  function labels(models) {
    var modelNames = {}, providers = {};
    S.safeArray(models).forEach(function (model) {
      if (!model || !model.id) return;
      if (model.name) modelNames[model.id] = model.name;
      if (model.providerID && model.providerName) providers[model.providerID] = model.providerName;
    });
    return {
      model: function (id) { return modelNames[id] || id || ""; },
      provider: function (id) { return providerNames[id] || providers[id] || id || ""; }
    };
  }

  function tokens(value) {
    if (typeof value !== "number" || !isFinite(value)) return "0";
    if (value >= 1e9) return (value / 1e9).toFixed(2) + "B";
    if (value >= 1e6) return (value / 1e6).toFixed(1) + "M";
    if (value >= 1e4) return (value / 1e3).toFixed(1) + "K";
    return String(value);
  }

  // Only requests that reported a cache count form the base, so other providers do not dilute it.
  function hitRate(cacheRead, cacheableInput) {
    if (typeof cacheRead !== "number" || typeof cacheableInput !== "number" || cacheableInput <= 0) {
      return "";
    }
    return "缓存命中 " + Math.round(Math.min(1, cacheRead / cacheableInput) * 100) + "%";
  }

  function summaryRow(item, names) {
    var row = S.node("div", "lightweight-activity-row"), main = S.node("div", "lightweight-activity-main");
    var titleRow = S.node("div", "plugin-card-title-row");
    titleRow.appendChild(S.node("strong", "plugin-card-title", names.model(item.model) || "模型"));
    if (item.failed > 0) titleRow.appendChild(S.badge("失败 " + item.failed, "error"));
    main.appendChild(titleRow);
    var usage = item.measured > 0
      ? ["输入 " + tokens(item.inputTokens), hitRate(item.cacheReadTokens, item.cacheableInputTokens),
        "输出 " + tokens(item.outputTokens),
        item.reasoningTokens > 0 ? "推理 " + tokens(item.reasoningTokens) : ""]
      : ["Token 用量未提供"];
    main.appendChild(S.node("span", "hint", [names.provider(item.providerID)].concat(usage)
      .filter(Boolean).join(" · ")));
    row.appendChild(main);
    row.appendChild(S.node("span", "lightweight-activity-meta mono", item.requests + " 次请求"));
    return row;
  }

  /// Renders the retained window's per-model totals; returns false when there is nothing to show.
  function renderSummary(list, entries, names) {
    var resolved = names || labels([]);
    S.clear(list);
    S.safeArray(entries).forEach(function (item) { list.appendChild(summaryRow(item, resolved)); });
    return S.safeArray(entries).length > 0;
  }

  global.CodexBridgeDesktopLightweightUsage = {
    renderSummary: renderSummary, hitRate: hitRate, labels: labels
  };
}(window));
