(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  function preferences(stored) {
    stored = stored || {};
    var tasks = stored.tasks || {};
    var acpSelected = stored.mode === "dsh" && stored.source === "legacy";
    return {
      mode: stored.mode === "collaboration" || acpSelected ? "collaboration" : "dsh",
      tasks: { collaboration: (acpSelected ? tasks.dsh : tasks.collaboration) || tasks.collaboration || tasks.dsh || null },
      panels: Object.assign({ workspaceCollapsed: true }, stored.panels || {})
    };
  }
  // Derived collections keep their previous reference while their members are unchanged (a shared
  // empty list stands in for a missing one), so the reference comparison in the workbench
  // renderer can skip pages whose tasks and approvals did not move.
  var noTasks = [], lastApprovals = [];
  function stableApprovals(next) {
    var same = next.length === lastApprovals.length && next.every(function (approval, index) {
      return approval === lastApprovals[index];
    });
    if (!same) lastApprovals = next;
    return lastApprovals;
  }
  function project(page, awaitingTaskID) {
    page = page || {};
    var tasks = Array.isArray(page.tasks) ? page.tasks : noTasks, selected = page.selectedTask;
    if (!selected || awaitingTaskID && selected.taskID !== awaitingTaskID) selected = null;
    var taskIDs = new Set(tasks.map(function (task) { return task.taskID; }));
    if (selected) taskIDs.add(selected.taskID);
    var approvals = new Set();
    return Object.assign({}, page, {
      tasks: tasks, selectedTask: selected, selectedTaskID: selected ? selected.taskID : null,
      approvals: stableApprovals(S.safeArray(page.approvals).filter(function (approval) {
        var inProject = approval.isDirect;
        if ((!inProject && !taskIDs.has(approval.taskID)) || approvals.has(approval.approvalID)) return false;
        approvals.add(approval.approvalID); return true;
      }))
    });
  }
  global.CodexBridgeDesktopDSHWorkbenchSelection = { preferences: preferences, project: project };
})(window);
