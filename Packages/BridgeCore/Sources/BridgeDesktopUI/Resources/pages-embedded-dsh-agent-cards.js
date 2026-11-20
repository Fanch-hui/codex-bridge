(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;

  var queued = ["queued", "waiting-for-workspace", "awaiting_local_approval"];
  var active = ["running", "starting", "created", "unknown"].concat(queued);
  var statusText = { running: "运行中", starting: "启动中", created: "启动中", queued: "排队中", "waiting-for-workspace": "等待写入",
    awaiting_local_approval: "等待批准", unknown: "待核对", idle: "已完成", inactive: "已完成", completed: "已完成",
    failed: "失败", interrupted: "已停止", stopped: "已停止", cancelled: "已停止" };
  var resultText = { completed: "已完成", failed: "失败", interrupted: "已停止" };
  var workspaceText = { pending: "待合并", conflict: "有冲突", validation_required: "待验证", validating: "验证中",
    recovery_required: "待恢复", merging: "合并中", failed: "合并失败", retained: "变更已保留" };

  function tone(status) {
    if (active.indexOf(status) >= 0) return "running";
    if (status === "failed") return "failed";
    if (["interrupted", "stopped", "cancelled"].indexOf(status) >= 0) return "stopped";
    return "done";
  }

  // What the card says about one dispatched Agent. `live` is the entry of the session's Agent list (null until the
  // list names it); the result notice backs up a list that no longer does.
  function describe(entry, live, name) {
    var result = entry.result || null, status = live && live.status || "";
    var summary = live ? statusText[status] || "" : result ? resultText[result.state] || "已结束" : "已交给 Agent";
    var state = live ? tone(status) : result ? tone(result.state) : "running";
    if (live && live.stopping) { summary = "正在停止…"; state = "running"; }
    var workspace = live && workspaceText[live.workspaceStatus];
    return { name: name, state: state, status: [summary, workspace].filter(Boolean).join(" · "),
      canOpen: !!live, canStop: !!live && !live.stopping && live.canStop, stopping: !!live && live.stopping,
      result: result ? result.text || (result.state === "failed" ? "任务失败。" : "") : "" };
  }

  // The session's Agent list as the cards read it; the owner feeds every refresh of that list.
  function createStore() {
    var items = new Map(), listeners = new Set(), signature = "";
    function publish(next) {
      var value = JSON.stringify(Array.from(next));
      if (value === signature) return;
      signature = value; items = next;
      listeners.forEach(function (listener) { listener(); });
    }
    function canStop(item, status) {
      if (item.capabilities && typeof item.capabilities === "object") return item.capabilities.canStop === true;
      return item.mode !== "external" && active.indexOf(status) >= 0;
    }
    return {
      update: function (list, stopping) {
        var next = new Map();
        (Array.isArray(list) ? list : []).forEach(function (item) {
          var id = item && (item.childId || item.id || item.sessionId);
          if (!id) return;
          var status = item.status || (item.running ? "running" : "");
          next.set(id, { status: status, workspaceStatus: item.workspaceStatus || "", label: item.label || item.name || "",
            canStop: canStop(item, status), stopping: !!(stopping && stopping(id)) });
        });
        publish(next);
      },
      reset: function () { publish(new Map()); },
      get: function (id) { return items.get(id) || null; },
      subscribe: function (listener) { listeners.add(listener); return function () { listeners.delete(listener); }; }
    };
  }

  function assign(node, value) { if (node.textContent !== value) node.textContent = value; }

  function build(host) {
    var node = S.node("section", "dsh-agent-dispatch");
    var head = S.node("header", "dsh-agent-dispatch-head");
    var target = S.node("span", "dsh-agent-dispatch-target"), status = S.node("span", "dsh-agent-dispatch-status");
    status.setAttribute("role", "status");
    head.appendChild(target); head.appendChild(status);
    var text = S.node("p", "dsh-agent-dispatch-text"), result = S.node("p", "dsh-agent-dispatch-result");
    var actions = S.node("div", "dsh-agent-dispatch-actions");
    var open = S.button("查看过程", null, {}, null, "small"), stop = S.button("停止", null, {}, null, "small");
    var pane = S.button("在协作视图打开", null, {}, null, "small");
    actions.appendChild(open); if (host.openPane) actions.appendChild(pane); actions.appendChild(stop);
    [head, text, result, actions].forEach(function (part) { node.appendChild(part); });
    var card = { entry: null, target: target, status: status, text: text, result: result, actions: actions, open: open, pane: pane, stop: stop };
    open.addEventListener("click", function () { host.open(card.entry.childID); });
    pane.addEventListener("click", function () { if (host.openPane) host.openPane(card.entry.childID); });
    stop.addEventListener("click", function () { host.stop(card.entry.childID); });
    node.__agentCard = card;
    return node;
  }

  function create(host) {
    var store = createStore();
    function nameOf(entry, live) {
      return live && live.label || entry.label || host.agentName(entry.installationID) || entry.installationID || "Agent";
    }
    // Creates the card of an entry, or brings an existing one up to date without replacing its buttons.
    function render(entry, node) {
      node = node || build(host);
      var card = node.__agentCard, live = store.get(entry.childID);
      var view = describe(entry, live, nameOf(entry, live));
      card.entry = entry;
      node.dataset.state = view.state; node.setAttribute("aria-label", "交给 " + view.name + " 的任务");
      assign(card.target, "@" + view.name); assign(card.status, view.status);
      assign(card.text, entry.text);
      assign(card.result, view.result); card.result.hidden = !view.result;
      card.open.hidden = !view.canOpen;
      card.pane.hidden = !view.canOpen || !host.openPane;
      card.stop.hidden = !view.canStop && !view.stopping; card.stop.disabled = view.stopping;
      assign(card.stop, view.stopping ? "停止中…" : "停止");
      card.actions.hidden = card.open.hidden && card.stop.hidden;
      return node;
    }
    return { feed: { update: store.update, reset: store.reset }, subscribe: store.subscribe, render: render };
  }

  var api = { create: create, createStore: createStore, describe: describe };
  global.CodexBridgeDesktopEmbeddedDSHAgentCards = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
}(typeof window === "undefined" ? globalThis : window));
