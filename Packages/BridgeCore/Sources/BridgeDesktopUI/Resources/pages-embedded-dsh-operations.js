(function (global) {
  "use strict";

  function create(saved) {
    var jobs = new Map();
    var pending = Array.isArray(saved && saved.pendingJobs) ? saved.pendingJobs : [];
    if (saved && saved.pending && !pending.some(function (job) { return job && job.requestId === saved.pending.requestId; })) {
      pending = pending.concat(Object.assign({}, saved.pending, { legacyPending: true }));
    }
    pending.forEach(function (job) { if (job && typeof job.requestId === "string" && job.requestId) jobs.set(job.requestId, job); });
    function current(projectID, sessionID) {
      return Array.from(jobs.values()).find(function (job) {
        if (sessionID) return job.sessionId === sessionID;
        return job.projectID === projectID && (job.phase === "create" || job.originDraft === true);
      }) || null;
    }
    return {
      current: current,
      add: function (job) { jobs.set(job.requestId, job); },
      remove: function (job) { if (jobs.get(job.requestId) === job) jobs.delete(job.requestId); },
      has: function (job) { return jobs.get(job.requestId) === job; },
      list: function () { return Array.from(jobs.values()); }
    };
  }

  function snapshot(result, operationID) {
    return result && Array.isArray(result.operations) ? result.operations.find(function (item) {
      return item && item.operationID === operationID;
    }) || null : null;
  }

  function outcome(operation) {
    if (!operation) return "unknown";
    if (operation.phase === "accepted" || operation.phase === "completed") return "accepted";
    if (operation.phase === "failed" || operation.phase === "cancelled") return operation.phase;
    return "pending";
  }

  function createRecovery(options) {
    var timers = new Map(), attempts = new Map(), delays = [1000, 2000, 4000, 8000, 15000, 30000];
    function clear(id) {
      if (timers.has(id)) global.clearTimeout(timers.get(id));
      timers.delete(id); attempts.delete(id);
    }
    function inspect(job, result) {
      var operation = snapshot(result, job.requestId), status = outcome(operation);
      if (status === "accepted") { clear(job.requestId); options.onAccepted(job); return true; }
      if (status === "failed" || status === "cancelled") {
        clear(job.requestId); options.onFailed(job, operation); return true;
      }
      return false;
    }
    function schedule(job, delay) {
      if (!options.jobs.has(job) || job.requiresManualRecovery || timers.has(job.requestId)) return;
      job.verifying = true; options.inFlight.delete(job.requestId); options.onReconciling(job);
      if (!options.isReady()) return;
      var attempt = attempts.get(job.requestId) || 0;
      var nextDelay = delay == null ? attempt < delays.length ? delays[attempt] : 60000 : delay;
      var timer = global.setTimeout(function () {
        timers.delete(job.requestId);
        if (!options.isReady() || !options.jobs.has(job)) return;
        options.inFlight.add(job.requestId); options.onUpdate();
        options.transport.call("operations.read", { operationIDs: [job.requestId] }).then(function (result) {
          if (inspect(job, result)) return null;
          if (job.legacyPending && options.importLegacy) {
            return options.importLegacy(job).then(function (value) {
              if (!inspect(job, value)) throw new Error("操作仍在核对。");
            });
          }
          return options.transport.call("operations.reconcile", { operationID: job.requestId }).then(function (value) {
            if (!inspect(job, value)) throw new Error("操作仍在核对。");
          });
        }).catch(function () {
          if (!options.jobs.has(job)) return;
          attempts.set(job.requestId, attempt + 1); schedule(job);
        }).finally(function () { options.inFlight.delete(job.requestId); options.onUpdate(); });
      }, nextDelay);
      if (timer && timer.unref) timer.unref();
      timers.set(job.requestId, timer);
    }
    return { inspect: inspect, schedule: schedule, clear: clear,
      clearTimers: function () { timers.forEach(function (timer) { global.clearTimeout(timer); }); timers.clear(); } };
  }

  var api = { create: create, snapshot: snapshot, outcome: outcome, createRecovery: createRecovery };
  global.CodexBridgeDesktopEmbeddedDSHOperations = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
}(typeof window === "undefined" ? globalThis : window));
