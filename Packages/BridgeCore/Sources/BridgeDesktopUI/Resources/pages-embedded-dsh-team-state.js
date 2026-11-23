(function (global) {
  "use strict";
  var statuses = ["pending", "in_progress", "completed", "deleted"];

  function strings(value) {
    return Array.isArray(value) ? value.filter(function (item) { return typeof item === "string"; }) : [];
  }

  function normalize(value) {
    if (!value || typeof value.id !== "string" || !value.id || !Number.isSafeInteger(value.revision)
      || statuses.indexOf(value.status) < 0) return null;
    return { id: value.id, revision: value.revision, status: value.status,
      subject: typeof value.subject === "string" ? value.subject : "",
      description: typeof value.description === "string" ? value.description : "",
      ownerName: typeof value.ownerName === "string" ? value.ownerName : "",
      ownerID: typeof value.ownerId === "string" ? value.ownerId : "",
      blockedBy: strings(value.blockedBy), writeScopes: strings(value.writeScopes) };
  }

  // Events newer than the projection baseline, oldest first. The log is ordered by sequence, so the scan
  // from the end stops at the first event the baseline already reflects.
  function eventsAfter(records, seq) {
    var found = [];
    for (var index = (records || []).length - 1; index >= 0; index--) {
      var event = records[index] && records[index].event;
      if (!event || !Number.isSafeInteger(event.seq) || event.seq <= seq) break;
      found.push(event);
    }
    return found.reverse();
  }

  // Readiness depends on sibling tasks, so it is derived here instead of trusted from an older baseline.
  function visible(tasks) {
    return Array.from(tasks.values()).filter(function (task) { return task.status !== "deleted"; }).map(function (task) {
      var dependencies = task.blockedBy.map(function (id) {
        var blocker = tasks.get(id);
        return { id: id, title: blocker && blocker.subject || id, done: !!blocker && blocker.status === "completed" };
      });
      return Object.assign({}, task, { dependencies: dependencies,
        blocked: task.status === "pending" && dependencies.some(function (item) { return !item.done; }) });
    });
  }

  // The engine's saved selection and task board for one root session: its `agentTeam` projection baseline
  // plus the `team/*` events recorded after it. Null while the projection is unavailable.
  function fold(projections, records) {
    var base = projections && projections.values && projections.values.agentTeam;
    if (!base || typeof base.enabled !== "boolean" || !Array.isArray(base.tasks)) return null;
    var failure = typeof base.failure === "string" ? base.failure : "", enabled = base.enabled, tasks = new Map();
    base.tasks.forEach(function (item) {
      var task = normalize(item);
      if (task) tasks.set(task.id, task);
    });
    eventsAfter(records, Number.isSafeInteger(projections.asOfSeq) ? projections.asOfSeq : -1).forEach(function (event) {
      var data = event.data || {};
      if (event.type === "team/mode" && typeof data.enabled === "boolean") enabled = data.enabled;
      if (event.type !== "team/task" || failure) return;
      var task = normalize(data.task), prior = task && tasks.get(task.id);
      if (task && (!prior || task.revision > prior.revision)) tasks.set(task.id, task);
    });
    return { enabled: enabled, failure: failure, tasks: visible(tasks) };
  }

  // The selection is only offered once the model selection projection is known; changing a session that
  // has already called the model costs cache reuse, which is why disabling it asks first.
  function usage(projections) {
    var selection = projections && projections.values && projections.values.modelSelection;
    return { known: !!selection && typeof selection === "object", used: !!selection && selection.lastUsed != null };
  }

  var api = { fold: fold, usage: usage };
  global.CodexBridgeDesktopEmbeddedDSHTeamState = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
}(typeof window === "undefined" ? globalThis : window));
