(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  var labels = { chatgpt: "ChatGPT", qwen: "Qwen", gemini: "Gemini", local: "本机发起", unknown: "来源未知" };
  var symbols = { chatgpt: "C", qwen: "Q", gemini: "G", local: "⌂", unknown: "?" };
  var webKinds = ["chatgpt", "qwen", "gemini"];
  var filters = ["all", "chatgpt", "qwen", "gemini"];

  function sourceKinds(row) {
    if (!row) return ["unknown"];
    if (Array.isArray(row.sourceKinds) && row.sourceKinds.length) return row.sourceKinds;
    if (row.sourceKind) return [row.sourceKind];
    var source = String(row.source || "").toLowerCase();
    if (source.includes("chatgpt")) return ["chatgpt"];
    if (source.includes("qwen")) return ["qwen"];
    if (source.includes("gemini")) return ["gemini"];
    if (source.includes("本机") || source.includes("local")) return ["local"];
    return ["unknown"];
  }
  function isWebRow(row) {
    if (!row) return false;
    return sourceKinds(row).some(function (kind) { return webKinds.indexOf(kind) >= 0; });
  }
  function visibleRows(rows, selected) {
    var wanted = selected || "all";
    return S.safeArray(rows).filter(function (row) {
      if (!isWebRow(row)) return false;
      var kinds = sourceKinds(row).filter(function (kind) { return webKinds.indexOf(kind) >= 0; });
      return wanted === "all" || kinds.indexOf(wanted) >= 0;
    });
  }
  function clients(connections) {
    var list = S.safeArray(connections && connections.clients);
    function get(id) { return list.find(function (item) { return item.clientID === id; }) || {}; }
    var tunnel = connections && connections.tunnel || {}, chat = get("openai.chatgpt"), qwen = get("qwen.studio"), gemini = get("google.gemini");
    var local = connections && connections.localMCPState, cloud = connections && connections.geminiCloud || {};
    var localFailure = local && local !== "ready";
    var tunnelFailure = tunnel.enabled && (tunnel.actionRequired || tunnel.helperAvailable === false
      || ["degraded", "failed", "stopped"].includes(tunnel.lifecycle));
    var tunnelStatus = { ready: "已就绪", stopped: "未连接", starting: "启动中", authenticating: "认证中",
      connecting: "连接中", degraded: "连接异常", failed: "连接失败" }[tunnel.lifecycle] || "状态未知";
    var chatFailure = chat.enabled && (tunnelFailure || tunnel.enabled === false);
    var cloudFailure = cloud.enabled && cloud.lifecycle === "failed";
    return [
      { id: "tunnel", name: "Tunnel", icon: "network", detail: "chatgpt",
        issue: tunnelFailure ? "Tunnel 异常" : "", status: tunnelStatus },
      { id: "chatgpt", name: "ChatGPT", symbol: "C", detail: "chatgpt",
        issue: chatFailure ? "ChatGPT 未连接" : "", status: !chat.enabled ? "未启用" : tunnel.lifecycle === "ready" ? "已就绪" : "等待连接" },
      { id: "qwen", name: "Qwen", symbol: "Q", detail: "qwen",
        issue: qwen.enabled && localFailure ? "Qwen 连接异常" : "", status: !qwen.enabled ? "未启用" : local === "ready" ? "已就绪" : "等待连接" },
      { id: "gemini", name: "Gemini", symbol: "G", detail: "gemini",
        issue: gemini.enabled && localFailure ? "Gemini 本机服务异常" : cloudFailure ? "Gemini 云连接异常" : "",
        status: !gemini.enabled ? "未启用" : cloud.enabled ? cloud.lifecycle || "等待连接" : local === "ready" ? "已就绪" : "等待连接" }
    ];
  }

  function create(options) {
    options = options || {};
    var selected = "all", emit = null;
    var root = S.node("div", "workbench-sources"), status = S.node("div", "workbench-client-status");
    status.setAttribute("aria-label", "网页客户端连接状态");
    var filter = S.node("select", "workbench-source-filter");
    filter.setAttribute("aria-label", "筛选任务来源");
    filters.forEach(function (id) {
      var item = S.node("option", null, id === "all" ? "全部来源" : labels[id]); item.value = id; filter.appendChild(item);
    });
    filter.value = selected;
    filter.addEventListener("change", function () {
      selected = filters.includes(filter.value) ? filter.value : "all";
      if (options.onFilterChange) options.onFilterChange();
    });
    root.appendChild(status); root.appendChild(filter);
    var controls = new Map();
    function update(connections, nextEmit) {
      emit = nextEmit;
      clients(connections).forEach(function (client) {
        var control = controls.get(client.id);
        if (!control) {
          control = S.button("", null, {}, null, "workbench-client-status-item");
          var icon = client.icon ? S.icon(client.icon) : S.node("span", "workbench-client-symbol", client.symbol);
          icon.setAttribute("aria-hidden", "true");
          control.appendChild(icon); control.appendChild(S.node("span", "workbench-client-problem"));
          control.addEventListener("click", function () {
            if (global.CodexBridgeDesktopConnectionsPage) global.CodexBridgeDesktopConnectionsPage.openDetail(client.detail, emit);
          });
          controls.set(client.id, control); status.appendChild(control);
        }
        control.title = client.name + " · " + (client.issue || client.status);
        control.setAttribute("aria-label", control.title);
        control.classList.toggle("has-problem", !!client.issue);
        var problem = control.querySelector(".workbench-client-problem");
        problem.textContent = client.issue; problem.hidden = !client.issue;
      });
    }
    function decorateRow(button, row) {
      var badge = S.node("span", "workbench-source-badges");
      var kinds = sourceKinds(row).filter(function (kind) { return kind !== "embedded"; });
      kinds.forEach(function (kind) {
        var item = S.node("span", "workbench-source-badge", symbols[kind] || symbols.unknown);
        var name = labels[kind] || labels.unknown;
        item.setAttribute("role", "img"); item.setAttribute("aria-label", name); item.title = name;
        badge.appendChild(item);
        if (kind === "local") badge.appendChild(S.node("span", "workbench-source-label", "本机发起"));
      });
      (button.querySelector(".dsh-session-metadata") || button).appendChild(badge);
      return badge;
    }
    return { root: root, update: update, filterRows: function (rows) { return visibleRows(rows, selected); },
      decorateRow: decorateRow, selected: function () { return selected; } };
  }
  var api = { create: create, sourceKinds: sourceKinds, isWebRow: isWebRow, visibleRows: visibleRows, clients: clients };
  global.CodexBridgeDesktopWorkbenchSources = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
}(typeof window === "undefined" ? globalThis : window));
