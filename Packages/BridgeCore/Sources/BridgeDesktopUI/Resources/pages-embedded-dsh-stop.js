(function (global) {
  "use strict";
  var T = global.CodexBridgeDesktopEmbeddedDSHTransport, O = global.CodexBridgeDesktopEmbeddedDSHOperations;
  function create(options) {
    var stopping = new Map(), inFlight = new Set(), timers = new Map(), retried = new Set();
    var delays = [1000, 2000, 4000, 8000, 15000, 30000, 60000];
    function submit(id, operationID) {
      return T.call("operations.submit", { operationID: operationID, kind: "session.stop", sessionID: id,
        requestID: operationID, input: { sessionId: id } });
    }
    function notify(id, state, error) { options.onChange(id, state, error); }
    function finish(id, state, error) {
      if (!stopping.has(id)) return;
      if (timers.has(id)) global.clearTimeout(timers.get(id));
      timers.delete(id);
      retried.delete(stopping.get(id)); stopping.delete(id); notify(id, state, error);
    }
    function later(id, attempt) {
      if (timers.has(id)) return;
      var timer = global.setTimeout(function () { timers.delete(id); check(id, attempt + 1); }, delays[Math.min(attempt, delays.length - 1)]);
      if (timer && timer.unref) timer.unref();
      timers.set(id, timer);
    }
    function check(id, attempt) {
      if (!options.isReady() || !stopping.has(id) || inFlight.has(id)) return;
      inFlight.add(id);
      var operationID = stopping.get(id);
      T.call("operations.reconcile", { operationID: operationID }).then(function (result) {
        var operation = O.snapshot(result, operationID);
        if (!operation && result.outcome === "notFound" && !retried.has(operationID)) {
          retried.add(operationID);
          return submit(id, operationID).then(function () { later(id, attempt); });
        }
        if (operation && ["failed", "cancelled"].includes(operation.phase)) { finish(id, "failed"); return; }
        if (!operation || operation.phase !== "completed") { later(id, attempt); return; }
        return options.listSessions().then(function (items) {
          var item = items.find(function (row) { return row.sessionId === id; });
          if (item && !item.running) finish(id, "stopped"); else later(id, attempt);
        });
      }).catch(function (error) {
        notify(id, "checking", error); later(id, attempt);
      }).finally(function () { inFlight.delete(id); });
    }
    function restore(id) {
      if (!id || !options.isReady()) return;
      T.call("operations.read", { sessionID: id, unresolvedOnly: true }).then(function (result) {
        var values = result && Array.isArray(result.operations) ? result.operations : [];
        var operation = values.find(function (item) {
          return item.kind === "session.stop" && !["completed", "failed", "cancelled"].includes(item.phase);
        });
        if (!operation || stopping.has(id)) return;
        stopping.set(id, operation.operationID); notify(id, "stopping"); check(id, 0);
      }).catch(function (error) { notify(id, "checking", error); });
    }
    function stop(id) {
      if (!id || stopping.has(id) || !options.isReady()) return;
      var operationID = T.requestID(); stopping.set(id, operationID); notify(id, "stopping");
      return submit(id, operationID).then(function (result) {
        var operation = O.snapshot(result, operationID);
        if (operation && ["failed", "cancelled"].includes(operation.phase)) { finish(id, "failed"); return; }
        check(id, 0);
      }).catch(function (error) {
        if (!error.code || ["embedded_dsh_transport_timeout", "embedded_dsh_runtime", "service_unavailable"].includes(error.code)) {
          check(id, 0); return;
        }
        finish(id, "failed", error);
      });
    }
    return { stop: stop, restore: restore, has: function (id) { return stopping.has(id); },
      observe: function (id, running) { if (!running && stopping.has(id)) check(id, 0); },
      resume: function () { stopping.forEach(function (_, id) { check(id, 0); }); } };
  }
  global.CodexBridgeDesktopEmbeddedDSHStop = { create: create };
}(window));
