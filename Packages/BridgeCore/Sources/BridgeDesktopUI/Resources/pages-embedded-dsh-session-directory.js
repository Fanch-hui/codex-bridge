(function (global) {
  "use strict";
  function label(item) {
    return item && (item.title || item.name || item.projections && item.projections.values && item.projections.values.title) || "新对话";
  }
  function createStore(initial) {
    var items = Array.isArray(initial) ? initial.map(function (item) { return Object.assign({}, item); }) : [];
    var ready = false, revision = 0;
    function find(id) { return items.find(function (item) { return item.sessionId === id; }); }
    return {
      begin: function () { return ++revision; },
      commit: function (ticket, values, pending) {
        if (ticket !== revision) return false;
        items = Array.isArray(values) ? values.map(function (item) { return Object.assign({}, item); }) : [];
        (Array.isArray(pending) ? pending : []).forEach(function (job) {
          if (job.phase === "create" && !find(job.sessionId)) items.unshift({ sessionId: job.sessionId, projectID: job.projectID });
        });
        ready = true; return true;
      },
      upsert: function (id, projectID) {
        if (!id || find(id)) return;
        items.unshift({ sessionId: id, projectID: projectID || null }); revision++;
      },
      setProject: function (id, projectID) {
        var index = items.findIndex(function (item) { return item.sessionId === id; });
        if (index >= 0) { items[index] = Object.assign({}, items[index], { projectID: projectID || null }); revision++; }
      },
      invalidate: function () { ready = false; revision++; },
      invalidateRead: function () { revision++; },
      ready: function () { return ready; },
      get: function (id) { var item = find(id); return item ? Object.assign({}, item) : null; },
      items: function () { return items.map(function (item) { return Object.assign({}, item); }); }
    };
  }
  function create(initial, options) {
    var S = global.CodexBridgeDesktopPageSupport, T = global.CodexBridgeDesktopEmbeddedDSHTransport;
    var store = createStore(initial), sidebar = S.node("nav", "dsh-session-list dsh-embedded-sessions"), signature = "";
    sidebar.setAttribute("aria-label", "对话");
    function render(state) {
      var visible = store.items().filter(function (item) { return item.origin !== "subagent"; });
      var next = JSON.stringify([state.projectID, state.sessionID, state.navigationActive, store.ready(), state.connected,
        state.engineFailed, visible.map(function (item) { return [item.sessionId, label(item), item.running]; })]);
      if (next === signature) return;
      signature = next;
      var focusID = document.activeElement && document.activeElement.dataset.sessionId;
      S.clear(sidebar);
      if (!visible.length) {
        var emptyLabel = "正在同步对话…";
        if (state.engineFailed) emptyLabel = "等待恢复会话连接。";
        else if (store.ready()) emptyLabel = "还没有对话。";
        sidebar.appendChild(S.node("p", "hint", emptyLabel));
      }
      visible.forEach(function (item) {
        var selected = state.navigationActive && item.sessionId === state.sessionID;
        var button = S.button("", null, {}, null, "dsh-session-button" + (selected ? " is-active" : ""));
        button.setAttribute("aria-current", selected ? "true" : "false"); button.dataset.sessionId = item.sessionId;
        button.appendChild(S.node("span", "dsh-session-title", label(item)));
        var status = !state.connected ? "待连接" : !store.ready() ? "同步中" : item.running ? "运行中" : "已创建";
        button.appendChild(S.node("span", "dsh-session-status", status));
        button.addEventListener("click", function () { options.onSelect(item.sessionId); }); sidebar.appendChild(button);
        if (focusID === item.sessionId) button.focus({ preventScroll: true });
      });
    }
    function list() {
      var generation = options.generation();
      return T.read("session.list", function () {
        var ticket = store.begin();
        return T.call("session.list", {}).then(function (value) {
          if (generation !== options.generation() || !options.connected()) return store.items();
          if (store.commit(ticket, value && value.items, options.pending())) options.onChange();
          return store.items();
        });
      }).catch(function (error) {
        if (options.active() && generation === options.generation()) options.onError(error);
        throw error;
      });
    }
    return { root: sidebar, list: list, render: render, ready: store.ready, get: store.get, items: store.items,
      upsert: store.upsert, setProject: store.setProject, invalidate: store.invalidate, invalidateRead: store.invalidateRead,
      label: function (id) { var item = store.get(id); return item ? label(item) : ""; } };
  }
  var api = { create: create, createStore: createStore, label: label };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  if (global) global.CodexBridgeDesktopEmbeddedDSHSessionDirectory = api;
}(typeof window === "undefined" ? null : window));
