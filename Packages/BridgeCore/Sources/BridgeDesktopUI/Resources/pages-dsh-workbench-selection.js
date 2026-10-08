(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport, providerID = "deepseek-harness";
  function matches(task, development) {
    return !!task && (development ? task.providerID === providerID : task.providerID !== providerID);
  }
  function project(page, development, blank, awaitingTaskID) {
    page = page || {};
    var tasks = S.safeArray(page.tasks).filter(function (task) { return matches(task, development); });
    var selected = page.selectedTask;
    if (blank || !matches(selected, development) || awaitingTaskID && selected.taskID !== awaitingTaskID) selected = null;
    var taskIDs = new Set(tasks.map(function (task) { return task.taskID; }));
    if (selected) taskIDs.add(selected.taskID);
    var approvals = new Set();
    var search = page.taskHistorySearch;
    if (search) {
      var queryVisible = development ? search.providerID === providerID : search.providerID !== providerID;
      search = Object.assign({}, search, {
        providers: S.safeArray(search.providers).filter(function (choice) { return development ? choice.id === providerID : choice.id !== providerID; }),
        results: queryVisible ? S.safeArray(search.results).filter(function (task) { return matches(task, development); }) : [],
        providerID: queryVisible ? search.providerID : "", hasSearched: queryVisible && search.hasSearched,
        canLoadMore: queryVisible && search.canLoadMore
      });
    }
    return Object.assign({}, page, {
      tasks: tasks, selectedTask: selected, selectedTaskID: selected ? selected.taskID : null,
      taskHistorySearch: search,
      approvals: S.safeArray(page.approvals).filter(function (approval) {
        var inProject = approval.isDirect && approval.projectID === page.selectedProjectID;
        if ((!inProject && !taskIDs.has(approval.taskID)) || approvals.has(approval.approvalID)) return false;
        approvals.add(approval.approvalID); return true;
      })
    });
  }
  global.CodexBridgeDesktopDSHWorkbenchSelection = { matches: matches, project: project };
})(window);
