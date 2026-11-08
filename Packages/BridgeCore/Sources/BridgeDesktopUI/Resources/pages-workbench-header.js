(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;

  function renderBrowser(page, emit) {
    global.CodexBridgeDesktopWorkbenchBrowser.render(page, emit);
  }

  function createHeaderActions(model) {
    // The composer picks each task's own permission; the toolbar holds the default that
    // ChatGPT, Qwen and Gemini use when they start Agent tasks.
    var actions = S.node("div", "inspector-toolbar-actions");
    model.permission = S.node("select", "browser-site-select workbench-default-permission");
    model.permission.title = "ChatGPT、Qwen、Gemini 发起 Agent 任务时的默认权限";
    model.permission.setAttribute("aria-label", model.permission.title);
    model.permission.addEventListener("change", function () {
      if (model.emit) model.emit("setWorkbenchPermissionMode", { mode: model.permission.value });
    });
    S.autoFitSelect(model.permission);
    actions.appendChild(model.permission);
    model.historySearch = global.CodexBridgeDesktopTaskHistorySearch.createDialog(actions);
    model.toggle = S.button("浏览器", null, {}, null, "small workbench-browser-toggle");
    model.toggle.setAttribute("role", "switch");
    model.toggle.setAttribute("aria-label", "内置浏览器");
    model.toggle.addEventListener("click", function () {
      var browser = model.page && model.page.browser || {};
      if (!model.toggle.disabled && model.emit) model.emit("setBrowserEnabled", { enabled: !browser.enabled });
    });
    actions.appendChild(model.toggle);
    model.taskActions = S.node("div", "workbench-task-actions");
    actions.appendChild(model.taskActions);
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
    model.context = S.node("div", "collaboration-toolbar-context");
    model.title = S.node("span", "dsh-toolbar-title"); model.context.appendChild(model.title);
    (document.getElementById("workspace-toolbar-context") || header).appendChild(model.context);
    model.actions = createHeaderActions(model);
    (document.getElementById("workspace-toolbar-actions") || header).appendChild(model.actions);
    createQueue(model, header);
    header.__inspectorHeader = model;
    return model;
  }

  function updateInspectorHeader(model, page, emit) {
    model.page = page; model.emit = emit;
    var permissions = S.safeArray(page.permissionOptions);
    if (!permissions.length) permissions = [{ id: "full", title: "完整权限" }, { id: "read-only", title: "只读权限" }];
    var permissionItems = permissions.map(function (choice) {
      return { id: choice.id, title: choice.id === "read-only" ? "只读权限" : "完整权限" };
    });
    if (global.CodexBridgeDesktopFormDraft && global.CodexBridgeDesktopFormDraft.selectOptions) {
      global.CodexBridgeDesktopFormDraft.selectOptions(model.permission, permissionItems, false);
    } else {
      S.clear(model.permission);
      permissionItems.forEach(function (item) {
        var opt = S.node("option", "", item.title);
        opt.value = item.id;
        model.permission.appendChild(opt);
      });
    }
    model.permission.value = page.permissionMode === "read-only" ? "read-only" : "full";
    var browser = page.browser || {};
    model.toggle.classList.toggle("is-active", !!browser.enabled);
    model.toggle.setAttribute("aria-checked", String(!!browser.enabled));
    model.toggle.title = browser.enabled ? "收起内置浏览器" : "显示内置浏览器";
    model.toggle.disabled = !browser.canToggle;

    model.title.textContent = page.selectedTask && page.selectedTask.title || page.draftTitle || "网页工作台";
    model.title.title = model.title.textContent;
    var queueTask = page.selectedTask;
    model.queue.hidden = !(queueTask && queueTask.queuePosition);
    if (document.getElementById("workspace-toolbar-actions")) {
      document.getElementById("workbench-inspector-header").hidden = model.queue.hidden;
    }
    if (queueTask && queueTask.queuePosition) {
      var queueText = "排队第 " + queueTask.queuePosition + " 位";
      if (queueTask.queueOccupantTaskID) queueText += " · 等待 " + queueTask.queueOccupantTaskID;
      model.queueText.title = queueTask.queueRequestedAt ? new Date(queueTask.queueRequestedAt).toLocaleString() : "";
      model.queueText.textContent = queueText;
    }
    model.taskActions.hidden = !page.selectedTask;
    if (page.selectedTask) {
      var row = S.safeArray(page.tasks).find(function (task) {
        var selected = page.selectedTask;
        return task.taskID === selected.taskID || selected.sessionID && task.sessionID === selected.sessionID
          && task.providerID === selected.providerID && task.projectID === (selected.projectID || page.selectedProjectID);
      }) || {};
      global.CodexBridgeDesktopWorkbenchActions.render(model.taskActions, page.selectedTask, row, emit, { showDetails: true, queueControl: true, composerControls: true });
    }
  }

  function renderInspectorHeader(page, emit) {
    var header = document.getElementById("workbench-inspector-header");
    var model = header.__inspectorHeader || createInspectorHeader(header);
    updateInspectorHeader(model, page, emit);
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
      page.projects, page.selectedProjectID, page.selectedTaskID, page.permissionMode, page.permissionOptions, page.draftTitle,
      (page.nativeSessions || {}).installations,
      page.projectStatus, page.projectStatusTone, detail.provider, detail.status, detail.permissionMode, detail.canOpenNativeSession, detail.canInterrupt, detail.canStop, detail.resultSummary, detail.taskID, detail.sessionID, detail.queuePosition, detail.queueOccupantTaskID, detail.queueRequestedAt,
      S.safeArray(page.tasks).map(function (t) {
        return [t.taskID, t.providerID, t.provider, t.title, t.status, t.selected, t.canInterrupt, t.canDelete, t.isRunning];
      })
    ]);
    if (header !== headerSignature) {
      var renderHeaderStable = global.CodexBridgeDesktopStableRender;
      if (renderHeaderStable) {
        renderHeaderStable(
          document.getElementById("workspace-toolbar-actions") || document.getElementById("workbench-inspector-header"),
          header,
          function () { renderInspectorHeader(page, emit); },
          true
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
    setVisible: function (visible) {
      var header = document.getElementById("workbench-inspector-header"), model = header && header.__inspectorHeader;
      if (model) { model.context.hidden = !visible; model.actions.hidden = !visible; }
    },
    reset: function () { browserSignature = headerSignature = undefined; }
  };
}(window));
