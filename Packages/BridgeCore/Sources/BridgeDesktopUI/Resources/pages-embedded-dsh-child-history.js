(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport, T = global.CodexBridgeDesktopEmbeddedDSHTransport;
  var pageSize = 200;

  function messageKey(message, taskID, index) {
    return JSON.stringify([message.taskID || message.task_id || taskID || "", message.key || message.message_id || index]);
  }

  function merge(first, second, taskID) {
    var values = new Map();
    first.concat(second).forEach(function (message, index) {
      if (message && typeof message === "object") values.set(messageKey(message, taskID, index), message);
    });
    return Array.from(values.values());
  }

  function create(options) {
    var generation = 0, binding = null, messages = [], before = null, hasMore = false;
    var loaded = false, hasEarlierPages = false, loadingEarlier = false, latest = null;

    function reset(next) {
      generation++; binding = next; messages = []; before = null; hasMore = false;
      loaded = false; hasEarlierPages = false; loadingEarlier = false; latest = null;
    }

    function current(ticket, captured, value) {
      if (ticket !== generation || !options.isCurrent(captured)) return false;
      if (captured.taskID && value && value.taskID && captured.taskID !== value.taskID) return false;
      return !(captured.runID && value && value.runID && captured.runID !== value.runID);
    }

    function update() {
      options.onChange({ messages: messages.slice(), hasMore: hasMore, loadingEarlier: loadingEarlier, loaded: loaded });
    }

    function pageMessages(value, allowFallback) {
      var result = S.safeArray(value && value.messages);
      if (allowFallback && !result.length && value && typeof value.output === "string" && value.output.trim()) {
        return [{ taskID: value.taskID, key: "output", role: "agent", kind: "agent", content: value.output, final: !!value.terminal }];
      }
      return result;
    }

    function more(value, count) {
      return typeof value.hasMore === "boolean" ? value.hasMore : count >= pageSize && value.beforeMessageID != null;
    }

    function load() {
      if (!binding) return Promise.resolve();
      if (latest) return latest;
      var captured = binding, ticket = generation;
      var payload = { sessionId: captured.parent, childId: captured.child, limit: pageSize };
      latest = T.read("subagent.history:" + JSON.stringify(payload), function () {
        if (!current(ticket, captured)) return Promise.resolve();
        return T.call("subagents.history", payload).then(function (value) {
          if (!current(ticket, captured, value)) return;
          if (value && value.pending === true) return;
          var incoming = pageMessages(value, true);
          messages = hasEarlierPages ? merge(messages, incoming, value.taskID) : merge([], incoming, value.taskID);
          if (!hasEarlierPages) { before = value.beforeMessageID; hasMore = more(value, incoming.length); }
          loaded = true; update();
        });
      }).catch(function (failure) { if (current(ticket, captured)) options.onError(failure); }).finally(function () {
        if (ticket === generation) latest = null;
      });
      return latest;
    }

    function loadEarlier() {
      if (!binding || !loaded || !hasMore || before == null || loadingEarlier) return;
      var captured = binding, ticket = generation, anchor = before;
      loadingEarlier = true; update();
      T.call("subagents.history", { sessionId: captured.parent, childId: captured.child,
        beforeMessageID: anchor, limit: pageSize }).then(function (value) {
        if (!current(ticket, captured, value)) return;
        var incoming = pageMessages(value, false);
        messages = merge(incoming, messages, value.taskID);
        if (incoming.length) hasEarlierPages = true;
        var next = value.beforeMessageID;
        hasMore = incoming.length > 0 && next != null && next !== anchor && more(value, incoming.length);
        before = next;
      }).catch(function (failure) { if (current(ticket, captured)) options.onError(failure); }).finally(function () {
        if (current(ticket, captured)) { loadingEarlier = false; update(); }
      });
    }

    return { reset: reset, load: load, loadEarlier: loadEarlier, dispose: function () { reset(null); } };
  }

  function createNative(options) {
    var model = global.CodexBridgeDesktopEmbeddedDSHHistory.create();
    var generation = 0, binding = null, loadingEarlier = false, latest = null;

    function reset(next) {
      generation++; binding = next; loadingEarlier = false; latest = null;
      model.reset(next && next.session);
    }
    function current(ticket, captured) { return ticket === generation && options.isCurrent(captured); }
    function update() {
      var snapshot = model.snapshot(); snapshot.loadingEarlier = loadingEarlier; options.onChange(snapshot);
    }
    function load() {
      if (!binding || !binding.session) return Promise.resolve();
      if (latest) return latest;
      var captured = binding, ticket = generation;
      latest = T.read("child.session.history:" + captured.session, function () {
        if (!current(ticket, captured)) return Promise.resolve();
        model.beginSnapshot();
        return T.call("session.history", { sessionId: captured.session }).then(function (value) {
          if (!current(ticket, captured)) return;
          var result = model.applySnapshot(value);
          if (result.resync) throw new Error("子会话状态尚未同步，请重试。");
          update();
        });
      }).catch(function (failure) { if (current(ticket, captured)) options.onError(failure); }).finally(function () {
        if (ticket === generation) latest = null;
      });
      return latest;
    }
    function loadEarlier() {
      var snapshot = model.snapshot();
      if (!binding || !snapshot.hasMore || loadingEarlier) return;
      var captured = binding, ticket = generation;
      loadingEarlier = true; update();
      T.call("session.history", { sessionId: captured.session, throughSeq: snapshot.cursor,
        beforeSeq: snapshot.beforeSeq }).then(function (value) {
        if (current(ticket, captured)) model.prependPage(value, snapshot);
      }).catch(function (failure) { if (current(ticket, captured)) options.onError(failure); }).finally(function () {
        if (current(ticket, captured)) { loadingEarlier = false; update(); }
      });
    }
    function receive(item) {
      if (!binding || !options.isCurrent(binding)) return;
      var result = model.receive(item);
      if (result.resync) load(); else if (result.changed) update();
    }
    return { reset: reset, load: load, loadEarlier: loadEarlier, receive: receive, dispose: function () { reset(null); } };
  }

  global.CodexBridgeDesktopEmbeddedDSHChildHistory = { create: create, createNative: createNative };
}(window));
