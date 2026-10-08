(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  var Selection = global.CodexBridgeDesktopDSHWorkbenchSelection;
  var storageKey = "codexbridge.dsh.workbench.v1";
  var preferences = { mode: "collaboration", tasks: {}, panels: {} }, view, context, newSession = false, settingsOpen = false, restoreRequested = null, awaitingTaskID = null, restoreProjectID = null, navigationTaskID = null;
  try {
    var stored = JSON.parse(global.localStorage.getItem(storageKey) || "null");
    if (stored) preferences = { mode: stored.mode === "dsh" ? "dsh" : "collaboration", tasks: stored.tasks || {}, panels: stored.panels || {}, draftProjectID: stored.draftProjectID };
  } catch (_) {}

  function persist() {
    try { global.localStorage.setItem(storageKey, JSON.stringify(preferences)); } catch (_) {}
  }
  function receiveNavigation(event) {
    var envelope = event.detail || {}, taskID = envelope.payload && envelope.payload.taskID;
    var outsideWorkbench = context && context.state && context.state.selectedNavigation !== "workbench";
    if (taskID && (envelope.command === "openTask" || envelope.command === "selectTask" && outsideWorkbench)) navigationTaskID = taskID;
  }
  function applyNavigation(page) {
    if (!navigationTaskID || !page || !page.selectedTask || page.selectedTaskID !== navigationTaskID) return;
    preferences.mode = Selection.matches(page.selectedTask, true) ? "dsh" : "collaboration";
    newSession = settingsOpen = false; awaitingTaskID = restoreRequested = navigationTaskID = null;
    delete preferences.draftProjectID; persist(); global.CodexBridgeDesktopWorkbenchHeader.reset();
  }
  function localButton(title, action, style) {
    var button = S.button(title, null, {}, null, style || "small");
    button.addEventListener("click", action);
    return button;
  }
  function remember(page) {
    if (!page || !page.selectedTask) return;
    if (restoreRequested && page.selectedTask.taskID !== restoreRequested) return;
    if (!Selection.matches(page.selectedTask, preferences.mode === "dsh")) return;
    preferences.tasks[preferences.mode] = page.selectedTask.taskID;
    persist();
  }
  function setMode(mode, taskID) {
    if (!context) return;
    remember(context.page);
    preferences.mode = mode; settingsOpen = false; newSession = mode === "dsh" && !taskID && preferences.draftProjectID === context.page.selectedProjectID;
    restoreRequested = null; awaitingTaskID = navigationTaskID = null; persist();
    global.CodexBridgeDesktopWorkbenchHeader.reset();
    var tasks = S.safeArray(context.page && context.page.tasks);
    var wanted = taskID || preferences.tasks[mode];
    var target = !newSession && tasks.find(function (task) {
      return task.taskID === wanted && Selection.matches(task, mode === "dsh");
    });
    if (!target && !newSession) target = tasks.find(function (task) { return Selection.matches(task, mode === "dsh"); });
    if (taskID && mode === "dsh") { newSession = false; delete preferences.draftProjectID; }
    if (target) { preferences.tasks[mode] = target.taskID; persist(); }
    if (target && target.taskID !== context.page.selectedTaskID) {
      restoreRequested = target.taskID;
      context.emit("selectTask", { taskID: target.taskID });
    }
    refresh();
  }
  function refresh() {
    if (!context) return;
    render(context.page, context.emit, context.state, context.shared);
    if (global.CodexBridgeDesktopPages) global.CodexBridgeDesktopPages.measureBrowserViewport(context.emit);
  }
  function startConversation(projectID) {
    newSession = true; awaitingTaskID = navigationTaskID = null; restoreRequested = null; settingsOpen = false;
    preferences.draftProjectID = projectID; persist(); refresh();
    if (view.composer.focus) view.composer.focus();
  }
  function restoreSelection(page, emit, development) {
    if (!page || restoreRequested || navigationTaskID || development && (newSession || awaitingTaskID)
      || Selection.matches(page.selectedTask, development)) return;
    var mode = development ? "dsh" : "collaboration", tasks = S.safeArray(page.tasks);
    var target = tasks.find(function (task) {
      return task.taskID === preferences.tasks[mode] && Selection.matches(task, development);
    }) || tasks.find(function (task) { return Selection.matches(task, development); });
    if (!target) return;
    restoreRequested = target.taskID; emit("selectTask", { taskID: target.taskID });
  }
  function mount() {
    if (view) return;
    view = {};
    var bar = document.getElementById("workbench-mode-bar");
    bar.appendChild(S.node("h2", "workbench-mode-title", "工作台"));
    var modes = S.node("div", "segmented-control");
    view.collaboration = localButton("协作", function () { setMode("collaboration"); }, "segmented-btn");
    view.dsh = localButton("DSH 开发台（beta）", function () { setMode("dsh"); }, "segmented-btn");
    modes.appendChild(view.collaboration); modes.appendChild(view.dsh); bar.appendChild(modes);
    view.root = S.node("div", "dsh-workbench"); view.root.id = "dsh-workbench";
    var sidebar = view.sidebar = S.node("aside", "dsh-session-sidebar"); sidebar.id = "dsh-session-sidebar";
    sidebar.setAttribute("aria-label", "DSH 项目与会话");
    var heading = S.node("div", "dsh-sidebar-heading");
    heading.appendChild(S.node("h3", null, "项目 / 会话"));
    heading.appendChild(localButton("新会话", function () { startConversation(context.page.selectedProjectID); }));
    sidebar.appendChild(heading);
    view.projects = S.node("select", "dsh-project-select"); view.projects.setAttribute("aria-label", "DSH 工作项目");
    view.projects.addEventListener("change", function () {
      newSession = true; awaitingTaskID = null; restoreRequested = null; settingsOpen = false;
      preferences.draftProjectID = view.projects.value; persist();
      context.emit("selectProject", { projectID: view.projects.value });
    });
    sidebar.appendChild(view.projects);
    view.sessions = S.node("nav", "dsh-session-list"); view.sessions.setAttribute("aria-label", "DSH 会话");
    sidebar.appendChild(view.sessions);
    if (global.CodexBridgeDesktopDSHSessions) {
      view.historySearch = global.CodexBridgeDesktopDSHSessions.create();
      sidebar.appendChild(view.historySearch.root);
    }
    sidebar.appendChild(localButton("引擎设置", function () { settingsOpen = true; refresh(); }));
    view.root.appendChild(sidebar);
    view.center = S.node("section", "dsh-conversation-pane"); view.center.setAttribute("aria-label", "DSH 对话");
    view.header = S.node("header", "dsh-conversation-header");
    view.title = S.node("h3"); view.status = S.node("span");
    view.header.appendChild(view.title); view.header.appendChild(view.status);
    view.menu = S.node("details", "dsh-chat-menu");
    var menuToggle = S.node("summary", "dsh-chat-menu-toggle"); menuToggle.setAttribute("aria-label", "会话操作");
    menuToggle.appendChild(S.icon("ellipsis")); view.menu.appendChild(menuToggle);
    view.actions = S.node("div", "dsh-chat-menu-actions"); view.menu.appendChild(view.actions); view.header.appendChild(view.menu);
    view.center.appendChild(view.header);
    view.shared = S.node("div", "dsh-shared-conversation"); view.center.appendChild(view.shared);
    view.composer = global.CodexBridgeDesktopDSHComposer.create(function (taskID) {
      newSession = false; awaitingTaskID = taskID; preferences.tasks.dsh = taskID; delete preferences.draftProjectID; persist();
    });
    view.center.appendChild(view.composer.root);
    view.root.appendChild(view.center);
    if (global.CodexBridgeDesktopDSHWorkspace) {
      view.workspace = global.CodexBridgeDesktopDSHWorkspace.create(function (projectID, path) {
        if (!view.composer.addAttachment(projectID, path)) return false;
        if (!newSession && !filteredPage(context.page).selectedTask) startConversation(projectID);
        return true;
      });
      view.workspace.root.id = "dsh-workspace-pane"; view.root.appendChild(view.workspace.root);
    }
    view.settings = S.node("section", "dsh-engine-settings"); view.settings.id = "dsh-engine-settings";
    var settingsHeader = S.node("header", "dsh-conversation-header");
    settingsHeader.appendChild(localButton("返回对话", function () { settingsOpen = false; refresh(); }));
    view.settings.appendChild(settingsHeader); view.root.appendChild(view.settings);
    document.getElementById("workbench-page").appendChild(view.root);
    view.layout = global.CodexBridgeDesktopDSHWorkbenchLayout.create(view, bar, preferences.panels, function () { persist(); refresh(); });
  }
  function filteredPage(page) {
    var filtered = Selection.project(page, true, newSession, awaitingTaskID || navigationTaskID), selected = filtered.selectedTask;
    if (selected && selected.taskID === awaitingTaskID) awaitingTaskID = null;
    return filtered;
  }
  function updateNavigator(page, emit) {
    global.CodexBridgeDesktopFormDraft.selectOptions(view.projects,
      S.safeArray(page.projects).map(function (project) { return { id: project.id, title: project.title }; }));
    view.projects.value = page.selectedProjectID || "";
    var signature = JSON.stringify([page.selectedTaskID, page.tasks]);
    global.CodexBridgeDesktopStableRender(view.sessions, signature, function () {
      S.clear(view.sessions);
      if (!page.tasks.length) view.sessions.appendChild(S.node("p", "hint", "此项目还没有 DSH 会话。"));
      page.tasks.forEach(function (task) {
        var title = task.title || "DSH 会话";
        var button = localButton("", function () {
          newSession = false; awaitingTaskID = null; settingsOpen = false; preferences.tasks.dsh = task.taskID; delete preferences.draftProjectID; persist();
          restoreRequested = task.taskID;
          emit("selectTask", { taskID: task.taskID }); refresh();
        }, "dsh-session-button" + (task.taskID === page.selectedTaskID ? " is-active" : ""));
        button.title = title; button.setAttribute("aria-label", title);
        button.setAttribute("aria-current", task.taskID === page.selectedTaskID ? "true" : "false");
        button.appendChild(S.node("span", "dsh-session-title", title));
        var metadata = S.node("span", "dsh-session-metadata");
        if (task.source) metadata.appendChild(S.node("span", "dsh-session-source", task.source));
        metadata.appendChild(S.node("span", "dsh-session-status", task.status));
        button.appendChild(metadata);
        view.sessions.appendChild(button);
      });
    });
  }
  function moveConversation(development) {
    var inspector = document.getElementById("workbench-inspector-pane");
    var target = development ? view.shared : document.getElementById("collaboration-workbench");
    if (inspector.parentNode !== target) {
      var active = document.activeElement, focused = active && inspector.contains(active);
      target.appendChild(inspector);
      if (focused) active.focus({ preventScroll: true });
    }
    document.getElementById("workbench-inspector-header").hidden = development;
    document.getElementById("workbench-native-sessions").hidden = development;
  }
  function updateSettings(state, emit) {
    var api = global.CodexBridgeDesktopDSHSettings;
    if (!api) return;
    if (!view.settingsEditor) {
      view.settingsEditor = api.create(emit);
      view.settings.appendChild(view.settingsEditor.root);
    }
    view.settingsEditor.update(state && state.connections, state && state.settings, emit);
    view.settingsEditor.setActive(settingsOpen, emit);
  }
  function render(page, emit, state, shared) {
    context = { page: page, emit: emit, state: state, shared: shared };
    mount();
    applyNavigation(page);
    var projectID = page && page.selectedProjectID;
    if (projectID !== restoreProjectID) {
      restoreProjectID = projectID; restoreRequested = null;
      newSession = preferences.draftProjectID === projectID;
    }
    if (page && page.selectedTaskID === restoreRequested) restoreRequested = null;
    var development = preferences.mode === "dsh";
    document.getElementById("collaboration-workbench").hidden = development;
    view.root.hidden = !development;
    view.collaboration.setAttribute("aria-pressed", String(!development));
    view.dsh.setAttribute("aria-pressed", String(development));
    view.collaboration.classList.toggle("is-active", !development);
    view.dsh.classList.toggle("is-active", development);
    var workspaceActive = view.layout.update(development, settingsOpen);
    moveConversation(development);
    restoreSelection(page, emit, development);
    if (!development) {
      if (view.settingsEditor) view.settingsEditor.setActive(false, emit);
      if (view.workspace) view.workspace.setActive(false, emit);
      var collaboration = Selection.project(page, false, false, navigationTaskID);
      remember(collaboration); shared(collaboration, emit); return;
    }
    var filtered = filteredPage(page);
    Object.defineProperty(filtered, "pendingSubmission", { enumerable: true, get: function () {
      return view.composer.pendingMessage ? view.composer.pendingMessage() : null;
    } });
    filtered.awaitingTaskID = awaitingTaskID || navigationTaskID;
    view.composer.update(filtered, state && state.settings, emit);
    filtered.awaitingTaskID = awaitingTaskID || navigationTaskID;
    remember(filtered);
    updateNavigator(filtered, emit);
    if (view.historySearch) view.historySearch.update(filtered, function (command, payload, requestID) {
      if (command === "selectTaskHistory") {
        newSession = false; awaitingTaskID = null; settingsOpen = false;
        restoreRequested = payload.taskID; preferences.tasks.dsh = payload.taskID; delete preferences.draftProjectID; persist();
      }
      emit(command, payload, requestID);
    });
    if (view.workspace) {
      view.workspace.update(page, emit);
      view.workspace.setActive(workspaceActive, emit);
    }
    if (settingsOpen) updateSettings(state, emit);
    else if (view.settingsEditor) view.settingsEditor.setActive(false, emit);
    view.title.textContent = filtered.selectedTask ? filtered.selectedTask.title
      : awaitingTaskID ? "正在打开会话…" : "新建 DSH 会话";
    view.title.title = view.title.textContent;
    view.header.hidden = !filtered.selectedTask;
    if (filtered.selectedTask) {
      var detail = filtered.selectedTask;
      S.updateStatus(view.status, detail.status, /失败|failed/.test(detail.status || "") ? "error"
        : detail.canStop || detail.canSteer ? "running" : "success");
      if (view.menu.__taskID !== detail.taskID) view.menu.open = false;
      view.menu.__taskID = detail.taskID;
      var row = filtered.tasks.find(function (task) { return task.taskID === detail.taskID; }) || {};
      if (global.CodexBridgeDesktopWorkbenchActions) global.CodexBridgeDesktopWorkbenchActions.render(view.actions, detail, row, emit);
    }
    shared(filtered, emit, true);
    view.composer.root.hidden = false;
  }
  global.CodexBridgeDesktopDSHWorkbench = {
    configure: function (state, emit) {
      context = { page: state && state.workbench, state: state, emit: emit,
        shared: global.CodexBridgeDesktopWorkbenchPage.renderShared };
    },
    render: render, mode: function () { return preferences.mode; }, filteredPage: filteredPage,
    setActive: function (active, emit) {
      if (!active && view && view.settingsEditor) view.settingsEditor.setActive(false, emit);
      if (!active && view && view.workspace) view.workspace.setActive(false, emit);
    },
    openTask: function (taskID) { setMode("dsh", taskID); },
    openSettings: function () {
      if (!context) return;
      navigationTaskID = null;
      preferences.mode = "dsh"; settingsOpen = true; persist();
      context.emit("selectPage", { navigation: "workbench" }); refresh();
    }
  };
  global.addEventListener("codex-bridge-command", receiveNavigation);
}(window));
