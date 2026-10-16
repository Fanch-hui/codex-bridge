(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;

  function toneForStatus(status) {
    if (status === "running" || status === "starting" || status === "运行中" || status === "正在启动") return "running";
    if (status === "completed" || status === "已完成" || status === "已创建" || status === "就绪") return "success";
    if (status === "failed" || status === "失败") return "error";
    if (/等待|审批|排队|queued|waiting|awaiting/.test(status || "")) return "warning";
    return (status && status.indexOf("approval") >= 0) ? "warning" : "neutral";
  }

  function renderBrowser(page, emit) {
    global.CodexBridgeDesktopWorkbenchBrowser.render(page, emit);
  }

  function setOptions(control, options, selected) {
    var signature = JSON.stringify(options);
    if (control.__choiceSignature !== signature) {
      control.__choiceSignature = signature;
      S.clear(control);
      options.forEach(function (choice) {
        var option = S.node("option", null, choice.title);
        option.value = choice.id;
        option.disabled = choice.enabled === false;
        control.appendChild(option);
      });
    }
    control.value = selected || "";
  }

  function createContextPickers(model) {
    var context = S.node("div", "inspector-context-pickers");
    var pGroup = S.node("div", "project-selector-group");
    pGroup.appendChild(S.icon("folder.fill", "project-folder-icon"));
    var selectWrap = S.node("div", "project-select-wrap");
    model.projectSelect = S.node("select", "project-native-select");
    model.projectSelect.setAttribute("aria-label", "工作台项目");
    model.projectSelect.addEventListener("change", function () {
      if (model.emit && model.projectSelect.value) model.emit("selectProject", { projectID: model.projectSelect.value });
    });
    selectWrap.appendChild(model.projectSelect);
    var pFace = S.node("span", "project-dropdown-face");
    model.projectTitle = S.node("span", "project-title-text");
    pFace.appendChild(model.projectTitle);
    pFace.appendChild(S.icon("chevron.down", "dropdown-arrow"));
    selectWrap.appendChild(pFace);
    pGroup.appendChild(selectWrap);
    context.appendChild(pGroup);
    var taskWrap = S.node("div", "task-picker-wrap");
    taskWrap.appendChild(S.icon("list.bullet.rectangle", "task-picker-icon"));
    model.taskSelect = S.node("select", "task-native-select");
    model.taskSelect.setAttribute("aria-label", "当前 Agent 会话");
    model.taskSelect.addEventListener("change", function () {
      if (model.emit && model.taskSelect.value) model.emit("selectTask", { taskID: model.taskSelect.value });
    });
    taskWrap.appendChild(model.taskSelect);
    var taskFace = S.node("span", "task-dropdown-face");
    model.taskTitle = S.node("span", "task-title-text");
    taskFace.appendChild(model.taskTitle);
    taskFace.appendChild(S.icon("chevron.down", "dropdown-arrow"));
    taskWrap.appendChild(taskFace);
    context.appendChild(taskWrap);
    return context;
  }

  function createHeaderActions(model) {
    var actions = S.node("div", "inspector-toolbar-actions");
    model.status = S.node("div", "inspector-status-wrap");
    actions.appendChild(model.status);
    var permission = S.selectField("Agent 权限", "full", [
      { id: "read-only", title: "只读权限" }, { id: "full", title: "完整权限" }
    ], function (value) {
      if (model.emit) model.emit("setWorkbenchPermissionMode", { mode: value });
    }, "workbench-permission-picker compact-field");
    permission.wrapper.querySelector("label").hidden = true;
    model.permission = permission.control;
    actions.appendChild(permission.wrapper);
    model.nativeHistory = S.button("原生历史", null, {}, null, "small", false);
    model.nativeHistory.addEventListener("click", function () {
      var page = model.page || {}, directory = page.nativeSessions || {};
      var installations = S.safeArray(directory.installations);
      var installationID = directory.installationID || (installations[0] && installations[0].installationID);
      var projectID = page.selectedProjectID || (page.projects[0] && page.projects[0].id);
      if (!model.emit || !installationID || !projectID) return;
      model.emit("manageNativeAgentSession", {
        action: "list", projectID: projectID, installationID: installationID, offset: 0, limit: 50
      });
    });
    actions.appendChild(model.nativeHistory);
    model.openNativeSession = S.button("打开对应会话", null, {}, null, "small", false);
    model.openNativeSession.addEventListener("click", function () {
      var task = model.page && model.page.selectedTask;
      if (task && task.canOpenNativeSession && model.emit) model.emit("openDeepSeekHarnessSession", { taskID: task.taskID });
    });
    actions.appendChild(model.openNativeSession);
    model.interrupt = S.button("中断", null, {}, null, "small danger", false);
    model.interrupt.addEventListener("click", function () {
      var task = model.page && model.page.selectedTask;
      if (!task || !task.canInterrupt || model.interrupt.disabled || !model.emit) return;
      model.interrupt.__pendingTaskID = task.taskID;
      model.interrupt.disabled = true;
      model.interrupt.textContent = "中断请求中…";
      model.interrupt.setAttribute("aria-busy", "true");
      model.emit("interruptTask", { taskID: task.taskID });
    });
    actions.appendChild(model.interrupt);
    model.historySearch = global.CodexBridgeDesktopTaskHistorySearch.createDialog(actions);
    model.toggle = S.button("浏览器", null, {}, null, "small workbench-browser-toggle");
    model.toggle.setAttribute("role", "switch");
    model.toggle.setAttribute("aria-label", "内置浏览器");
    model.toggle.addEventListener("click", function () {
      var browser = model.page && model.page.browser || {};
      if (!model.toggle.disabled && model.emit) model.emit("setBrowserEnabled", { enabled: !browser.enabled });
    });
    actions.appendChild(model.toggle);
    return actions;
  }

  function createQueue(model, header) {
    model.queue = S.node("div", "workbench-queue-status");
    model.queueText = S.node("span", "muted");
    model.queue.appendChild(model.queueText);
    model.cancelQueue = S.button("取消排队", null, {}, null, "small", false);
    model.cancelQueue.addEventListener("click", function () {
      var task = model.page && model.page.selectedTask;
      if (!task || !task.queuePosition || model.cancelQueue.disabled || !model.emit) return;
      model.cancelQueue.disabled = true;
      model.cancelQueue.textContent = "取消中…";
      model.emit("stopTask", { taskID: task.taskID });
      global.setTimeout(function () {
        model.cancelQueue.disabled = false;
        model.cancelQueue.textContent = "取消排队";
      }, 2000);
    });
    model.queue.appendChild(model.cancelQueue);
    header.appendChild(model.queue);
  }

  function createInspectorHeader(header) {
    S.clear(header);
    var model = { page: null, emit: null };
    var toolbar = S.node("div", "inspector-toolbar");
    toolbar.appendChild(createContextPickers(model));
    toolbar.appendChild(createHeaderActions(model));
    header.appendChild(toolbar);
    createQueue(model, header);
    header.__inspectorHeader = model;
    return model;
  }

  function updateInspectorHeader(model, page, emit) {
    model.page = page; model.emit = emit;
    model.openNativeSession.hidden = !(page.selectedTask && page.selectedTask.canOpenNativeSession);
    model.nativeHistory.disabled = !S.safeArray((page.nativeSessions || {}).installations).length;
    var browser = page.browser || {};
    model.toggle.classList.toggle("is-active", !!browser.enabled);
    model.toggle.setAttribute("aria-checked", String(!!browser.enabled));
    model.toggle.title = browser.enabled ? "收起内置浏览器" : "显示内置浏览器";
    model.toggle.disabled = !browser.canToggle;

    var projects = S.safeArray(page.projects);
    setOptions(model.projectSelect, projects.map(function (project) {
      return { id: project.id, title: project.title };
    }), page.selectedProjectID);
    var currentProject = projects.find(function (project) { return project.id === page.selectedProjectID; });
    model.projectTitle.textContent = currentProject
      ? currentProject.title : projects.length ? projects[0].title : "选择项目";
    model.projectTitle.title = model.projectTitle.textContent;
    S.clear(model.status);
    if (page.selectedTask) {
      model.status.appendChild(S.status(page.selectedTask.status, toneForStatus(page.selectedTask.status)));
    } else {
      model.status.appendChild(S.status(page.projectStatus || "就绪", page.projectStatusTone || "success"));
    }

    var queueTask = page.selectedTask;
    model.queue.hidden = !(queueTask && queueTask.queuePosition);
    if (queueTask && queueTask.queuePosition) {
      var queueText = "排队第 " + queueTask.queuePosition + " 位";
      if (queueTask.queueOccupantTaskID) queueText += " · 等待 " + queueTask.queueOccupantTaskID;
      model.queueText.title = queueTask.queueRequestedAt ? new Date(queueTask.queueRequestedAt).toLocaleString() : "";
      model.queueText.textContent = queueText;
    }
    var readOnly = page.permissionMode === "read-only";
    model.permission.value = readOnly ? "read-only" : "full";
    model.permission.title = readOnly ? "Agent 允许读取，禁止写入和联网" : "Agent 允许读取、写入和联网";
    updateTaskPicker(model, page);
  }

  function updateTaskPicker(model, page) {
    var tasks = S.safeArray(page.tasks), choices = [{ id: "", title: "选择 Agent 会话 (" + tasks.length + ")" }];
    groupTasks(tasks).forEach(function (group) {
      choices.push({ group: group.label + " 会话", options: group.tasks.map(function (task) {
        return { id: task.taskID, title: task.title + " (" + task.status + ")" };
      }) });
    });
    var taskSignature = JSON.stringify(choices);
    if (model.taskSelect.__choiceSignature !== taskSignature) {
      model.taskSelect.__choiceSignature = taskSignature;
      S.clear(model.taskSelect);
      choices.forEach(function (choice) {
        if (choice.group) {
          var group = S.node("optgroup"); group.label = choice.group;
          choice.options.forEach(function (optionValue) {
            var option = S.node("option", null, optionValue.title);
            option.value = optionValue.id; group.appendChild(option);
          });
          model.taskSelect.appendChild(group);
          return;
        }
        var option = S.node("option", null, choice.title);
        option.value = choice.id; model.taskSelect.appendChild(option);
      });
    }
    model.taskSelect.value = page.selectedTaskID || "";
    var currentTask = tasks.find(function (task) {
      return task.taskID === page.selectedTaskID || task.selected;
    });
    model.taskTitle.textContent = currentTask
      ? "[" + currentTask.provider + "] " + currentTask.title
      : "选择 Agent 会话 (" + tasks.length + ")";
    model.taskTitle.title = model.taskTitle.textContent;
    var canInterrupt = !!(page.selectedTask && page.selectedTask.canInterrupt === true);
    var pendingInterrupt = canInterrupt && model.interrupt.__pendingTaskID === page.selectedTask.taskID;
    if (!canInterrupt || !page.selectedTask || page.selectedTask.taskID !== model.interrupt.__pendingTaskID) {
      model.interrupt.__pendingTaskID = null;
    }
    model.interrupt.hidden = !canInterrupt;
    model.interrupt.disabled = !canInterrupt || pendingInterrupt;
    model.interrupt.textContent = pendingInterrupt ? "中断请求中…" : "中断";
    model.interrupt.setAttribute("aria-busy", String(pendingInterrupt));
  }

  function renderInspectorHeader(page, emit) {
    var header = document.getElementById("workbench-inspector-header");
    var model = header.__inspectorHeader || createInspectorHeader(header);
    updateInspectorHeader(model, page, emit);
  }

  function groupTasks(tasks) {
    var groups = [], byProvider = new Map();
    tasks.forEach(function (task) {
      var key = task.providerID || task.provider || "unknown";
      var group = byProvider.get(key);
      if (!group) {
        group = { label: task.provider || task.providerID || "未知 Agent", tasks: [] };
        byProvider.set(key, group); groups.push(group);
      }
      group.tasks.push(task);
    });
    return groups;
  }

  var browserSignature, headerSignature;
  function render(page, emit) {
    var browser = JSON.stringify(page.browser || {});
    if (browser !== browserSignature) {
      renderBrowser(page, emit);
      browserSignature = browser;
    }
    var detail = page.selectedTask || {};
    var header = JSON.stringify([
      page.browser && page.browser.enabled, page.browser && page.browser.canToggle,
      page.projects, page.selectedProjectID, page.selectedTaskID, page.permissionMode,
      (page.nativeSessions || {}).installations,
      page.projectStatus, page.projectStatusTone, detail.provider, detail.status, detail.permissionMode, detail.canOpenNativeSession, detail.canInterrupt, detail.queuePosition, detail.queueOccupantTaskID, detail.queueRequestedAt,
      S.safeArray(page.tasks).map(function (t) {
        return [t.taskID, t.providerID, t.provider, t.title, t.status, t.selected, t.canInterrupt, t.isRunning];
      })
    ]);
    if (header !== headerSignature) {
      var renderHeaderStable = global.CodexBridgeDesktopStableRender;
      if (renderHeaderStable) {
        renderHeaderStable(
          document.getElementById("workbench-inspector-header"),
          header,
          function () { renderInspectorHeader(page, emit); }
        );
      } else {
        renderInspectorHeader(page, emit);
      }
      headerSignature = header;
    }
    var model = document.getElementById("workbench-inspector-header").__inspectorHeader;
    if (model) global.CodexBridgeDesktopTaskHistorySearch.update(model.historySearch, page, emit);
  }

  global.CodexBridgeDesktopWorkbenchHeader = {
    render: render,
    reset: function () { browserSignature = headerSignature = undefined; }
  };
}(window));
