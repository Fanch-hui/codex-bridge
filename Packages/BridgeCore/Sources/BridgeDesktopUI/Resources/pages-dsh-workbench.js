(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  var Selection = global.CodexBridgeDesktopDSHWorkbenchSelection;
  var storageKey = "codexbridge.dsh.workbench.v1";
  var preferences = Selection.preferences(), view, context, settingsOpen = false, settingsPurpose = null, settingsCategory = null, restoreRequested = null, restoreProjectID = null, navigationTaskID = null, pendingNewConversation = null, pendingEmbeddedSessionID = null;
  var followedProject = "";
  var settingsIntent = null, navigationTaskRequest = null, sessionOpenRevision = 0, pendingSessionResolution = null;
  var savedOperationsPaused = false;
  try {
    var stored = JSON.parse(global.localStorage.getItem(storageKey) || "null");
    preferences = Selection.preferences(stored);
  } catch (_) {}
  preferences.mode = "dsh";

  function persist() {
    try { global.localStorage.setItem(storageKey, JSON.stringify(preferences)); } catch (_) {}
  }
  function availability(state) {
    if (!state || !state.settings) return { loaded: false, enabled: true, changing: false };
    var settings = state.settings;
    return { loaded: settings.workbenchSettingsLoaded !== false, enabled: settings.workbenchEnabled !== false,
      changing: !!settings.isChangingWorkbench };
  }
  function workbenchAvailable(state) {
    var status = availability(state);
    return status.loaded && status.enabled && !status.changing;
  }
  function setTransportAvailability(state) {
    var transport = global.CodexBridgeDesktopEmbeddedDSHTransport;
    if (transport && transport.setEnabled) transport.setEnabled(workbenchAvailable(state));
    var status = availability(state), embedded = global.CodexBridgeDesktopEmbeddedDSH;
    if (!status.loaded || status.enabled) savedOperationsPaused = false;
    else if (!savedOperationsPaused && (!view || !view.embedded) && embedded && embedded.pauseSavedOperations) {
      embedded.pauseSavedOperations(); savedOperationsPaused = true;
    }
  }
  function receiveNavigation(event) {
    var envelope = event.detail || {}, taskID = envelope.payload && envelope.payload.taskID;
    if (envelope.command === "openWorkbenchSession" && document.documentElement.dataset.surface !== "preferences") {
      receiveEmbeddedSession({ detail: envelope.payload }); return;
    }
    if (envelope.command === "selectPage" && envelope.payload && envelope.payload.navigation !== "workbench") {
      sessionOpenRevision++; pendingEmbeddedSessionID = null; pendingSessionResolution = null;
    }
    var outsideWorkbench = context && context.state && context.state.selectedNavigation !== "workbench";
    if (taskID && (envelope.command === "openTask" || envelope.command === "selectTask" && outsideWorkbench)) navigationTaskID = taskID;
  }
  function receiveEmbeddedSession(event) {
    var detail = event.detail || {};
    if (!detail.sessionID) return;
    var revision = ++sessionOpenRevision;
    preferences.mode = "dsh"; settingsOpen = false; persist();
    global.dispatchEvent(new CustomEvent("codex-bridge-workbench-mode-changed"));
    if (context && context.emit) context.emit("selectPage", { navigation: "workbench" });
    if (context && context.state && context.state.selectedNavigation === "workbench") refresh();
    pendingSessionResolution = { id: detail.sessionID, revision: revision };
    resolvePendingSession();
  }
  function resolvePendingSession() {
    if (!pendingSessionResolution || !context || !workbenchAvailable(context.state)) return;
    var request = pendingSessionResolution, revision = request.revision;
    pendingSessionResolution = null;
    global.CodexBridgeDesktopEmbeddedDSHTransport.call("session.resolve", { sessionId: request.id }).then(function (value) {
      if (revision !== sessionOpenRevision) return;
      if (!value || !value.sessionId) throw new Error("找不到此会话，请刷新后重试。");
      pendingEmbeddedSessionID = value.sessionId;
      if (context && context.state && context.state.selectedNavigation === "workbench") refresh();
    }).catch(function (error) {
      if (revision === sessionOpenRevision && (error.code === "workbench_disabled" || !workbenchAvailable(context && context.state))) {
        pendingSessionResolution = request; resolvePendingSession(); return;
      }
      if (revision === sessionOpenRevision && view && view.embedded) view.embedded.showError(error);
    });
  }
  function applyNavigation(page) {
    if (!navigationTaskID || !page || !page.selectedTask || page.selectedTaskID !== navigationTaskID) return;
    preferences.mode = "collaboration";
    settingsOpen = false; restoreRequested = navigationTaskID = pendingNewConversation = null;
    navigationTaskRequest = null;
    persist(); global.CodexBridgeDesktopWorkbenchHeader.reset();
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
    if (preferences.mode !== "collaboration") return;
    preferences.tasks.collaboration = page.selectedTask.taskID;
    persist();
  }
  function setMode(mode, taskID) {
    if (!context) return;
    sessionOpenRevision++; pendingEmbeddedSessionID = null; pendingSessionResolution = null;
    remember(context.page);
    preferences.mode = mode; settingsOpen = false; settingsPurpose = null;
    global.dispatchEvent(new CustomEvent("codex-bridge-workbench-mode-changed"));
    restoreRequested = null; navigationTaskID = null; navigationTaskRequest = null; persist();
    global.CodexBridgeDesktopWorkbenchHeader.reset();
    var tasks = S.safeArray(context.page && context.page.tasks), target;
    if (mode === "collaboration") {
      var wanted = taskID || preferences.tasks.collaboration;
      target = tasks.find(function (task) { return task.taskID === wanted; });
      if (!target && !taskID) target = tasks[0];
      if (taskID) navigationTaskID = taskID;
      if (target) { preferences.tasks.collaboration = target.taskID; persist(); }
    }
    if (target && target.taskID !== context.page.selectedTaskID) {
      restoreRequested = target.taskID;
      context.emit("selectTask", { taskID: target.taskID });
    } else if (taskID && !target) {
      restoreRequested = taskID;
      context.emit("selectTask", { taskID: taskID });
    }
    refresh();
  }
  function refresh() {
    if (!context) return;
    render(context.page, context.emit, context.state, context.shared);
    if (global.CodexBridgeDesktopPages) global.CodexBridgeDesktopPages.measureBrowserViewport(context.emit);
  }
  function openEmbeddedSettings(purpose) {
    if (!context || !workbenchAvailable(context.state)) return;
    if (purpose === "models" || purpose === "mcp") { settingsCategory = purpose; purpose = null; }
    settingsIntent = purpose && view.embedded ? view.embedded.navigationIdentity() : null;
    settingsPurpose = purpose === "chatgpt-add" ? "chatgpt" : purpose || null;
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
    sessionOpenRevision++; pendingEmbeddedSessionID = null; pendingSessionResolution = null;
    preferences.mode = "collaboration"; settingsOpen = false; settingsPurpose = null;
    restoreRequested = null; persist();
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
  function restoreSelection(page, emit) {
    if (!page || restoreRequested || navigationTaskID || page.selectedTask) return;
    var tasks = S.safeArray(page.tasks);
    var target = tasks.find(function (task) {
      return task.taskID === preferences.tasks.collaboration;
    }) || tasks.find(function (task) { return task.projectID === page.selectedProjectID; }) || tasks[0];
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
    var sessionsHeading = S.node("div", "dsh-sidebar-heading dsh-sessions-heading");
    sessionsHeading.appendChild(S.node("h3", null, "会话"));
    var headingActions = S.node("div", "dsh-sidebar-heading-actions");
    function headingButton(title, symbol, action) {
      var button = localButton("", action, "dsh-session-search-toggle");
      button.appendChild(S.icon(symbol)); button.title = title; button.setAttribute("aria-label", title);
      headingActions.appendChild(button);
      return button;
    }
    view.searchSessions = headingButton("搜索会话", "magnifyingglass", function () { if (view.embedded) view.embedded.toggleSearch(); });
    view.newCollaborationTask = headingButton("新建 Agent 任务", "plus", function () {
      if (global.CodexBridgeDesktopWorkbenchNewTask) global.CodexBridgeDesktopWorkbenchNewTask.open();
    });
    headingButton("选择工作文件夹", "folder.badge.plus", function () { context.emit("registerProject", {}); });
    sessionsHeading.appendChild(headingActions);
    sidebar.appendChild(sessionsHeading);
    view.collaborationSessions = S.node("nav", "dsh-session-list collaboration-session-list");
    view.collaborationSessions.setAttribute("aria-label", "网页工作台会话");
    sidebar.appendChild(view.collaborationSessions);
    navigator.appendChild(sidebar);
    view.center = S.node("section", "dsh-conversation-pane"); view.center.setAttribute("aria-label", "对话");
    view.unavailable = S.node("div", "empty-state dsh-workbench-unavailable");
    view.unavailable.setAttribute("role", "status");
    view.unavailableTitle = S.node("h2"); view.unavailable.appendChild(view.unavailableTitle);
    view.unavailableSettings = localButton("打开设置", function () {
      if (global.CodexBridgeDesktopSettingsPage) {
        global.CodexBridgeDesktopSettingsPage.openDetail("application", context.emit);
      } else {
        context.emit("selectPage", { navigation: "settings", kind: "settings-detail", value: "application" });
      }
    });
    view.unavailable.appendChild(view.unavailableSettings); view.center.appendChild(view.unavailable);
    if (global.CodexBridgeDesktopEmbeddedDSH) {
      view.embedded = global.CodexBridgeDesktopEmbeddedDSH.create(function () {
        sessionOpenRevision++; pendingEmbeddedSessionID = null; pendingSessionResolution = null;
        settingsOpen = false; pendingNewConversation = null; persist(); refresh();
      }, openEmbeddedSettings, openExternalSearchResult, refresh);
      view.center.appendChild(view.embedded.root);
      if (view.embedded.setEventListener) view.embedded.setEventListener(function (item) {
        if (view.embeddedSettings) view.embeddedSettings.receive(item);
        else if (item && (item.type === "auth.changed" || item.type === "models.changed")) {
          if (!view.modelRefreshQueued) {
            view.modelRefreshQueued = true;
            Promise.resolve().then(function () {
              view.modelRefreshQueued = false;
              if (context && workbenchAvailable(context.state)) return view.embedded.refreshModels();
            }).catch(view.embedded.showError);
          }
        }
        if (view.workspace && item && item.sessionID === view.embedded.currentSessionID()) view.workspace.receive(item);
      });
      if (view.embedded.searchRoot) sidebar.appendChild(view.embedded.searchRoot);
      sidebar.appendChild(view.embedded.sidebar);
      toolbarContext.appendChild(view.embedded.toolbarContext);
      toolbarActions.appendChild(view.embedded.toolbarActions);
    }
    view.root.appendChild(view.center);
    if (global.CodexBridgeDesktopDSHWorkspace) {
      view.workspace = global.CodexBridgeDesktopDSHWorkspace.create(function (projectID, path) {
        return !!view.embedded && view.embedded.addAttachment(projectID, path);
      });
      if (view.embedded && view.embedded.subagents && view.workspace.mountSubagents) {
        view.workspace.mountSubagents(view.embedded.subagents);
      }
      if (view.embedded && view.embedded.setSubagentsListener) {
        view.embedded.setSubagentsListener(function (count, added) {
          if (view.workspace && view.workspace.syncSubagents) view.workspace.syncSubagents();
          if (added && view.workspace && view.workspace.selectTab) {
            view.workspace.selectTab("agents");
            if (preferences.panels && preferences.panels.workspaceCollapsed) {
              preferences.panels.workspaceCollapsed = false; persist(); refresh();
            }
          }
        });
      }
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
    var embeddedComposer = view.embedded && view.embedded.root.querySelector(".dsh-native-composer");
    var conversationViewport = view.embedded && view.embedded.root.querySelector(".dsh-bridge-conversation");
    if (!embeddedComposer) return;
    view.composerObserver = new global.ResizeObserver(function () {
      var bounds = embeddedComposer.getBoundingClientRect();
      if (bounds.height <= 0) return;
      var height = Math.ceil(bounds.height);
      view.root.style.setProperty("--dsh-composer-height", height + "px");
      if (conversationViewport) {
        var overlap = conversationViewport.getBoundingClientRect().bottom - bounds.top;
        view.embedded.setBottomInset(Math.max(0, Math.ceil(overlap + 12)));
      }
    });
    view.composerObserver.observe(embeddedComposer);
    if (conversationViewport) view.composerObserver.observe(conversationViewport);
  }
  function closeSettings() {
    settingsOpen = false; settingsPurpose = null; refresh();
    if (view.embedded) view.embedded.focus();
  }
  function updateCollaborationSessions(page, emit) {
    var tasks = S.safeArray(page.tasks), projects = S.safeArray(page.projects), defaultID = S.defaultProjectID(page);
    var signature = JSON.stringify([page.selectedTaskID, tasks, projects, defaultID]);
    global.CodexBridgeDesktopStableRender(view.collaborationSessions, signature, function () {
      S.clear(view.collaborationSessions);
      if (!tasks.length) view.collaborationSessions.appendChild(S.node("p", "hint", "暂无网页工作台会话"));
      function row(task, target) {
        var title = task.title || "Agent 会话", selected = task.taskID === page.selectedTaskID;
        var button = localButton("", function () {
          if (global.CodexBridgeDesktopWorkbenchNewTask) global.CodexBridgeDesktopWorkbenchNewTask.close();
          preferences.tasks.collaboration = task.taskID; persist();
          // The host aligns the viewing project with the session, so the selection stays.
          emit("selectTask", { taskID: task.taskID });
        }, "dsh-session-button" + (selected ? " is-active" : ""));
        button.title = title; button.setAttribute("aria-current", selected ? "true" : "false");
        button.appendChild(S.node("span", "dsh-session-title", title));
        var meta = S.node("span", "dsh-session-metadata");
        meta.appendChild(S.node("span", "dsh-session-source", task.provider || task.providerID || "Agent"));
        var status = task.status && task.status !== "已创建" ? task.status : "";
        if (status) meta.appendChild(S.node("span", "dsh-session-status", status));
        button.appendChild(meta); target.appendChild(button);
      }
      if (!projects.length) { tasks.forEach(function (task) { row(task, view.collaborationSessions); }); return; }
      S.groupByProject(tasks, projects, defaultID, function (task) { return task.projectID; },
        function (task) { return task.projectName; }).forEach(function (group) {
        var rendered = S.projectGroup(group, { scope: "agent", newLabel: "新建 Agent 任务", onNew: function (projectID) {
          if (global.CodexBridgeDesktopWorkbenchNewTask) global.CodexBridgeDesktopWorkbenchNewTask.open({ projectID: projectID });
        } });
        group.rows.forEach(function (task) { row(task, rendered.body); });
        view.collaborationSessions.appendChild(rendered.root);
      });
    });
  }
  function updateSharedVisibility(development) {
    var header = document.getElementById("workbench-inspector-header"), headerModel = header.__inspectorHeader;
    header.hidden = development || !headerModel || headerModel.queue.hidden;
    document.getElementById("workbench-native-sessions").hidden = development;
  }
  function updateSettings() {
    if (view.embedded && global.CodexBridgeDesktopEmbeddedDSHSettings) {
      if (!view.embeddedSettings) {
        view.embeddedSettings = global.CodexBridgeDesktopEmbeddedDSHSettings.create(view.embedded.refreshModels, view.embedded.restart, connectionReady);
        view.settings.appendChild(view.embeddedSettings.root);
      }
      view.embeddedSettings.setSession(view.embedded.currentSessionID());
      view.embeddedSettings.setSetupMode(settingsPurpose);
      if (settingsCategory) { view.embeddedSettings.selectCategory(settingsCategory); settingsCategory = null; }
      view.embeddedSettings.root.hidden = false; view.embeddedSettings.setActive(settingsOpen);
    }
  }
  // The files and changes beside a conversation belong to the project of the conversation on
  // screen, so the viewing project follows it. One request per (conversation, viewing project)
  // pair keeps a host that declines the change from being asked on every render.
  function followViewedProject(page, emit) {
    var wanted = view.embedded.currentProjectID();
    var key = wanted + "\u001f" + (page && page.selectedProjectID || "");
    if (!wanted || !page || wanted === page.selectedProjectID || followedProject === key) return;
    followedProject = key; emit("selectProject", { projectID: wanted });
  }
  function render(page, emit, state, shared) {
    context = { page: page, emit: emit, state: state, shared: shared };
    setTransportAvailability(state);
    if (global.CodexBridgeDesktopWorkbenchNewTask) {
      global.CodexBridgeDesktopWorkbenchNewTask.setSettings(state && state.settings);
      global.CodexBridgeDesktopWorkbenchNewTask.setOnChange(function () {
        if (context) render(context.page, context.emit, context.state, context.shared);
      });
    }
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
    }
    if (page && page.selectedTaskID === restoreRequested) restoreRequested = null;
    var development = preferences.mode === "dsh";
    var status = availability(state), available = workbenchAvailable(state);
    var embedded = development && available && !!view.embedded;
    view.unavailable.hidden = !development || available;
    view.unavailableTitle.textContent = !status.loaded ? "正在读取工作台设置…"
      : status.changing ? (status.enabled ? "正在关闭工作台…" : "正在开启工作台…") : "工作台已关闭";
    view.unavailableSettings.hidden = !status.loaded || status.changing;
    view.searchSessions.hidden = !embedded;
    view.newCollaborationTask.hidden = development;
    document.getElementById("collaboration-workbench").hidden = development;
    view.root.hidden = !development;
    view.collaborationSessions.hidden = development;
    if (view.embedded) {
      view.embedded.sidebar.hidden = !embedded;
      if (view.embedded.searchRoot && !embedded) view.embedded.searchRoot.hidden = true;
      view.embedded.toolbarContext.hidden = !embedded;
      view.embedded.toolbarActions.hidden = !embedded;
    }
    view.settingsButton.hidden = !embedded;
    var workspaceActive = view.layout.update(embedded);
    updateSharedVisibility(development);
    global.CodexBridgeDesktopWorkbenchHeader.setVisible(!development);
    if (!development) restoreSelection(page, emit);
    if (view.embedded) {
      view.embedded.root.hidden = !embedded;
      view.embedded.setNavigationActive(embedded);
      view.embedded.update(page, emit, embedded, available && !!(state && state.serviceConnected),
        status.loaded && !status.enabled);
      if (embedded) resolvePendingSession();
      if (embedded && pendingEmbeddedSessionID) {
        var requestedSession = pendingEmbeddedSessionID; pendingEmbeddedSessionID = null;
        view.embedded.openSession(requestedSession).catch(view.embedded.showError);
      }
      if (embedded && pendingNewConversation) {
        var request = pendingNewConversation; pendingNewConversation = null;
        view.embedded.newSession(request.projectID);
      }
      if (embedded) followViewedProject(page, emit);
    }
    if (!embedded && global.CodexBridgeDesktopStartup) global.CodexBridgeDesktopStartup.update({ status: "ready" });
    if (!development) {
      if (view.embeddedSettings) view.embeddedSettings.setActive(false);
      if (view.workspace) view.workspace.setActive(false, emit);
      var collaboration = Selection.project(page, navigationTaskID || restoreRequested);
      updateCollaborationSessions(collaboration, emit);
      if (view.settings.open) view.settings.close();
      remember(collaboration); shared(collaboration, emit); return;
    }
    if (!available) {
      settingsOpen = false; settingsPurpose = null;
      if (view.settings.open) view.settings.close();
      if (view.embeddedSettings) view.embeddedSettings.setActive(false);
      if (view.workspace) view.workspace.setActive(false, emit);
      return;
    }
    if (view.workspace) {
      if (view.embedded && view.workspace.setSession) view.workspace.setSession(view.embedded.currentSessionID());
      view.workspace.update(page, emit, !(state && state.serviceConnected === false));
      view.workspace.setActive(workspaceActive, emit);
    }
    if (settingsOpen) {
      updateSettings();
      if (!view.settings.open) {
        view.settings.showModal();
        if (settingsPurpose === "api" && view.embeddedSettings) view.embeddedSettings.focusSetup();
      }
    } else {
      if (view.settings.open) view.settings.close();
      if (view.embeddedSettings) view.embeddedSettings.setActive(false);
    }
  }
  global.CodexBridgeDesktopDSHWorkbench = {
    configure: function (state, emit) {
      context = { page: state && state.workbench, state: state, emit: emit,
        shared: global.CodexBridgeDesktopWorkbenchPage.renderShared };
      if (global.CodexBridgeDesktopEmbeddedDSHTransport) {
        setTransportAvailability(state);
        global.CodexBridgeDesktopEmbeddedDSHTransport.configure(emit);
        global.CodexBridgeDesktopEmbeddedDSHTransport.receive(state && state.workbench && state.workbench.embeddedDSHReceipts);
      }
    },
    render: render, mode: function () { return preferences.mode; }, filteredPage: Selection.project,
    setActive: function (active, emit) {
      if (!active && view && view.settings && view.settings.open) {
        settingsOpen = false; settingsPurpose = null; view.settings.close();
      }
      if (!active && view && view.embeddedSettings) view.embeddedSettings.setActive(false);
      if (!active && view && view.embedded) {
        var status = availability(context && context.state);
        view.embedded.update(context && context.page, emit, false,
          workbenchAvailable(context && context.state) && !!(context && context.state && context.state.serviceConnected),
          status.loaded && !status.enabled);
      }
      if (!active && view && view.workspace) view.workspace.setActive(false, emit);
    },
    openTask: function (taskID) { setMode("collaboration", taskID); },
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
      preferences.mode = "dsh"; settingsOpen = false; settingsPurpose = null;
      global.dispatchEvent(new CustomEvent("codex-bridge-workbench-mode-changed"));
      navigationTaskID = restoreRequested = null;
      pendingNewConversation = { projectID: projectID || null }; persist();
      global.CodexBridgeDesktopWorkbenchHeader.reset();
      context.emit("selectPage", { navigation: "workbench" }); refresh();
      return true;
    },
    openSettings: function (category) {
      if (!context || !context.page || !context.emit) return false;
      navigationTaskID = null;
      preferences.mode = "dsh";
      settingsPurpose = null; settingsCategory = category || "models";
      settingsOpen = workbenchAvailable(context.state); persist();
      global.dispatchEvent(new CustomEvent("codex-bridge-workbench-mode-changed"));
      context.emit("selectPage", { navigation: "workbench" });
      if (context.state && context.state.selectedNavigation === "workbench") refresh();
      return true;
    }
  };
  global.addEventListener("codex-bridge-command", receiveNavigation);
  global.addEventListener("codex-bridge-open-workbench-session", receiveEmbeddedSession);
}(window));
