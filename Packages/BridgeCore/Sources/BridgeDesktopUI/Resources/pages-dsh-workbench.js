(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  var Selection = global.CodexBridgeDesktopDSHWorkbenchSelection;
  var storageKey = "codexbridge.dsh.workbench.v1";
  var preferences = { mode: "dsh", source: "embedded", tasks: {}, panels: { workspaceCollapsed: true } }, view, context, newSession = false, settingsOpen = false, settingsPurpose = null, settingsCategory = null, restoreRequested = null, awaitingTaskID = null, restoreProjectID = null, navigationTaskID = null, pendingNewProjectID = null, pendingEmbeddedSessionID = null;
  var settingsIntent = null, navigationTaskRequest = null, sessionOpenRevision = 0;
  try {
    var stored = JSON.parse(global.localStorage.getItem(storageKey) || "null");
    if (stored) preferences = { mode: stored.mode === "dsh" ? "dsh" : "collaboration", source: stored.source === "legacy" ? "legacy" : "embedded", tasks: stored.tasks || {}, panels: Object.assign({ workspaceCollapsed: true }, stored.panels || {}), draftProjectID: stored.draftProjectID };
  } catch (_) {}

  function persist() {
    try { global.localStorage.setItem(storageKey, JSON.stringify(preferences)); } catch (_) {}
  }
  function receiveNavigation(event) {
    var envelope = event.detail || {}, taskID = envelope.payload && envelope.payload.taskID;
    if (envelope.command === "openWorkbenchSession" && document.documentElement.dataset.surface !== "preferences") {
      receiveEmbeddedSession({ detail: envelope.payload }); return;
    }
    if (envelope.command === "selectPage" && envelope.payload && envelope.payload.navigation !== "workbench") {
      sessionOpenRevision++; pendingEmbeddedSessionID = null;
    }
    var outsideWorkbench = context && context.state && context.state.selectedNavigation !== "workbench";
    if (taskID && (envelope.command === "openTask" || envelope.command === "selectTask" && outsideWorkbench)) navigationTaskID = taskID;
  }
  function receiveEmbeddedSession(event) {
    var detail = event.detail || {};
    if (!detail.sessionID) return;
    var revision = ++sessionOpenRevision;
    preferences.mode = "dsh"; preferences.source = "embedded"; settingsOpen = false; persist();
    global.dispatchEvent(new CustomEvent("codex-bridge-workbench-mode-changed"));
    if (context && context.emit) context.emit("selectPage", { navigation: "workbench" });
    if (context && context.state && context.state.selectedNavigation === "workbench") refresh();
    global.CodexBridgeDesktopEmbeddedDSHTransport.call("session.resolve", { sessionId: detail.sessionID }).then(function (value) {
      if (revision !== sessionOpenRevision) return;
      if (!value || !value.sessionId) throw new Error("找不到此会话，请刷新后重试。");
      pendingEmbeddedSessionID = value.sessionId;
      if (context && context.state && context.state.selectedNavigation === "workbench") refresh();
    }).catch(function (error) {
      if (revision === sessionOpenRevision && view && view.embedded) view.embedded.showError(error);
    });
  }
  function applyNavigation(page) {
    if (!navigationTaskID || !page || !page.selectedTask || page.selectedTaskID !== navigationTaskID) return;
    preferences.mode = Selection.matches(page.selectedTask, true) ? "dsh" : "collaboration";
    if (preferences.mode === "dsh") preferences.source = "legacy";
    newSession = settingsOpen = false; awaitingTaskID = restoreRequested = navigationTaskID = pendingNewProjectID = null;
    navigationTaskRequest = null;
    delete preferences.draftProjectID; persist(); global.CodexBridgeDesktopWorkbenchHeader.reset();
    global.dispatchEvent(new CustomEvent("codex-bridge-workbench-mode-changed"));
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
    sessionOpenRevision++; pendingEmbeddedSessionID = null;
    remember(context.page);
    preferences.mode = mode; settingsOpen = false; settingsPurpose = null; newSession = mode === "dsh" && !taskID && preferences.draftProjectID === context.page.selectedProjectID;
    global.dispatchEvent(new CustomEvent("codex-bridge-workbench-mode-changed"));
    if (mode === "dsh" && taskID) preferences.source = "legacy";
    restoreRequested = null; navigationTaskID = null; navigationTaskRequest = null; persist();
    global.CodexBridgeDesktopWorkbenchHeader.reset();
    var tasks = S.safeArray(context.page && context.page.tasks);
    var wanted = taskID || (mode === "dsh" && preferences.source === "embedded" ? null : preferences.tasks[mode]);
    var target = !newSession && tasks.find(function (task) {
      return task.taskID === wanted && Selection.matches(task, mode === "dsh");
    });
    if (!target && !newSession && (mode !== "dsh" || preferences.source === "legacy")) target = tasks.find(function (task) { return Selection.matches(task, mode === "dsh"); });
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
    sessionOpenRevision++; pendingEmbeddedSessionID = null;
    newSession = true; awaitingTaskID = navigationTaskID = pendingNewProjectID = null; restoreRequested = null; settingsOpen = false;
    preferences.source = "embedded";
    preferences.draftProjectID = projectID; persist(); refresh();
    if (view.embedded) view.embedded.newSession(projectID);
    else if (view.composer.focus) view.composer.focus();
  }
  function openEmbeddedSettings(purpose) {
    if (purpose === "models" || purpose === "mcp") { settingsCategory = purpose; purpose = null; }
    settingsIntent = purpose && view.embedded ? view.embedded.navigationIdentity() : null;
    preferences.source = "embedded"; settingsPurpose = purpose === "chatgpt-add" ? "chatgpt" : purpose || null;
    settingsOpen = true; persist(); refresh();
    if (purpose === "chatgpt" && view.embeddedSettings) view.embeddedSettings.beginLogin();
    if (purpose === "chatgpt-add" && view.embeddedSettings) view.embeddedSettings.beginAddAccount();
  }
  function connectionReady(kind, providerID) {
    if (!settingsOpen || settingsPurpose !== kind) return;
    if (settingsIntent && view.embedded && settingsIntent !== view.embedded.navigationIdentity()) return;
    if (view.embedded) view.embedded.selectProvider(providerID);
    settingsOpen = false; settingsPurpose = null; settingsIntent = null; refresh();
    if (view.embedded) view.embedded.focus();
  }
  function openExternalSearchResult(item) {
    if (!context || !context.emit) return;
    sessionOpenRevision++; pendingEmbeddedSessionID = null;
    preferences.mode = "collaboration"; settingsOpen = false; settingsPurpose = null;
    newSession = false; awaitingTaskID = null; restoreRequested = null; persist();
    global.dispatchEvent(new CustomEvent("codex-bridge-workbench-mode-changed"));
    if (item.source === "agent" && item.projectID && item.projectID !== context.page.selectedProjectID) {
      context.emit("selectProject", { projectID: item.projectID });
    }
    if (item.source === "bridge" && item.taskID) {
      navigationTaskID = item.taskID;
      navigationTaskRequest = { taskID: item.taskID, requestID: global.CodexBridgeDesktopEmbeddedDSHTransport.requestID() };
      var anchor = item.matchAnchor || {}, messageID = anchor.messageID;
      if (global.CodexBridgeDesktopWorkbenchConversation && global.CodexBridgeDesktopWorkbenchConversation.reveal) {
        global.CodexBridgeDesktopWorkbenchConversation.reveal(item.taskID, anchor.messageKey);
      }
      context.emit("selectTaskHistory", { taskID: item.taskID,
        messageKey: anchor.messageKey || undefined, value: messageID == null ? undefined : String(messageID) }, navigationTaskRequest.requestID);
    } else if (item.source === "agent" && global.CodexBridgeDesktopTaskHistorySearch) {
      global.CodexBridgeDesktopTaskHistorySearch.openNative({ projectID: item.projectID,
        installationID: item.installationID, nativeSessionID: item.nativeSessionID, matchAnchor: item.matchAnchor }, context.emit);
    }
    refresh();
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
    var navigator = document.getElementById("workspace-navigator");
    var toolbarContext = document.getElementById("workspace-toolbar-context");
    var toolbarActions = document.getElementById("workspace-toolbar-actions");
    view.root = S.node("div", "dsh-workbench"); view.root.id = "dsh-workbench";
    var sidebar = view.sidebar = S.node("aside", "dsh-session-sidebar"); sidebar.id = "dsh-session-sidebar";
    sidebar.setAttribute("aria-label", "项目与会话");
    var heading = S.node("div", "dsh-sidebar-heading");
    heading.appendChild(S.node("h3", null, "工作项目"));
    sidebar.appendChild(heading);
    view.projects = S.node("select", "dsh-project-select"); view.projects.setAttribute("aria-label", "工作项目");
    view.projects.addEventListener("change", function () {
      if (preferences.mode === "dsh" && preferences.source === "embedded" && view.embedded && view.embedded.currentSessionID()) {
        context.emit("selectProject", { projectID: view.projects.value }); return;
      }
      newSession = true; awaitingTaskID = null; restoreRequested = null; settingsOpen = false;
      pendingNewProjectID = null;
      if (preferences.mode === "dsh") {
        preferences.source = "embedded";
        preferences.draftProjectID = view.projects.value;
      }
      persist(); context.emit("selectProject", { projectID: view.projects.value });
    });
    var projectRow = S.node("div", "dsh-project-row"), addProject = localButton("", function () {
      context.emit("registerProject", {});
    }, "dsh-add-project");
    addProject.appendChild(S.icon("plus")); addProject.title = "选择工作文件夹";
    addProject.setAttribute("aria-label", addProject.title);
    projectRow.appendChild(view.projects); projectRow.appendChild(addProject); sidebar.appendChild(projectRow);
    var sessionsHeading = S.node("div", "dsh-sidebar-heading dsh-sessions-heading");
    sessionsHeading.appendChild(S.node("h3", null, "会话"));
    view.searchSessions = localButton("", function () { if (view.embedded) view.embedded.toggleSearch(); }, "dsh-session-search-toggle");
    view.searchSessions.appendChild(S.icon("magnifyingglass"));
    view.searchSessions.title = "搜索会话"; view.searchSessions.setAttribute("aria-label", "搜索会话");
    sessionsHeading.appendChild(view.searchSessions);
    sidebar.appendChild(sessionsHeading);
    view.collaborationSessions = S.node("nav", "dsh-session-list collaboration-session-list");
    view.collaborationSessions.setAttribute("aria-label", "网页工作台会话");
    sidebar.appendChild(view.collaborationSessions);
    view.legacySessions = S.node("details", "dsh-legacy-sessions");
    view.legacySessions.appendChild(S.node("summary", null, "历史 ACP 会话"));
    view.sessions = S.node("nav", "dsh-session-list"); view.sessions.setAttribute("aria-label", "历史 ACP 会话");
    view.legacySessions.appendChild(view.sessions);
    view.legacySessions.appendChild(localButton("ACP 设置", function () {
      preferences.source = "legacy"; settingsOpen = true; persist(); refresh();
    }));
    if (global.CodexBridgeDesktopDSHSessions) {
      view.historySearch = global.CodexBridgeDesktopDSHSessions.create();
      view.legacySessions.appendChild(view.historySearch.root);
    }
    sidebar.appendChild(view.legacySessions);
    navigator.appendChild(sidebar);
    view.center = S.node("section", "dsh-conversation-pane"); view.center.setAttribute("aria-label", "对话");
    view.header = S.node("div", "dsh-toolbar-context");
    view.title = S.node("span", "dsh-toolbar-title"); view.status = S.node("span");
    view.header.appendChild(view.title); view.header.appendChild(view.status); toolbarContext.appendChild(view.header);
    view.actions = S.node("div", "workbench-task-actions dsh-toolbar-actions"); toolbarActions.appendChild(view.actions);
    view.shared = S.node("div", "dsh-shared-conversation"); view.center.appendChild(view.shared);
    view.composer = global.CodexBridgeDesktopDSHComposer.create(function (taskID) {
      newSession = false; awaitingTaskID = taskID; preferences.tasks.dsh = taskID; delete preferences.draftProjectID; persist();
    });
    view.center.appendChild(view.composer.root);
    if (global.CodexBridgeDesktopEmbeddedDSH) {
      view.embedded = global.CodexBridgeDesktopEmbeddedDSH.create(function () {
        sessionOpenRevision++; pendingEmbeddedSessionID = null;
        preferences.source = "embedded"; newSession = false; settingsOpen = false; pendingNewProjectID = null; persist(); refresh();
      }, openEmbeddedSettings, openExternalSearchResult);
      view.center.appendChild(view.embedded.root);
      if (view.embedded.searchRoot) sidebar.insertBefore(view.embedded.searchRoot, view.legacySessions);
      sidebar.insertBefore(view.embedded.sidebar, view.legacySessions);
      toolbarContext.appendChild(view.embedded.toolbarContext);
      toolbarActions.appendChild(view.embedded.toolbarActions);
    } else preferences.source = "legacy";
    view.root.appendChild(view.center);
    if (global.CodexBridgeDesktopDSHWorkspace) {
      view.workspace = global.CodexBridgeDesktopDSHWorkspace.create(function (projectID, path) {
        if (preferences.source === "embedded" && view.embedded) return view.embedded.addAttachment(projectID, path);
        if (!view.composer.addAttachment(projectID, path)) return false;
        if (!newSession && !filteredPage(context.page).selectedTask) startConversation(projectID);
        return true;
      });
      view.workspace.root.id = "dsh-workspace-pane"; view.root.appendChild(view.workspace.root);
    }
    view.settings = S.node("dialog", "dsh-engine-settings"); view.settings.id = "dsh-engine-settings";
    view.settings.setAttribute("aria-labelledby", "dsh-settings-title");
    var settingsHeader = S.node("header", "dsh-settings-header");
    var settingsTitle = S.node("h2", null, "工作台设置"); settingsTitle.id = "dsh-settings-title";
    settingsHeader.appendChild(settingsTitle);
    settingsHeader.appendChild(localButton("完成", closeSettings));
    view.settings.appendChild(settingsHeader); view.root.appendChild(view.settings);
    view.settings.addEventListener("cancel", function (event) { event.preventDefault(); closeSettings(); });
    view.settings.addEventListener("close", function () {
      if (settingsOpen) { settingsOpen = false; settingsPurpose = null; refresh(); }
    });
    view.settingsButton = localButton("", function () {
      settingsPurpose = null; settingsOpen = true; refresh();
    }, "dsh-pane-toggle");
    view.settingsButton.appendChild(S.icon("gearshape")); view.settingsButton.title = "工作台设置";
    view.settingsButton.setAttribute("aria-label", view.settingsButton.title); toolbarActions.appendChild(view.settingsButton);
    document.getElementById("workbench-page").appendChild(view.root);
    view.layout = global.CodexBridgeDesktopDSHWorkbenchLayout.create(view, toolbarActions, preferences.panels, function () { persist(); refresh(); });
    observeComposerHeight();
  }
  function observeComposerHeight() {
    if (typeof global.ResizeObserver !== "function") return;
    var composers = [view.composer.root];
    var embeddedComposer = view.embedded && view.embedded.root.querySelector(".dsh-native-composer");
    var conversationViewport = view.embedded && view.embedded.root.querySelector(".dsh-bridge-conversation");
    if (embeddedComposer) composers.push(embeddedComposer);
    view.composerObserver = new global.ResizeObserver(function () {
      var visible = composers.find(function (element) { return element.getBoundingClientRect().height > 0; });
      if (!visible) return;
      var height = Math.ceil(visible.getBoundingClientRect().height);
      view.root.style.setProperty("--dsh-composer-height", height + "px");
      if (view.embedded && visible === embeddedComposer && conversationViewport) {
        var overlap = conversationViewport.getBoundingClientRect().bottom - visible.getBoundingClientRect().top;
        view.embedded.setBottomInset(Math.max(0, Math.ceil(overlap + 12)));
      }
    });
    composers.forEach(function (composer) { view.composerObserver.observe(composer); });
    if (conversationViewport) view.composerObserver.observe(conversationViewport);
  }
  function closeSettings() {
    settingsOpen = false; settingsPurpose = null; refresh();
    if (view.embedded && preferences.source === "embedded") view.embedded.focus();
  }
  function filteredPage(page) {
    var filtered = Selection.project(page, true, newSession, awaitingTaskID || navigationTaskID), selected = filtered.selectedTask;
    if (selected && selected.taskID === awaitingTaskID) awaitingTaskID = null;
    return filtered;
  }
  function updateProjectPicker(page) {
    global.CodexBridgeDesktopFormDraft.selectOptions(view.projects,
      S.safeArray(page.projects).map(function (project) { return { id: project.id, title: project.title }; }));
    view.projects.hidden = !S.safeArray(page.projects).length;
    view.projects.value = page.selectedProjectID || "";
  }
  function updateNavigator(page, emit) {
    updateProjectPicker(page);
    var signature = JSON.stringify([page.selectedTaskID, page.tasks, preferences.source]);
    global.CodexBridgeDesktopStableRender(view.sessions, signature, function () {
      S.clear(view.sessions);
      if (!page.tasks.length) view.sessions.appendChild(S.node("p", "hint", "此项目还没有历史 ACP 会话。"));
      page.tasks.forEach(function (task) {
        var title = task.title || "ACP 会话";
        var button = localButton("", function () {
          preferences.source = "legacy";
          newSession = false; awaitingTaskID = null; settingsOpen = false; preferences.tasks.dsh = task.taskID; delete preferences.draftProjectID; persist();
          restoreRequested = task.taskID;
          emit("selectTask", { taskID: task.taskID }); refresh();
        }, "dsh-session-button" + (preferences.source === "legacy" && task.taskID === page.selectedTaskID ? " is-active" : ""));
        button.title = title; button.setAttribute("aria-label", title);
        button.setAttribute("aria-current", preferences.source === "legacy" && task.taskID === page.selectedTaskID ? "true" : "false");
        button.appendChild(S.node("span", "dsh-session-title", title));
        var metadata = S.node("span", "dsh-session-metadata");
        if (task.source) metadata.appendChild(S.node("span", "dsh-session-source", task.source));
        metadata.appendChild(S.node("span", "dsh-session-status", task.status));
        button.appendChild(metadata);
        view.sessions.appendChild(button);
      });
    });
  }
  function updateCollaborationSessions(page, emit) {
    var tasks = S.safeArray(page.tasks), signature = JSON.stringify([page.selectedTaskID, tasks]);
    global.CodexBridgeDesktopStableRender(view.collaborationSessions, signature, function () {
      S.clear(view.collaborationSessions);
      if (!tasks.length) view.collaborationSessions.appendChild(S.node("p", "hint", "暂无网页工作台会话"));
      tasks.forEach(function (task) {
        var title = task.title || "Agent 会话", selected = task.taskID === page.selectedTaskID;
        var button = localButton("", function () {
          preferences.tasks.collaboration = task.taskID; persist();
          emit("selectTask", { taskID: task.taskID });
        }, "dsh-session-button" + (selected ? " is-active" : ""));
        button.title = title; button.setAttribute("aria-current", selected ? "true" : "false");
        button.appendChild(S.node("span", "dsh-session-title", title));
        var meta = S.node("span", "dsh-session-metadata");
        meta.appendChild(S.node("span", "dsh-session-source", task.provider || task.providerID || "Agent"));
        meta.appendChild(S.node("span", "dsh-session-status", task.status || ""));
        button.appendChild(meta); view.collaborationSessions.appendChild(button);
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
    var header = document.getElementById("workbench-inspector-header"), headerModel = header.__inspectorHeader;
    header.hidden = development || !headerModel || headerModel.queue.hidden;
    document.getElementById("workbench-native-sessions").hidden = development;
  }
  function updateSettings(state, emit) {
    if (preferences.source === "embedded" && view.embedded && global.CodexBridgeDesktopEmbeddedDSHSettings) {
      if (!view.embeddedSettings) {
        view.embeddedSettings = global.CodexBridgeDesktopEmbeddedDSHSettings.create(view.embedded.refreshModels, view.embedded.restart, connectionReady);
        view.settings.appendChild(view.embeddedSettings.root);
        view.embedded.setEventListener(view.embeddedSettings.receive);
      }
      view.embeddedSettings.setSession(view.embedded.currentSessionID());
      view.embeddedSettings.setSetupMode(settingsPurpose);
      if (settingsCategory) { view.embeddedSettings.selectCategory(settingsCategory); settingsCategory = null; }
      view.embeddedSettings.root.hidden = false; view.embeddedSettings.setActive(settingsOpen);
      if (view.settingsEditor) { view.settingsEditor.root.hidden = true; view.settingsEditor.setActive(false, emit); }
      return;
    }
    if (view.embeddedSettings) { view.embeddedSettings.root.hidden = true; view.embeddedSettings.setActive(false); }
    var api = global.CodexBridgeDesktopDSHSettings;
    if (!api) return;
    if (!view.settingsEditor) {
      view.settingsEditor = api.create(emit);
      view.settings.appendChild(view.settingsEditor.root);
    }
    view.settingsEditor.root.hidden = false;
    view.settingsEditor.update(state && state.connections, state && state.settings, emit);
    view.settingsEditor.setActive(settingsOpen, emit);
  }
  function render(page, emit, state, shared) {
    context = { page: page, emit: emit, state: state, shared: shared };
    mount();
    var receipt = page && page.commandReceipt;
    if (navigationTaskRequest && receipt && receipt.command === "selectTaskHistory"
      && receipt.requestID === navigationTaskRequest.requestID && receipt.taskID === navigationTaskRequest.taskID
      && receipt.accepted === false) {
      if (navigationTaskID === navigationTaskRequest.taskID) navigationTaskID = null;
      navigationTaskRequest = null;
    }
    applyNavigation(page);
    var projectID = page && page.selectedProjectID;
    if (projectID !== restoreProjectID) {
      restoreProjectID = projectID; restoreRequested = null;
      newSession = preferences.draftProjectID === projectID;
    }
    if (page && page.selectedTaskID === restoreRequested) restoreRequested = null;
    var development = preferences.mode === "dsh";
    var embedded = development && preferences.source === "embedded" && !!view.embedded;
    view.searchSessions.hidden = !embedded;
    document.getElementById("collaboration-workbench").hidden = development;
    view.root.hidden = !development;
    view.collaborationSessions.hidden = development;
    view.legacySessions.hidden = !development;
    if (view.embedded) {
      view.embedded.sidebar.hidden = !development;
      if (view.embedded.searchRoot && !embedded) view.embedded.searchRoot.hidden = true;
      view.embedded.toolbarContext.hidden = !embedded;
      view.embedded.toolbarActions.hidden = !embedded;
    }
    view.header.hidden = !development || embedded;
    view.actions.hidden = !development || embedded;
    view.settingsButton.hidden = !development;
    var workspaceActive = view.layout.update(development);
    moveConversation(development);
    global.CodexBridgeDesktopWorkbenchHeader.setVisible(!development);
    if (development && !embedded && awaitingTaskID && !restoreRequested
      && page.selectedTaskID !== awaitingTaskID
      && S.safeArray(page.tasks).some(function (task) { return task.taskID === awaitingTaskID; })) {
      restoreRequested = awaitingTaskID; emit("selectTask", { taskID: awaitingTaskID });
    }
    if (!embedded) restoreSelection(page, emit, development);
    if (view.embedded) {
      view.embedded.root.hidden = !embedded;
      view.embedded.setNavigationActive(embedded);
      view.embedded.update(page, emit, embedded, !!(state && state.serviceConnected));
      if (embedded && pendingEmbeddedSessionID) {
        var requestedSession = pendingEmbeddedSessionID; pendingEmbeddedSessionID = null;
        view.embedded.openSession(requestedSession).catch(view.embedded.showError);
      }
      if (embedded && pendingNewProjectID && projectID === pendingNewProjectID) {
        pendingNewProjectID = null; view.embedded.newSession(projectID);
      }
    }
    if (!embedded && global.CodexBridgeDesktopStartup) global.CodexBridgeDesktopStartup.update({ status: "ready" });
    if (!development) {
      if (view.settingsEditor) view.settingsEditor.setActive(false, emit);
      if (view.embeddedSettings) view.embeddedSettings.setActive(false);
      if (view.workspace) view.workspace.setActive(false, emit);
      var collaboration = Selection.project(page, false, false, navigationTaskID);
      updateProjectPicker(collaboration);
      updateCollaborationSessions(collaboration, emit);
      if (view.settings.open) view.settings.close();
      remember(collaboration); shared(collaboration, emit); return;
    }
    var filtered = filteredPage(page);
    Object.defineProperty(filtered, "pendingSubmission", { enumerable: true, get: function () {
      return view.composer.pendingMessage ? view.composer.pendingMessage() : null;
    } });
    filtered.awaitingTaskID = awaitingTaskID || navigationTaskID;
    if (!embedded) view.composer.update(filtered, state && state.settings, emit);
    filtered.awaitingTaskID = awaitingTaskID || navigationTaskID;
    remember(filtered);
    updateNavigator(filtered, emit);
    if (view.historySearch) view.historySearch.update(filtered, function (command, payload, requestID) {
      if (command === "selectTaskHistory") {
        preferences.source = "legacy";
        newSession = false; awaitingTaskID = null; settingsOpen = false;
        restoreRequested = payload.taskID; preferences.tasks.dsh = payload.taskID; delete preferences.draftProjectID; persist();
      }
      emit(command, payload, requestID);
    });
    if (view.workspace) {
      view.workspace.update(page, emit);
      view.workspace.setActive(workspaceActive, emit);
    }
    if (settingsOpen) {
      updateSettings(state, emit);
      if (!view.settings.open) {
        view.settings.showModal();
        if (settingsPurpose === "api" && view.embeddedSettings) view.embeddedSettings.focusSetup();
      }
    } else {
      if (view.settings.open) view.settings.close();
      if (view.settingsEditor) view.settingsEditor.setActive(false, emit);
      if (view.embeddedSettings) view.embeddedSettings.setActive(false);
    }
    view.shared.hidden = embedded; view.composer.root.hidden = embedded;
    if (embedded) { view.header.hidden = true; return; }
    view.title.textContent = filtered.selectedTask ? filtered.selectedTask.title
      : awaitingTaskID ? "正在打开会话…" : "新建会话";
    view.title.title = view.title.textContent;
    view.header.hidden = !filtered.selectedTask;
    view.actions.hidden = !filtered.selectedTask;
    if (filtered.selectedTask) {
      var detail = filtered.selectedTask;
      S.updateStatus(view.status, detail.status, /失败|failed/.test(detail.status || "") ? "error"
        : detail.canStop || detail.canSteer ? "running" : "success");
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
      if (global.CodexBridgeDesktopEmbeddedDSHTransport) {
        global.CodexBridgeDesktopEmbeddedDSHTransport.configure(emit);
        global.CodexBridgeDesktopEmbeddedDSHTransport.receive(state && state.workbench && state.workbench.embeddedDSHReceipts);
      }
    },
    render: render, mode: function () { return preferences.mode; }, filteredPage: filteredPage,
    setActive: function (active, emit) {
      if (!active && view && view.settings && view.settings.open) {
        settingsOpen = false; settingsPurpose = null; view.settings.close();
      }
      if (!active && view && view.settingsEditor) view.settingsEditor.setActive(false, emit);
      if (!active && view && view.embeddedSettings) view.embeddedSettings.setActive(false);
      if (!active && view && view.embedded) view.embedded.update(context && context.page, emit, false,
        !!(context && context.state && context.state.serviceConnected));
      if (!active && view && view.workspace) view.workspace.setActive(false, emit);
    },
    openTask: function (taskID) { setMode("dsh", taskID); },
    showDevelopment: function () {
      if (!context || !context.page || !context.emit) return false;
      if (preferences.mode !== "dsh") setMode("dsh");
      context.emit("selectPage", { navigation: "workbench" });
      return true;
    },
    openCollaboration: function () {
      if (!context || !context.page || !context.emit) return false;
      if (preferences.mode !== "collaboration") setMode("collaboration");
      context.emit("selectPage", { navigation: "workbench" });
      return true;
    },
    openConversation: function (projectID) {
      if (!context || !context.page || !context.emit) return false;
      var current = context.page && context.page.selectedProjectID;
      preferences.mode = "dsh"; preferences.source = "embedded"; settingsOpen = false; settingsPurpose = null;
      global.dispatchEvent(new CustomEvent("codex-bridge-workbench-mode-changed"));
      newSession = true; awaitingTaskID = navigationTaskID = restoreRequested = null;
      pendingNewProjectID = projectID || current || null;
      preferences.draftProjectID = pendingNewProjectID; persist();
      global.CodexBridgeDesktopWorkbenchHeader.reset();
      if (projectID && projectID !== current) context.emit("selectProject", { projectID: projectID });
      context.emit("selectPage", { navigation: "workbench" }); refresh();
      if (!pendingNewProjectID && view && view.embedded) view.embedded.newSession(null);
      return true;
    },
    openSettings: function (category) {
      if (!context || !context.page || !context.emit) return false;
      navigationTaskID = null;
      preferences.mode = "dsh"; preferences.source = "embedded";
      settingsPurpose = null; settingsCategory = category || "models"; settingsOpen = true; persist();
      global.dispatchEvent(new CustomEvent("codex-bridge-workbench-mode-changed"));
      context.emit("selectPage", { navigation: "workbench" });
      if (context.state && context.state.selectedNavigation === "workbench") refresh();
      return true;
    }
  };
  global.addEventListener("codex-bridge-command", receiveNavigation);
  global.addEventListener("codex-bridge-open-workbench-session", receiveEmbeddedSession);
}(window));
