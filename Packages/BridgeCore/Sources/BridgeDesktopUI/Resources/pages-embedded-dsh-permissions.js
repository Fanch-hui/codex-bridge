(function (global) {
  "use strict";

  function create(transport, onUpdate) {
    var generation = 0, writes = new Map();
    var state = { sessionID: null, selected: "", draftPreset: "", choices: [], ready: false,
      loading: false, writing: false, error: "" };

    function notify() { onUpdate(Object.assign({}, state, { choices: state.choices.slice() })); }
    function current(id, ticket) { return state.sessionID === id && generation === ticket; }
    function message(error) { return error && error.message || "权限设置不可用，请重试。"; }
    function applyResult(value) {
      var names = { "read-only": "只读", "workspace-write": "项目读写", "danger-full-access": "完全访问", auto: "自动" };
      var choices = Array.isArray(value && value.presets) ? value.presets.filter(function (item) {
        return item && typeof item.id === "string" && item.id;
      }).map(function (item) {
        var title = item.name || item.id;
        return { id: item.id, title: names[item.id] && title === item.id ? names[item.id] : title };
      }) : [];
      var selected = state.sessionID ? value && value.selected : state.draftPreset || value && value.selected;
      if (!selected || !choices.length) throw new Error("未获取到可用的权限预设。");
      var available = choices.some(function (item) { return item.id === selected; });
      if (!available) choices.unshift({ id: selected, title: selected === "custom" ? "自定义" : selected + " · 暂不可用", enabled: false });
      state.choices = choices; state.selected = selected;
      state.ready = available || !!state.sessionID && selected === "custom";
      state.error = state.ready ? "" : "所选权限预设暂不可用，请选择其他权限。";
    }
    function refresh() {
      var id = state.sessionID, ticket = ++generation, waiting = writes.get(id);
      state.loading = true; state.ready = false; state.error = ""; notify();
      return Promise.resolve(waiting).catch(function () {}).then(function () {
        return transport.read("permissions:" + JSON.stringify(id), function () {
          return transport.call("permissions.get", { sessionId: id });
        });
      }).then(function (value) {
        if (current(id, ticket)) applyResult(value);
      }).catch(function (error) {
        if (current(id, ticket)) { state.error = message(error); state.ready = false; }
      }).finally(function () {
        if (current(id, ticket)) { state.loading = false; notify(); }
      });
    }
    function open(id, draftPreset, connected) {
      generation++;
      state = { sessionID: id || null, selected: "", draftPreset: id ? "" : draftPreset || "",
        choices: [], ready: false, loading: false, writing: false, error: "" };
      if (connected) return refresh();
      notify(); return Promise.resolve();
    }
    async function setAndReconcile(id, preset) {
      try { return await transport.call("permissions.set", { sessionId: id, presetId: preset }); }
      catch (failure) {
        var value;
        try { value = await transport.call("permissions.get", { sessionId: id }); }
        catch (_) { throw new Error("权限设置未确认，请重新载入会话后重试。"); }
        if (value && value.selected === preset) return value;
        failure.permissionState = value; throw failure;
      }
    }
    function track(id, operation) {
      writes.set(id, operation);
      function clear() { if (writes.get(id) === operation) writes.delete(id); }
      operation.then(clear, clear);
      return operation;
    }
    function choose(preset) {
      if (!state.choices.some(function (item) { return item.id === preset && item.enabled !== false; })) return Promise.resolve();
      if (!state.sessionID) {
        state.draftPreset = preset; state.selected = preset; state.ready = true; state.error = ""; notify(); return Promise.resolve();
      }
      var id = state.sessionID, ticket = ++generation;
      state.writing = true; state.error = ""; notify();
      return track(id, setAndReconcile(id, preset)).then(function (value) {
        if (current(id, ticket)) applyResult(value);
      }).catch(function (error) {
        if (!current(id, ticket)) return;
        try {
          if (error.permissionState) applyResult(error.permissionState);
          else state.ready = false;
        } catch (_) { state.ready = false; }
        state.error = message(error);
      }).finally(function () {
        if (current(id, ticket)) { state.writing = false; notify(); }
      });
    }
    async function apply(id, preset) {
      if (!preset) return;
      var operation = (async function () {
        var value = await transport.call("permissions.get", { sessionId: id });
        return value && value.selected === preset ? value : setAndReconcile(id, preset);
      }());
      var value = await track(id, operation);
      if (state.sessionID === id) {
        generation++; state.loading = false; state.writing = false; applyResult(value); notify();
      }
    }
    function releaseDraft() { if (!state.sessionID) { state.draftPreset = ""; notify(); } }
    return { open: open, refresh: refresh, choose: choose, apply: apply, releaseDraft: releaseDraft };
  }

  var api = { create: create };
  global.CodexBridgeDesktopEmbeddedDSHPermissions = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
}(typeof window === "undefined" ? globalThis : window));
