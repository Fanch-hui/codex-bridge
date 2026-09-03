(function (global) {
  "use strict";

  var S = global.CodexBridgeDesktopPageSupport;

  function toneForStatus(status) {
    if (status === "running" || status === "starting" || status === "运行中" || status === "正在启动") return "running";
    if (status === "completed" || status === "已完成" || status === "就绪") return "success";
    if (status === "failed" || status === "失败") return "error";
    return (status && status.indexOf("approval") >= 0) ? "warning" : "neutral";
  }

  function renderBrowser(page, emit) {
    var browser = page.browser || {}, tb = document.getElementById("workbench-browser-toolbar");
    var slot = document.getElementById("chat-browser-slot"), note = document.getElementById("browser-slot-note");
    S.clear(tb);
    var navGroup = S.node("div", "browser-nav-group");
    [["chevron.left", "后退", "browserBack", !browser.canGoBack],
     ["chevron.right", "前进", "browserForward", !browser.canGoForward],
     ["arrow.clockwise", "刷新当前网页", "browserReload", !browser.canReload]].forEach(function (n) {
      var btn = S.button("", n[2], {}, emit, "icon-btn-small", n[3]);
      btn.title = n[1]; btn.appendChild(S.icon(n[0])); navGroup.appendChild(btn);
    });
    tb.appendChild(navGroup);
    var urlPill = S.node("div", "browser-url-pill mono");
    urlPill.appendChild(S.icon("lock.fill", "url-lock-icon"));
    urlPill.appendChild(S.node("span", "url-text", "https://chatgpt.com"));
    tb.appendChild(urlPill);
    tb.appendChild(S.node("div", "toolbar-spacer"));

    var toggleWrap = S.node("label", "browser-toggle-wrap");
    toggleWrap.appendChild(S.node("span", "browser-toggle-title", "内置浏览器"));
    var toggleBtn = S.node("button", "switch-toggle" + (browser.enabled ? " is-active" : ""));
    toggleBtn.type = "button"; toggleBtn.disabled = !browser.canToggle;
    toggleBtn.appendChild(S.node("span", "switch-thumb"));
    toggleBtn.addEventListener("click", function () { emit("setBrowserEnabled", { enabled: !browser.enabled }); });
    toggleWrap.appendChild(toggleBtn);
    tb.appendChild(toggleWrap);

    if (browser.canOpenExternally) {
      var extBtn = S.button("", "openBrowserExternally", {}, emit, "browser-external-btn link-button");
      extBtn.appendChild(S.icon("safari", "external-icon"));
      extBtn.appendChild(S.node("span", null, "在外部浏览器打开"));
      tb.appendChild(extBtn);
    }
    slot.classList.toggle("browser-hidden", !(browser.visible && browser.enabled));
    S.clear(note);
    if (!browser.enabled) {
      var ph = S.node("div", "browser-disabled-placeholder");
      ph.appendChild(S.icon("circle.dashed", "placeholder-icon"));
      ph.appendChild(S.node("div", "placeholder-title", "内置浏览器已关闭"));
      ph.appendChild(S.node("div", "placeholder-sub", "点击右上角开关重新开启，登录状态会保留。"));
      note.appendChild(ph);
    } else {
      note.textContent = browser.status || "由宿主加载真实 ChatGPT 工作区";
    }
  }

  function renderInspectorHeader(page, emit) {
    var header = document.getElementById("workbench-inspector-header");
    S.clear(header);
    // Row 1: Project folder icon + Project dropdown + Status badge
    var row1 = S.node("div", "inspector-header-row row-project"), pGroup = S.node("div", "project-selector-group");
    pGroup.appendChild(S.icon("folder.fill", "project-folder-icon"));
    var selectWrap = S.node("div", "project-select-wrap"), select = S.node("select", "project-native-select");
    var projects = page.projects || [];
    projects.forEach(function (p) {
      var opt = S.node("option", null, p.title);
      opt.value = p.id; if (p.id === page.selectedProjectID) opt.selected = true; select.appendChild(opt);
    });
    select.addEventListener("change", function () { emit("selectProject", { projectID: select.value }); });
    selectWrap.appendChild(select);
    var curP = projects.find(function (p) { return p.id === page.selectedProjectID; });
    var pFace = S.node("span", "project-dropdown-face");
    pFace.appendChild(S.node("span", "project-title-text", (curP ? curP.title : (projects[0] ? projects[0].title : "选择项目"))));
    pFace.appendChild(S.icon("chevron.down", "dropdown-arrow"));
    selectWrap.appendChild(pFace); pGroup.appendChild(selectWrap); row1.appendChild(pGroup);

    var statusWrap = S.node("div", "inspector-status-wrap");
    if (page.selectedTask) {
      statusWrap.appendChild(S.badge(page.selectedTask.provider, "neutral"));
      statusWrap.appendChild(S.badge(page.selectedTask.status, toneForStatus(page.selectedTask.status)));
    } else {
      statusWrap.appendChild(S.badge(page.projectStatus || "就绪", page.projectStatusTone || "success"));
    }
    row1.appendChild(statusWrap);
    header.appendChild(row1);

    // Row 2: Subtitle
    var subText = "远程 MCP 调用 Codex 或外部 Agent 时，默认在当前选择的项目中执行";
    if (page.selectedTask && page.selectedTask.provider && page.selectedTask.permissionMode) {
      subText = page.selectedTask.provider + " 原生 " + page.selectedTask.permissionMode + "，在当前项目执行并在此处显示实时结果";
    }
    header.appendChild(S.node("p", "inspector-subtitle", subText));

    // Row 3: Permission segmented control: [ Read Only | Write ]
    var row3 = S.node("div", "inspector-header-row row-permissions"), permLabel = S.node("div", "permission-row-label");
    permLabel.appendChild(S.icon("doc.text", "perm-icon"));
    permLabel.appendChild(S.node("span", null, "GPT/Qwen 新任务"));
    row3.appendChild(permLabel);

    var seg = S.node("div", "segmented-control"), isRO = page.permissionMode === "read-only";
    var rBtn = S.node("button", "segmented-btn" + (isRO ? " is-active" : ""), "Read Only");
    rBtn.type = "button"; rBtn.addEventListener("click", function () { emit("setWorkbenchPermissionMode", { mode: "read-only" }); });
    seg.appendChild(rBtn);
    var wBtn = S.node("button", "segmented-btn" + (!isRO ? " is-active" : ""), "Write");
    wBtn.type = "button"; wBtn.addEventListener("click", function () { emit("setWorkbenchPermissionMode", { mode: "workspace-write" }); });
    seg.appendChild(wBtn);
    row3.appendChild(seg);
    header.appendChild(row3);

    // Row 4: Task selector dropdown + Action button
    var row4 = S.node("div", "inspector-header-row row-tasks"), taskWrap = S.node("div", "task-picker-wrap");
    taskWrap.appendChild(S.icon("list.bullet.rectangle", "task-picker-icon"));
    var taskSelect = S.node("select", "task-native-select"), tasks = page.tasks || [];
    var defaultOpt = S.node("option", null, "选择 Agent 任务 (" + tasks.length + ")");
    defaultOpt.value = ""; taskSelect.appendChild(defaultOpt);
    var curTask = null;
    tasks.forEach(function (t) {
      var opt = S.node("option", null, "[" + t.provider + "] " + t.title + " (" + t.status + ")");
      opt.value = t.taskID;
      if (t.taskID === page.selectedTaskID || t.selected) { opt.selected = true; curTask = t; }
      taskSelect.appendChild(opt);
    });
    taskSelect.addEventListener("change", function () { if (taskSelect.value) emit("selectTask", { taskID: taskSelect.value }); });
    taskWrap.appendChild(taskSelect);

    var taskFace = S.node("span", "task-dropdown-face");
    var taskFaceLabel = curTask ? ("[" + curTask.provider + "] " + curTask.title) : ("选择 Agent 任务 (" + tasks.length + ")");
    taskFace.appendChild(S.node("span", "task-title-text", taskFaceLabel));
    taskFace.appendChild(S.icon("chevron.down", "dropdown-arrow"));
    taskWrap.appendChild(taskFace);
    row4.appendChild(taskWrap);

    if (curTask && (curTask.canInterrupt || curTask.isRunning)) {
      row4.appendChild(S.button("中断", "interruptTask", { taskID: curTask.taskID }, emit, "small danger", false));
    }
    header.appendChild(row4);
  }

  function renderApprovals(page, emit) {
    var container = document.getElementById("workbench-inspector-approvals");
    S.clear(container);
    if (!page.approvals || page.approvals.length === 0) return;
    var section = S.node("div", "approvals-tray");
    page.approvals.forEach(function (appr) {
      var card = S.node("article", "approval-card");
      card.appendChild(S.node("h4", null, appr.title || appr.kind));
      card.appendChild(S.node("p", null, appr.summary));
      if (appr.displayCommand) card.appendChild(S.node("pre", "mono", appr.displayCommand));
      if (appr.reason) card.appendChild(S.node("p", null, appr.reason));
      if (appr.relativePaths && appr.relativePaths.length) addListBlock(card, "涉及路径", appr.relativePaths);
      var actions = S.node("div", "approval-actions");
      var decs = appr.decisionOptions && appr.decisionOptions.length ? appr.decisionOptions : ["allow", "deny"];
      if (appr.canDeny && !decs.some(function (d) { return d.toLowerCase() === "deny"; })) decs = decs.concat(["deny"]);
      decs.forEach(function (dec) {
        var isDeny = dec.toLowerCase() === "deny", allowed = isDeny ? appr.canDeny : appr.canAllow;
        var cmd = appr.isDirect ? "resolveDirectApproval" : "resolveApproval";
        actions.appendChild(S.button(isDeny ? "拒绝" : (dec.toLowerCase() === "allow" ? "允许" : dec), cmd,
          { approvalID: appr.approvalID, taskID: appr.taskID, decision: dec }, emit,
          isDeny ? "small danger" : "small primary", appr.resolving || !allowed));
      });
      card.appendChild(actions); section.appendChild(card);
    });
    container.appendChild(section);
  }

  function renderContent(page, emit) {
    var content = document.getElementById("workbench-inspector-content");
    S.clear(content);
    if (!page.selectedTask) {
      var empty = S.node("div", "workbench-empty-state");
      empty.appendChild(S.icon("sparkles", "empty-sparkle-icon"));
      empty.appendChild(S.node("h3", "empty-title", "等待 ChatGPT 指令"));
      empty.appendChild(S.node("p", "empty-desc", "在左侧 ChatGPT 网页版发起提问并调用 MCP 工具，本面板将实时呈现任务流与所选 Provider 的执行结果。"));
      content.appendChild(empty);
      return;
    }
    var detail = page.selectedTask, row = S.safeArray(page.tasks).find(function (t) { return t.taskID === detail.taskID; }) || {};
    if (detail.currentStep) {
      var stepCard = S.node("div", "page-card current-step-card");
      stepCard.appendChild(S.node("div", "step-caption", "当前正在执行"));
      stepCard.appendChild(S.node("div", "step-text", detail.currentStep));
      content.appendChild(stepCard);
    }
    var card = S.node("div", "page-card task-detail-card");
    card.appendChild(S.node("h3", "detail-title", detail.title));
    card.appendChild(S.node("p", "detail-subtitle", detail.projectName + " · " + detail.provider));
    var grid = S.node("dl", "detail-grid");
    addDetail(grid, "状态", detail.status); addDetail(grid, "更新时间", detail.updatedAt);
    addDetail(grid, "模型", detail.model || "未记录"); addDetail(grid, "权限", detail.permissionMode || "未记录");
    if (detail.failureCode) addDetail(grid, "失败代码", detail.failureCode);
    card.appendChild(grid);

    var actions = S.node("div", "form-actions");
    if (row.canInterrupt) actions.appendChild(S.button("中断", "interruptTask", { taskID: detail.taskID }, emit, "small danger", false));
    if (row.canStop) actions.appendChild(S.button("停止", "stopTask", { taskID: detail.taskID }, emit, "small danger", false));
    if (row.canDelete || (!row.isRunning && !row.isActive)) {
      var rm = S.button("删除会话", null, {}, emit, "small danger", false);
      rm.addEventListener("click", function () {
        if (global.confirm("删除会话？\n这会删除 Codex Bridge 保存的任务、事件和对话记录，无法撤销。")) emit("deleteTask", { taskID: detail.taskID });
      });
      actions.appendChild(rm);
    }
    actions.appendChild(S.button("刷新任务", "refreshTasks", {}, emit, "small", false));
    card.appendChild(actions);

    if (row.canSteer) card.appendChild(steerForm(page, detail.taskID, emit));
    if (detail.resultSummary) addTextBlock(card, "结果摘要", detail.resultSummary);
    if (detail.changedFiles && detail.changedFiles.length) addListBlock(card, "变更文件", detail.changedFiles);
    if (detail.activity && detail.activity.length) addActivityBlock(card, detail.activity);
    if (detail.conversation && detail.conversation.length) addConversationBlock(card, detail.conversation, page, emit);
    content.appendChild(card);
  }

  function addDetail(c, k, v) { var it = S.node("div", "detail-item"); it.appendChild(S.node("dt", null, k)); it.appendChild(S.node("dd", null, v)); c.appendChild(it); }
  function addTextBlock(c, title, text) { c.appendChild(S.node("h4", "subsection-title", title)); c.appendChild(S.node("p", "muted", text)); }
  function addListBlock(c, title, values) {
    c.appendChild(S.node("h4", "subsection-title", title));
    var list = S.node("div", "activity-list");
    values.forEach(function (v) { list.appendChild(S.node("div", "activity-row mono", v)); });
    c.appendChild(list);
  }

  function steerForm(page, taskID, emit) {
    var form = S.node("div", "form-grid"), input = S.textField("补充指令", "", "当前轮完成后继续", "full");
    form.appendChild(input.wrapper);
    var modes = S.selectField("发送方式", page.steerModes && page.steerModes[0] ? page.steerModes[0].id : "", page.steerModes || [], function () {}, "");
    form.appendChild(modes.wrapper);
    var action = S.node("div", "form-actions full"), send = S.button("发送 Steer", null, {}, emit, "small primary", false);
    send.addEventListener("click", function () {
      var val = input.control.value; if (!val.trim()) return;
      emit("steerTask", { taskID: taskID, input: val, mode: modes.control.value }); input.control.value = "";
    });
    action.appendChild(send); form.appendChild(action);
    var wrapper = S.node("div", "steer-form"); wrapper.appendChild(form); return wrapper;
  }

  function addActivityBlock(container, values) {
    container.appendChild(S.node("h4", "subsection-title", "实时活动"));
    var list = S.node("div", "activity-list");
    values.forEach(function (a) {
      var row = S.node("div", "activity-row");
      row.appendChild(S.node("span", "muted mono", a.occurredAt)); row.appendChild(S.node("span", null, a.summary)); list.appendChild(row);
    });
    container.appendChild(list);
  }

  function addConversationBlock(container, values, page, emit) {
    container.appendChild(S.node("h4", "subsection-title", "对话"));
    var list = S.node("div", "conversation-list");
    values.forEach(function (e) {
      var it = S.node("div", "conversation-entry entry-" + (e.kind || "message")), hd = S.node("div", "entry-heading");
      hd.appendChild(S.node("span", "entry-role", e.role));
      if (e.kind) hd.appendChild(S.badge(e.kind, "neutral"));
      if (!e.isFinal) hd.appendChild(S.badge("流式", "running"));
      it.appendChild(hd);
      if (e.toolName) {
        var tl = S.node("div", "entry-tool mono", e.toolName);
        if (e.toolStatus) tl.appendChild(S.badge(e.toolStatus, e.toolStatus === "failed" ? "error" : "neutral"));
        it.appendChild(tl);
      }
      it.appendChild(S.node("div", "entry-text", e.text));
      if (e.toolArguments) it.appendChild(S.node("pre", "entry-arguments mono", e.toolArguments));
      list.appendChild(it);
    });
    container.appendChild(list);
    if (page.browser && page.browser.canLoadEarlierConversation) container.appendChild(S.button("加载更早对话", "loadEarlierConversation", { taskID: page.selectedTaskID }, emit, "small", false));
    if (page.selectedTaskID) container.appendChild(S.button("刷新对话", "refreshConversation", { taskID: page.selectedTaskID }, emit, "small", false));
  }

  function renderFooter(page, emit) {
    var footer = document.getElementById("workbench-inspector-footer");
    S.clear(footer);
    footer.appendChild(S.node("span", "footer-status-text", page.engineStatus || "已连接本机 Codex 引擎"));
    var refreshBtn = S.button("", "refresh", {}, emit, "footer-refresh-btn link-button");
    refreshBtn.appendChild(S.icon("arrow.clockwise"));
    refreshBtn.appendChild(S.node("span", null, "刷新"));
    footer.appendChild(refreshBtn);
  }

  function render(page, emit) {
    if (!page) {
      document.getElementById("chat-browser-slot").classList.add("browser-hidden");
      document.getElementById("browser-slot-note").textContent = "等待本机 Service 提供浏览器状态";
      return;
    }
    renderBrowser(page, emit);
    renderInspectorHeader(page, emit);
    renderApprovals(page, emit);
    renderContent(page, emit);
    renderFooter(page, emit);
  }

  global.CodexBridgeDesktopWorkbenchPage = { render: render };
}(window));
