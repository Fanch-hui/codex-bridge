(function (global) {
  "use strict";

  function create(options) {
    var T = options.transport, active = false, current = null, timer = null;
    var storageKey = "codexbridge.workbench.pluginInstall.v1";
    var pendingStates = ["installing", "applying", "checking", "cancelling"];
    var terminalStates = ["completed", "failed", "cancelled", "unknown"];
    var labels = { installing: "正在安装插件…", applying: "正在应用插件…", checking: "正在核对安装进度…",
      cancelling: "正在取消安装…", completed: "插件已安装。", failed: "插件安装失败。",
      cancelled: "安装已取消。", unknown: "安装状态待确认，请查看插件列表。" };

    function saveID() {
      try {
        if (current) global.localStorage.setItem(storageKey, current.requestId);
        else global.localStorage.removeItem(storageKey);
        return true;
      } catch (_) {
        options.onError(new Error("无法保存安装进度，请检查本地存储。"));
        return false;
      }
    }
    function render() {
      var status = current && current.status, pending = pendingStates.indexOf(status) !== -1;
      options.root.hidden = !current;
      options.message.textContent = current && current.error || labels[status] || "";
      options.installButton.disabled = pending;
      options.cancelButton.hidden = !pending || status === "cancelling";
      options.dismissButton.hidden = pending;
      if (options.onPending) options.onPending(pending);
    }
    function scheduleRead() {
      if (timer) global.clearTimeout(timer);
      timer = null;
      if (!active || !current || terminalStates.indexOf(current.status) !== -1) return;
      timer = global.setTimeout(read, 8000);
    }
    function apply(value) {
      if (!current || !value || value.requestId !== current.requestId) return;
      current.status = value.status || "checking";
      current.error = value.error && (value.error.message || value.error) || "";
      render();
      if (active && terminalStates.indexOf(current.status) !== -1) options.onChanged();
      scheduleRead();
    }
    function read() {
      if (!active || !current || current.reading) return;
      var entry = current; entry.reading = true;
      return T.call("plugins.installStatus", { requestId: entry.requestId }).then(function (value) {
        if (current === entry) apply(value);
      }).catch(function () {
        if (current === entry) { entry.status = "checking"; render(); }
      }).finally(function () {
        entry.reading = false;
        if (current === entry) scheduleRead();
      });
    }
    function setActive(value) {
      active = value;
      if (!active) { if (timer) global.clearTimeout(timer); timer = null; return; }
      if (!current) {
        var id = "";
        try { id = global.localStorage.getItem(storageKey) || ""; } catch (_) {}
        if (id && id.length <= 256) current = { requestId: id, status: "checking" };
      }
      render(); if (current) read();
    }
    function begin(spec) {
      if (current && pendingStates.indexOf(current.status) !== -1) return;
      var entry = current = { requestId: T.requestID(), status: "installing" };
      saveID();
      render();
      return T.call("plugins.beginInstall", { spec: spec, requestId: entry.requestId }, { timeoutMs: 10000 })
        .then(function (value) {
          if (current !== entry) return;
          if (options.input.value.trim() === spec) options.input.value = "";
          apply(value);
        }).catch(function () {
          if (current !== entry) return;
          entry.status = "checking"; render(); read();
        });
    }
    function cancel() {
      if (!current || current.status === "cancelling") return;
      var entry = current; entry.status = "cancelling"; render();
      return T.call("plugins.cancelInstall", { requestId: entry.requestId }).then(function () {
        if (current === entry) read();
      }).catch(function (failure) {
        if (current !== entry) return;
        entry.status = "checking"; options.onError(failure); render(); scheduleRead();
      });
    }
    function dismiss() {
      if (!current || options.dismissButton.disabled) return;
      var entry = current; options.dismissButton.disabled = true;
      return T.call("plugins.dismissInstall", { requestId: entry.requestId }).then(function () {
        if (current !== entry) return;
        if (timer) global.clearTimeout(timer);
        timer = null; current = null;
        if (!saveID()) current = entry;
        render();
      }).catch(options.onError).finally(function () { options.dismissButton.disabled = false; });
    }
    function receive(event) {
      if (active && current && event && event.type === "plugin.install" && event.payload
          && event.payload.requestId === current.requestId) read();
    }
    function adopt(operations) {
      if (current || !Array.isArray(operations)) return;
      var item = operations.find(function (operation) {
        return operation && operation.requestId && pendingStates.indexOf(operation.status) !== -1;
      }) || operations.find(function (operation) { return operation && operation.requestId && operation.status === "unknown"; });
      if (!item) return;
      current = { requestId: item.requestId, status: item.status };
      saveID(); apply(item);
    }
    render();
    return { setActive: setActive, begin: begin, cancel: cancel, dismiss: dismiss, receive: receive, adopt: adopt,
      isPending: function () { return !!current && pendingStates.indexOf(current.status) !== -1; } };
  }
  global.CodexBridgeDesktopEmbeddedDSHPluginInstall = { create: create };
}(window));
