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
      btn.title = n[1]; btn.setAttribute("aria-label", n[1]); btn.appendChild(S.icon(n[0])); navGroup.appendChild(btn);
    });
    tb.appendChild(navGroup);
    var urlPill = S.node("div", "browser-url-pill mono");
    urlPill.appendChild(S.icon("lock.fill", "url-lock-icon"));
    urlPill.appendChild(S.node("span", "url-text", browser.url || "https://chatgpt.com"));
    tb.appendChild(urlPill);
    tb.appendChild(S.node("div", "toolbar-spacer"));

    if (browser.canOpenExternally) {
      var extBtn = S.button("", "openBrowserExternally", {}, emit, "browser-external-btn link-button");
      extBtn.appendChild(S.icon("safari", "external-icon"));
      extBtn.appendChild(S.node("span", null, "在外部浏览器打开"));
      tb.appendChild(extBtn);
    }
    slot.classList.toggle("browser-hidden", !(browser.visible && browser.enabled));
    S.clear(note);
    note.textContent = browser.status || "由宿主加载真实 ChatGPT 工作区";
    document.querySelector(".workbench-layout").classList.toggle("browser-collapsed", !browser.enabled);
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

  function createInspectorHeader(header) {
    S.clear(header);
    var model = { page: null, emit: null };
    var controls = S.node("div", "inspector-browser-controls");
    var toggleWrap = S.node("label", "browser-toggle-wrap");
    toggleWrap.appendChild(S.node("span", "browser-toggle-title", "内置浏览器"));
    model.toggle = S.node("button", "switch-toggle");
    model.toggle.setAttribute("role", "switch");
    model.toggle.setAttribute("aria-label", "内置浏览器");
    model.toggle.type = "button";
    model.toggle.appendChild(S.node("span", "switch-thumb"));
    model.toggle.addEventListener("click", function () {
      var browser = model.page && model.page.browser || {};
      if (!model.toggle.disabled && model.emit) model.emit("setBrowserEnabled", { enabled: !browser.enabled });
    });
    toggleWrap.appendChild(model.toggle);
    controls.appendChild(toggleWrap);
    header.appendChild(controls);

    var row1 = S.node("div", "inspector-header-row row-project");
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
    row1.appendChild(pGroup);
    model.status = S.node("div", "inspector-status-wrap");
    row1.appendChild(model.status);
    header.appendChild(row1);

    var row3 = S.node("div", "inspector-header-row row-permissions");
    var permLabel = S.node("div", "permission-row-label");
    permLabel.appendChild(S.icon("doc.text", "perm-icon"));
    permLabel.appendChild(S.node("span", null, "Agent权限"));
    row3.appendChild(permLabel);
    var seg = S.node("div", "segmented-control");
    model.readOnly = S.node("button", "segmented-btn", "Read Only");
    model.readOnly.type = "button";
    model.readOnly.addEventListener("click", function () {
      if (model.emit) model.emit("setWorkbenchPermissionMode", { mode: "read-only" });
    });
    model.write = S.node("button", "segmented-btn", "Write");
    model.write.type = "button";
    model.write.addEventListener("click", function () {
      if (model.emit) model.emit("setWorkbenchPermissionMode", { mode: "workspace-write" });
    });
    seg.appendChild(model.readOnly); seg.appendChild(model.write); row3.appendChild(seg);
    header.appendChild(row3);

    model.taskRow = S.node("div", "inspector-header-row row-tasks");
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
    model.taskRow.appendChild(taskWrap);
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
    model.taskRow.appendChild(model.interrupt);
    header.appendChild(model.taskRow);
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
    header.__inspectorHeader = model;
    return model;
  }

  function updateInspectorHeader(model, page, emit) {
    model.page = page; model.emit = emit;
    var browser = page.browser || {};
    model.toggle.className = "switch-toggle" + (browser.enabled ? " is-active" : "");
    model.toggle.setAttribute("aria-checked", String(!!browser.enabled));
    model.toggle.disabled = !browser.canToggle;

    var projects = S.safeArray(page.projects);
    setOptions(model.projectSelect, projects.map(function (project) {
      return { id: project.id, title: project.title };
    }), page.selectedProjectID);
    var currentProject = projects.find(function (project) { return project.id === page.selectedProjectID; });
    model.projectTitle.textContent = currentProject
      ? currentProject.title : projects.length ? projects[0].title : "选择项目";
    S.clear(model.status);
    if (page.selectedTask) {
      model.status.appendChild(S.badge(page.selectedTask.provider, "neutral"));
      model.status.appendChild(S.badge(page.selectedTask.status, toneForStatus(page.selectedTask.status)));
    } else {
      model.status.appendChild(S.badge(page.projectStatus || "就绪", page.projectStatusTone || "success"));
    }

    var queueTask = page.selectedTask;
    model.queue.hidden = !(queueTask && queueTask.queuePosition);
    if (queueTask && queueTask.queuePosition) {
      var queueText = "排队第 " + queueTask.queuePosition + " 位";
      if (queueTask.queueOccupantTaskID) queueText += " · 等待 " + queueTask.queueOccupantTaskID;
      if (queueTask.queueRequestedAt) queueText += " · " + new Date(queueTask.queueRequestedAt).toLocaleString();
      model.queueText.textContent = queueText;
    }
    var readOnly = page.permissionMode === "read-only";
    model.readOnly.className = "segmented-btn" + (readOnly ? " is-active" : "");
    model.write.className = "segmented-btn" + (readOnly ? "" : " is-active");

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
      var renderBrowserStable = global.CodexBridgeDesktopStableRender;
      if (renderBrowserStable) {
        renderBrowserStable(
          document.getElementById("workbench-browser-toolbar"),
          browser,
          function () { renderBrowser(page, emit); }
        );
      } else {
        renderBrowser(page, emit);
      }
      browserSignature = browser;
    }
    var detail = page.selectedTask || {};
    var header = JSON.stringify([
      page.browser && page.browser.enabled, page.browser && page.browser.canToggle,
      page.projects, page.selectedProjectID, page.selectedTaskID, page.permissionMode,
      page.projectStatus, page.projectStatusTone, detail.provider, detail.status, detail.permissionMode, detail.canInterrupt, detail.queuePosition, detail.queueOccupantTaskID, detail.queueRequestedAt,
      S.safeArray(page.tasks).map(function (t) {
        return [t.taskID, t.provider, t.title, t.status, t.selected, t.canInterrupt, t.isRunning];
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
  }

  global.CodexBridgeDesktopWorkbenchHeader = {
    render: render,
    reset: function () { browserSignature = headerSignature = undefined; }
  };
}(window));
