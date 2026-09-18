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

  function renderInspectorHeader(page, emit) {
    var header = document.getElementById("workbench-inspector-header");
    S.clear(header);
    var browser = page.browser || {};
    var controls = S.node("div", "inspector-browser-controls");
    var toggleWrap = S.node("label", "browser-toggle-wrap");
    toggleWrap.appendChild(S.node("span", "browser-toggle-title", "内置浏览器"));
    var toggleBtn = S.node("button", "switch-toggle" + (browser.enabled ? " is-active" : ""));
    toggleBtn.setAttribute("role", "switch");
    toggleBtn.setAttribute("aria-label", "内置浏览器");
    toggleBtn.setAttribute("aria-checked", String(!!browser.enabled));
    toggleBtn.type = "button"; toggleBtn.disabled = !browser.canToggle;
    toggleBtn.appendChild(S.node("span", "switch-thumb"));
    toggleBtn.addEventListener("click", function () { emit("setBrowserEnabled", { enabled: !browser.enabled }); });
    toggleWrap.appendChild(toggleBtn);
    controls.appendChild(toggleWrap);
    header.appendChild(controls);


    // Row 1: Project folder icon + Project dropdown + Status badge
    var row1 = S.node("div", "inspector-header-row row-project"), pGroup = S.node("div", "project-selector-group");
    pGroup.appendChild(S.icon("folder.fill", "project-folder-icon"));
    var selectWrap = S.node("div", "project-select-wrap"), select = S.node("select", "project-native-select");
    select.setAttribute("aria-label", "工作台项目");
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

    // Row 3: Permission segmented control: [ Read Only | Write ]
    var row3 = S.node("div", "inspector-header-row row-permissions"), permLabel = S.node("div", "permission-row-label");
    permLabel.appendChild(S.icon("doc.text", "perm-icon"));
    permLabel.appendChild(S.node("span", null, "Agent权限"));
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

    header.appendChild(sessionPicker(page, emit));
  }

  function sessionPicker(page, emit) {
    var row4 = S.node("div", "inspector-header-row row-tasks"), taskWrap = S.node("div", "task-picker-wrap");
    taskWrap.appendChild(S.icon("list.bullet.rectangle", "task-picker-icon"));
    var taskSelect = S.node("select", "task-native-select"), tasks = page.tasks || [];
    var defaultOpt = S.node("option", null, "选择 Agent 会话 (" + tasks.length + ")");
    defaultOpt.value = ""; taskSelect.appendChild(defaultOpt);
    var curTask = null;
    groupTasks(tasks).forEach(function (group) {
      var taskGroup = S.node("optgroup"); taskGroup.label = group.label + " 会话";
      group.tasks.forEach(function (t) {
        var opt = S.node("option", null, t.title + " (" + t.status + ")");
        opt.value = t.taskID;
        if (t.taskID === page.selectedTaskID || t.selected) { opt.selected = true; curTask = t; }
        taskGroup.appendChild(opt);
      });
      taskSelect.appendChild(taskGroup);
    });
    taskSelect.setAttribute("aria-label", "当前 Agent 会话");
    taskSelect.addEventListener("change", function () {
      var option = taskSelect.options[taskSelect.selectedIndex];
      if (option && taskSelect.value) emit("selectTask", { taskID: taskSelect.value });
    });
    taskWrap.appendChild(taskSelect);

    var taskFace = S.node("span", "task-dropdown-face");
    var taskFaceLabel = curTask ? ("[" + curTask.provider + "] " + curTask.title) : ("选择 Agent 会话 (" + tasks.length + ")");
    taskFace.appendChild(S.node("span", "task-title-text", taskFaceLabel));
    taskFace.appendChild(S.icon("chevron.down", "dropdown-arrow"));
    taskWrap.appendChild(taskFace);
    row4.appendChild(taskWrap);

    if (page.selectedTask && page.selectedTask.canInterrupt === true) {
      row4.appendChild(S.button("中断", "interruptTask", { taskID: page.selectedTask.taskID }, emit, "small danger", false));
    }
    return row4;
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
      page.projectStatus, page.projectStatusTone, detail.provider, detail.status, detail.permissionMode, detail.canInterrupt,
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
