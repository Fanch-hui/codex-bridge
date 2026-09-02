(function (global) {
  "use strict";

  var S = global.CodexBridgeDesktopPageSupport;

  function toneForStatus(status) {
    if (status === "running" || status === "starting") return "running";
    if (status === "completed") return "success";
    if (status === "failed") return "error";
    if (status.indexOf("approval") >= 0) return "warning";
    return "neutral";
  }

  function renderBrowser(page, emit) {
    var browser = page.browser || {};
    var controls = document.getElementById("browser-controls");
    var slot = document.getElementById("chat-browser-slot");
    var note = document.getElementById("browser-slot-note");
    S.clear(controls);
    var controlsList = [
      ["后退", "browserBack", browser.canGoBack],
      ["前进", "browserForward", browser.canGoForward],
      ["刷新", "browserReload", browser.canReload],
      [browser.enabled ? "停用" : "启用", "setBrowserEnabled", browser.canToggle]
    ];
    controlsList.forEach(function (item) {
      controls.appendChild(S.button(item[0], item[1], item[1] === "setBrowserEnabled" ? { enabled: !browser.enabled } : {}, emit, "small", !item[2]));
    });
    if (browser.canOpenExternally) {
      controls.appendChild(S.button("在浏览器中打开", "openBrowserExternally", {}, emit, "small", false));
    }
    slot.classList.toggle("browser-hidden", !(browser.visible && browser.enabled));
    note.textContent = browser.status || "由宿主加载真实 ChatGPT 工作区";
  }

  function renderProjectPicker(page, emit) {
    var container = document.getElementById("workbench-inspector-project");
    S.clear(container);
    if (!page.projects || page.projects.length === 0) return;
    var picker = S.selectField(
      "项目",
      page.selectedProjectID,
      S.choices(page.selectedProjectID, page.projects),
      function (value) { emit("selectProject", { projectID: value }); },
      "compact-field"
    );
    container.appendChild(picker.control);
  }

  function renderPermissionPicker(header, page, emit) {
    var picker = S.selectField(
      "工作台权限",
      page.permissionMode,
      S.choices(page.permissionMode, page.permissionOptions),
      function (value) { emit("setWorkbenchPermissionMode", { mode: value }); },
      "compact-field"
    );
    header.appendChild(picker.wrapper);
  }

  function renderTaskList(container, page, emit) {
    var section = S.node("section", "inspector-section");
    section.appendChild(S.node("h4", null, "任务"));
    var list = S.node("div", "task-list");
    S.safeArray(page.tasks).forEach(function (task) {
      var row = S.node("button", "task-row" + (task.selected ? " selected" : ""));
      row.type = "button";
      row.appendChild(S.badge(task.status, toneForStatus(task.status)));
      var copy = S.node("div", "row-main");
      copy.appendChild(S.node("div", "row-title", task.title));
      copy.appendChild(S.node("div", "row-detail", task.provider + " · " + task.source + " · " + task.updatedAt));
      row.appendChild(copy);
      row.addEventListener("click", function () { emit("selectTask", { taskID: task.taskID }); });
      list.appendChild(row);
    });
    if (!page.tasks || page.tasks.length === 0) {
      list.appendChild(S.node("div", "list-empty", "当前没有任务记录。"));
    }
    section.appendChild(list);
    container.appendChild(section);
  }

  function renderTaskDetail(container, page, emit) {
    var detail = page.selectedTask;
    if (!detail) {
      var empty = S.node("section", "inspector-section");
      empty.appendChild(S.node("h4", null, "任务详情"));
      empty.appendChild(S.node("div", "list-empty", "从上方选择任务查看实时状态。"));
      container.appendChild(empty);
      return;
    }
    var row = S.safeArray(page.tasks).find(function (task) { return task.taskID === detail.taskID; }) || {};
    var section = S.node("section", "inspector-section");
    section.appendChild(S.node("h4", null, "任务详情"));
    var card = S.node("div", "page-card");
    card.appendChild(S.node("h3", "detail-title", detail.title));
    card.appendChild(S.node("p", "detail-subtitle", detail.projectName + " · " + detail.provider));
    var grid = S.node("dl", "detail-grid");
    addDetail(grid, "状态", detail.status);
    addDetail(grid, "更新时间", detail.updatedAt);
    addDetail(grid, "模型", detail.model || "未记录");
    addDetail(grid, "权限", detail.permissionMode || "未记录");
    addDetail(grid, "当前步骤", detail.currentStep || "空闲");
    if (detail.failureCode) addDetail(grid, "失败代码", detail.failureCode);
    card.appendChild(grid);
    var actions = S.node("div", "form-actions");
    if (row.canInterrupt) actions.appendChild(S.button("中断", "interruptTask", { taskID: detail.taskID }, emit, "small danger", false));
    if (row.canStop) actions.appendChild(S.button("停止", "stopTask", { taskID: detail.taskID }, emit, "small danger", false));
    if (!row.isRunning && !row.isActive) actions.appendChild(S.button("删除记录", "deleteTask", { taskID: detail.taskID }, emit, "small danger", false));
    if (row.canSteer) actions.appendChild(S.button("刷新任务", "refreshTasks", {}, emit, "small", false));
    card.appendChild(actions);
    if (row.canSteer) card.appendChild(steerForm(card, page, detail.taskID, emit));
    if (detail.resultSummary) addTextBlock(card, "结果摘要", detail.resultSummary);
    if (detail.changedFiles && detail.changedFiles.length) addListBlock(card, "变更文件", detail.changedFiles);
    if (detail.activity && detail.activity.length) addActivityBlock(card, detail.activity);
    if (detail.conversation && detail.conversation.length) addConversationBlock(card, detail.conversation, page, emit);
    section.appendChild(card);
    container.appendChild(section);
  }

  function addDetail(container, title, value) {
    var item = S.node("div", "detail-item");
    item.appendChild(S.node("dt", null, title));
    item.appendChild(S.node("dd", null, value));
    container.appendChild(item);
  }

  function addTextBlock(container, title, text) {
    container.appendChild(S.node("h4", "subsection-title", title));
    container.appendChild(S.node("p", "muted", text));
  }

  function addListBlock(container, title, values) {
    container.appendChild(S.node("h4", "subsection-title", title));
    var list = S.node("div", "activity-list");
    values.forEach(function (value) { list.appendChild(S.node("div", "activity-row mono", value)); });
    container.appendChild(list);
  }

  function steerForm(card, page, taskID, emit) {
    var form = S.node("div", "form-grid");
    var input = S.textField("补充指令", "", "当前轮完成后继续", "full");
    form.appendChild(input.wrapper);
    var modes = S.selectField("发送方式", page.steerModes && page.steerModes[0] ? page.steerModes[0].id : "", page.steerModes || [], function () {}, "");
    form.appendChild(modes.wrapper);
    var action = S.node("div", "form-actions full");
    var send = S.button("发送 Steer", null, {}, emit, "small primary", false);
    send.addEventListener("click", function () {
      var value = input.control.value;
      if (!value.trim()) return;
      emit("steerTask", { taskID: taskID, input: value, mode: modes.control.value });
      input.control.value = "";
    });
    action.appendChild(send);
    form.appendChild(action);
    var wrapper = S.node("div", "steer-form");
    wrapper.appendChild(form);
    return wrapper;
  }

  function addActivityBlock(container, values) {
    container.appendChild(S.node("h4", "subsection-title", "实时活动"));
    var list = S.node("div", "activity-list");
    values.forEach(function (activity) {
      var row = S.node("div", "activity-row");
      row.appendChild(S.node("span", "muted mono", activity.occurredAt));
      row.appendChild(S.node("span", null, activity.summary));
      list.appendChild(row);
    });
    container.appendChild(list);
  }

  function addConversationBlock(container, values, page, emit) {
    container.appendChild(S.node("h4", "subsection-title", "对话"));
    var list = S.node("div", "conversation-list");
    values.forEach(function (entry) {
      var item = S.node("div", "conversation-entry");
      item.appendChild(S.node("div", "entry-role", entry.role));
      item.appendChild(S.node("div", "entry-text", entry.text));
      list.appendChild(item);
    });
    container.appendChild(list);
    if (page.browser && page.browser.canLoadEarlierConversation) {
      container.appendChild(S.button("加载更早对话", "loadEarlierConversation", { taskID: page.selectedTaskID }, emit, "small", false));
    }
    if (page.selectedTaskID) {
      container.appendChild(S.button("刷新对话", "refreshConversation", { taskID: page.selectedTaskID }, emit, "small", false));
    }
  }

  function renderApprovals(container, page, emit) {
    if (!page.approvals || page.approvals.length === 0) return;
    var section = S.node("section", "inspector-section");
    section.appendChild(S.node("h4", null, "待处理审批"));
    page.approvals.forEach(function (approval) {
      var card = S.node("article", "approval-card");
      card.appendChild(S.node("h4", null, approval.title || approval.kind));
      card.appendChild(S.node("p", null, approval.summary));
      if (approval.displayCommand) card.appendChild(S.node("pre", "mono", approval.displayCommand));
      if (approval.reason) card.appendChild(S.node("p", null, approval.reason));
      if (approval.relativePaths && approval.relativePaths.length) addListBlock(card, "涉及路径", approval.relativePaths);
      var actions = S.node("div", "approval-actions");
      var decisions = approval.decisionOptions && approval.decisionOptions.length
        ? approval.decisionOptions : ["allow", "deny"];
      decisions.forEach(function (decision) {
        var allowed = decision.toLowerCase() === "deny" ? approval.canDeny : approval.canAllow;
        var command = approval.isDirect ? "resolveDirectApproval" : "resolveApproval";
        actions.appendChild(S.button(
          decisionLabel(decision), command,
          { approvalID: approval.approvalID, taskID: approval.taskID, decision: decision },
          emit, decision.toLowerCase() === "deny" ? "small danger" : "small primary",
          approval.resolving || !allowed
        ));
      });
      card.appendChild(actions);
      section.appendChild(card);
    });
    container.appendChild(section);
  }

  function decisionLabel(value) {
    var lower = value.toLowerCase();
    if (lower === "allow") return "允许";
    if (lower === "deny") return "拒绝";
    return value;
  }

  function render(page, emit) {
    var header = document.getElementById("workbench-header");
    var content = document.getElementById("workbench-inspector-content");
    if (!page) {
      document.getElementById("chat-browser-slot").classList.add("browser-hidden");
      document.getElementById("browser-slot-note").textContent = "等待本机 Service 提供浏览器状态";
      S.clear(document.getElementById("browser-controls"));
      S.pageHeader(header, { title: "工作台", subtitle: "正在从本机 Service 读取任务状态。", symbol: "bubble.left.and.text.bubble.right.fill" });
      S.empty(content, "工作台暂不可用", "连接本机 Service 后，任务和审批会显示在这里。");
      return;
    }
    S.pageHeader(header, page.header);
    renderPermissionPicker(header, page, emit);
    renderBrowser(page, emit);
    renderProjectPicker(page, emit);
    S.clear(content);
    renderTaskList(content, page, emit);
    renderTaskDetail(content, page, emit);
    renderApprovals(content, page, emit);
  }

  global.CodexBridgeDesktopWorkbenchPage = { render: render };
}(window));
