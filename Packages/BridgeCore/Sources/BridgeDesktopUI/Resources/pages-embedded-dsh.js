(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport, D = global.CodexBridgeDesktopFormDraft;
  var T = global.CodexBridgeDesktopEmbeddedDSHTransport, P = global.CodexBridgeDesktopEmbeddedDSHProjection;
  var M = global.CodexBridgeDesktopEmbeddedDSHModels;
  var O = global.CodexBridgeDesktopEmbeddedDSHOperations;
  var key = "codexbridge.dsh.embedded.v1";
  var startupSequence = 0;
  function readState() {
    try { return JSON.parse(global.localStorage.getItem(key) || "null") || {}; } catch (_) { return {}; }
  }
  function create(onSelect, openSettings, openExternalResult) {
    var startupScope = ++startupSequence;
    var saved = readState(), page = {}, emit = null, active = false, serviceConnected = false, connected = false, engineFailed = false;
    var serviceGeneration = 0;
    var models = [], catalogFailures = [], selected = saved.selected || {}, drafts = saved.drafts || {};
    var modelsLoaded = false, modelRequest = 0, modelRefresh = null, catalogDefault = null, defaultRevision = 0;
    var auth = { authenticated: false, signingIn: false }, authRevision = 0, authKnown = false;
    var sessionID = null, projectID = null, pending = null, running = false, projectInitialized = false;
    var jobs = O.create(saved), inFlight = new Set();
    var workspaceRequests = global.CodexBridgeDesktopEmbeddedDSHWorkspaceRequests.create(saved.workspaceBindIDs, T.requestID, persist);
    var bindingSessions = new Set();
    var restoredPending = jobs.list().length > 0;
    var cursor = 0, generation = 0, loading = false, started = false;
    var pollTimer = null, synchronizationMessage = "正在同步会话状态…";
    var eventListener = null, sessionNavigation = 0, pendingOpenSession = null;
    var startupFinished = false, startupFailures = {}, startupModelsSettled = false, startupPermissionsSettled = false;
    var startupReads = {};
    var restarting = false, chatModelRefresh = null, commandPreparing = false;
    var message = "", attachmentPaths = [], attachmentRefs = [], attachmentItems = [], attachmentError = "";
    var attachmentDraft = null, attachmentView = null, attachmentScope = "";
    var composing = false, deferredUpdate = null;
    var navigationActive = true, navigationRevision = 0, pendingOrigin = null;
    var root = S.node("section", "dsh-embedded-root");
    var directory = global.CodexBridgeDesktopEmbeddedDSHSessionDirectory.create(P.navigationIndex(saved.sessions, selected), {
      generation: function () { return generation; }, connected: function () { return connected; },
      active: function () { return active; }, pending: function () { return jobs.list(); },
      onSelect: function (id) { select(id); if (onSelect) onSelect(); },
      onChange: function () {
        delete startupFailures.sessions;
        var selectedSession = directory.get(sessionID);
        if (selectedSession) running = !!selectedSession.running;
        persist(); render();
      },
      onError: function (error) { startupFailure("sessions", error); render(); }
    });
    var history = global.CodexBridgeDesktopEmbeddedDSHHistoryController.create({
      createHistory: global.CodexBridgeDesktopEmbeddedDSHHistory.create, transport: T,
      generation: function () { return generation; }, connected: function () { return connected; },
      onLoaded: function (value, previousFailure) {
        delete startupFailures.history;
        if (message === previousFailure || message === "正在重新加载对话…") message = "";
        if (restoringSelection) {
          var selection = value && value.modelSelection;
          chosenModel = selection && selection.provider && selection.model ? JSON.stringify([selection.provider, selection.model]) : "";
          chosenEffort = selection && selection.reasoningEffort || ""; chosenExplicit = !!chosenModel;
          restoringSelection = false; updateModels(); saveDraft();
        }
        if (pending && restoredPending && pending.phase !== "prompt" && !pending.error) sendPending(pending);
      },
      onChange: render, onError: showError,
      onReadFailure: function (error) { if (active) { startupFailure("history", error); render(); } }
    });
    var sidebar = directory.root;
    var toolbarContext = S.node("div", "dsh-toolbar-context");
    var toolbarActions = S.node("div", "dsh-toolbar-actions");
    var stop = S.button("停止", null, {}, null, "small");
    var restart = S.button("重启引擎", null, {}, null, "small");
    var reconnect = S.button("使用 ChatGPT 登录", null, {}, null, "small");
    var customAPI = S.button("连接自定义 API", null, {}, null, "small");
    var cancelLogin = S.button("取消登录", null, {}, null, "small");
    [reconnect, customAPI, cancelLogin, restart, stop].forEach(function (item) { toolbarActions.appendChild(item); });
    var welcome = global.CodexBridgeDesktopEmbeddedDSHWelcome.create({
      openSettings: function (kind) { if (openSettings) openSettings(kind); },
      chooseProject: function () { if (emit) emit("registerProject", {}); },
      cancelLogin: function () { T.call("auth.cancel", {}).catch(showError); },
      retryModels: refreshChatModels
    });
    root.appendChild(welcome.root);
    var conversation = global.CodexBridgeDesktopEmbeddedDSHConversation.create();
    var search = global.CodexBridgeDesktopEmbeddedDSHSearch && global.CodexBridgeDesktopEmbeddedDSHSearch.create(function (item) {
      if (!item.source || item.source === "workbench") {
        var seq = item.matchAnchor && item.matchAnchor.seq != null ? item.matchAnchor.seq : item.seq;
        openSessionAt(item.sessionId, seq); return;
      }
      if (openExternalResult) openExternalResult(item);
    });
    var actions = global.CodexBridgeDesktopEmbeddedDSHActions.create({
      openSettings: openSettings, getSessionTitle: function (id) {
        return directory.label(id);
      }, onSessionsChanged: function () { return Promise.all([listSessions(), loadHistory()]); }, onOpenSession: openSession,
      ensureCommandSession: ensureCommandSession, onCommandStatus: function (id, value) {
        if (id === sessionID) { message = value; render(); }
      }, onError: showError
    });
    root.appendChild(conversation.root); root.appendChild(actions.root); toolbarActions.appendChild(actions.menu);
    var subagents = S.node("div", "dsh-embedded-subagents"); root.appendChild(subagents);
    var interaction = S.node("div", "dsh-embedded-interaction"); root.appendChild(interaction);
    var interactions = global.CodexBridgeDesktopEmbeddedDSHInteractions.create(interaction, subagents, showError);
    var workspacePrompt = S.node("section", "dsh-embedded-request dsh-workspace-request");
    var workspacePromptText = S.node("span", null, "选择工作文件夹以继续。");
    var workspaceButton = S.button("选择文件夹", null, {}, null, "small");
    workspacePrompt.appendChild(workspacePromptText); workspacePrompt.appendChild(workspaceButton);
    workspacePrompt.hidden = true; root.appendChild(workspacePrompt);
    var view = global.CodexBridgeDesktopDSHComposerView.create({ detachedFeedback: true });
    root.appendChild(view.root);
    var queue = global.CodexBridgeDesktopEmbeddedDSHQueue.create(); view.queueSlot.appendChild(queue.root);
    var mentions = global.CodexBridgeDesktopEmbeddedDSHMentions && global.CodexBridgeDesktopEmbeddedDSHMentions.create(
      view.input, root, function () { return { sessionID: sessionID, projectID: projectID, connected: connected }; },
      function () { saveDraft(); S.autoGrowTextArea(view.input); validate(); });
    view.input.id = "dsh-embedded-session-input";
    view.input.parentNode.querySelector("label").htmlFor = view.input.id;
    view.modeWrapper.hidden = true; view.effortWrapper.hidden = true;
    var permissionState = { selected: "", draftPreset: "", choices: [], ready: false, loading: false, writing: false, error: "" };
    var permissions = global.CodexBridgeDesktopEmbeddedDSHPermissions.create(T, function (state) {
      permissionState = state; updatePermissions();
    });
    var modelChoices = [];
    var options = [{ id: "queue", title: "结束后发送" }, { id: "steer", title: "立即插入" }];
    D.selectOptions(view.mode, options, false); view.mode.value = "queue";
    var chosenModel = "", chosenEffort = "", chosenExplicit = false, restoringSelection = false, draftSelectionEdited = false;
    var recovery = O.createRecovery({ transport: T, jobs: jobs, inFlight: inFlight, importLegacy: submitPromptOperation,
      isReady: function () { return active && connected; },
      onAccepted: finishJob, onFailed: operationFailed,
      onReconciling: function (job) {
        if (pending === job && message === "正在发送…") message = "";
        refreshPending(); persist(); render();
      },
      onUpdate: function () { refreshPending(); render(); }
    });
    var stopManager = global.CodexBridgeDesktopEmbeddedDSHStop.create({
      isReady: function () { return active && connected; }, listSessions: listSessions,
      onChange: function (id, state, error) {
        if (state === "stopped") workspaceRequests.remove(id);
        if (id === sessionID) {
          if (state === "stopping") message = "正在停止会话…";
          else if (state === "stopped") { running = false; message = "会话已停止。"; }
          else if (state === "failed") message = error && error.message || "停止失败，请重试。";
          else if (state === "checking" && error) message = "正在确认停止状态。";
        }
        render();
      }
    });

    function persist() {
      var snapshot = { selected: selected, drafts: drafts, pendingJobs: jobs.list(),
        activeSessionID: sessionID, activeProjectID: projectID,
        sessions: P.navigationIndex(directory.items()), workspaceBindIDs: workspaceRequests.savedIDs() };
      var legacy = jobs.list().find(function (job) { return job.legacyPending; });
      if (legacy) snapshot.pending = legacy;
      try { global.localStorage.setItem(key, JSON.stringify(snapshot)); } catch (_) {}
    }
    function projectKey(id) { return id == null ? "" : id; }
    function refreshPending() {
      pending = jobs.current(projectID, sessionID);
      loading = !!pending && inFlight.has(pending.requestId);
      restoredPending = !!pending && !loading && !pending.error;
    }
    function currentDraftKey() { return JSON.stringify([projectID, sessionID || "new"]); }
    function saveDraft() {
      var draft = { text: view.input.value, model: chosenModel, effort: chosenEffort,
        attachmentPaths: attachmentPaths.slice(), attachmentRefs: attachmentRefs.slice(),
        attachmentItems: attachmentItems.slice(), attachmentError: attachmentError, selectionEdited: draftSelectionEdited };
      if (!sessionID && permissionState.draftPreset) draft.permissionPreset = permissionState.draftPreset;
      if (!sessionID && !M.retainsDraft(draft)) delete drafts[currentDraftKey()];
      else drafts[currentDraftKey()] = draft;
      persist();
    }
    function loadDraft() {
      var draft = drafts[currentDraftKey()] || {};
      if (!sessionID && !M.retainsDraft(draft)) draft = {};
      view.input.value = draft.text || ""; attachmentPaths = S.safeArray(draft.attachmentPaths).slice();
      attachmentRefs = S.safeArray(draft.attachmentRefs).slice(); attachmentItems = S.safeArray(draft.attachmentItems).slice();
      attachmentError = draft.attachmentError || "";
      draftSelectionEdited = M.hasUserSelection(draft);
      var choice = M.initialSelection(draft, !!sessionID, catalogDefault);
      chosenModel = choice.model; chosenExplicit = choice.explicit; chosenEffort = choice.effort;
      restoringSelection = !!sessionID && !chosenModel;
      updateModels(); S.autoGrowTextArea(view.input); updateAttachments();
      permissions.open(sessionID, draft.permissionPreset, connected);
    }
    function followCatalogDefault() {
      if (!catalogDefault || !M.followsDefault({ text: view.input.value,
        attachmentPaths: attachmentPaths, attachmentRefs: attachmentRefs, selectionEdited: draftSelectionEdited }, !!sessionID)) return;
      chosenModel = catalogDefault.model; chosenEffort = catalogDefault.effort; chosenExplicit = catalogDefault.explicit;
      updateModels(); saveDraft();
    }
    function startupFailure(kind, error) {
      if (!startupFinished) startupFailures[kind] = error && error.message || "工作台启动失败，请重试。";
    }
    function startupRead(kind, read) {
      if (startupReads[kind]) return startupReads[kind];
      var tracked = read().finally(function () { if (startupReads[kind] === tracked) delete startupReads[kind]; });
      startupReads[kind] = tracked;
      return tracked;
    }
    function retryStartup() {
      startupFailures = {};
      if (!serviceConnected) {
        if (emit) emit("refresh", {});
      } else if (!connected) {
        if (!started) { engineFailed = false; activate(); }
      } else {
        if (!directory.ready()) startupRead("sessions", listSessions).catch(showError);
        if (!history.ready()) startupRead("history", loadHistory).catch(showError);
      }
      updateStartup();
    }
    function updateStartup() {
      var startup = global.CodexBridgeDesktopStartup;
      if (!startup || startupFinished || !active) return;
      startupFinished = true; startup.update({ status: "ready" });
    }
    function updateModels() {
      if (!modelsLoaded) return;
      modelChoices = M.choices(models, catalogFailures, chosenModel, Object.assign({ known: authKnown }, auth), chosenExplicit);
      D.selectOptions(view.model, modelChoices.map(function (choice) { return { id: choice.id, title: choice.title }; }), false);
      chosenModel = restoringSelection ? "" : M.selectedModel(modelChoices, chosenModel);
      view.model.value = chosenModel;
      var model = modelChoices.find(function (choice) { return choice.id === chosenModel; });
      if (model && !model.pending) chosenExplicit = true;
      var effort = M.efforts(model, chosenEffort); chosenEffort = effort.selected;
      D.selectOptions(view.effort, global.CodexBridgeDesktopDSHComposerView.localizeEfforts(effort.choices), false); view.effort.value = chosenEffort;
      view.effortWrapper.hidden = !effort.choices.length;
    }
    function updatePermissions() {
      var choices = permissionState.choices.length ? permissionState.choices : [{ id: "", title: "权限加载中" }];
      D.selectOptions(view.permission, choices, false); view.permission.value = permissionState.selected;
      view.permissionWrapper.hidden = false; validate();
    }
    function updateAttachments() {
      var scope = JSON.stringify([projectID, sessionID, navigationRevision]);
      if (!attachmentView || attachmentScope !== scope) {
        var id = projectID, session = sessionID, revision = navigationRevision;
        var draftKey = currentDraftKey();
        attachmentScope = scope; attachmentDraft = { attachmentPaths: attachmentPaths, attachmentRefs: attachmentRefs,
          attachmentItems: attachmentItems, attachmentError: attachmentError, attachmentBusy: false };
        var draft = attachmentDraft;
        attachmentView = global.CodexBridgeDesktopDSHComposerView.attachments(view.attachmentSlot, draft, true, function () {
          if (id === projectID && session === sessionID && revision === navigationRevision) {
            attachmentPaths = draft.attachmentPaths; attachmentRefs = draft.attachmentRefs;
            attachmentItems = draft.attachmentItems; attachmentError = draft.attachmentError; saveDraft(); validate();
          } else {
            var savedDraft = drafts[draftKey] || {};
            savedDraft.attachmentPaths = draft.attachmentPaths.slice(); savedDraft.attachmentRefs = draft.attachmentRefs.slice();
            savedDraft.attachmentItems = draft.attachmentItems.slice(); savedDraft.attachmentError = draft.attachmentError;
            drafts[draftKey] = savedDraft; persist();
          }
        }, { projectID: id, list: view.attachmentList });
      } else {
        attachmentDraft.attachmentPaths = attachmentPaths; attachmentDraft.attachmentRefs = attachmentRefs;
        attachmentDraft.attachmentItems = attachmentItems; attachmentDraft.attachmentError = attachmentError;
        attachmentView.update();
      }
      if (attachmentView) attachmentView.setDisabled(!!pending);
    }
    function validate() {
      var blocked = !!pending, invalid = view.input.value.indexOf("\u0000") >= 0 || new TextEncoder().encode(view.input.value).length > 32768;
      var model = modelChoices.find(function (choice) { return choice.id === view.model.value; });
      var modelPending = !!(model && model.pending);
      var offerChat = modelPending && (!auth.authenticated || !auth.planEnabled || model.provider === "chatgpt-siwc");
      view.send.disabled = blocked || loading || commandPreparing || restoringSelection || !connected || !history.ready() || !permissionState.ready
        || !!sessionID && !directory.ready()
        || permissionState.loading || permissionState.writing || !!permissionState.error || !!attachmentError
        || !!(attachmentDraft && attachmentDraft.attachmentBusy)
        || !view.model.value || !!(model && model.pending)
        || (!view.input.value.trim() && !attachmentPaths.length && !attachmentRefs.length) || invalid;
      view.input.readOnly = false; view.model.disabled = blocked || running; view.effort.disabled = blocked || running;
      view.permission.disabled = !connected || blocked || running || permissionState.loading || permissionState.writing
        || !permissionState.choices.length || !!sessionID && !directory.get(sessionID);
      updateAttachments();
      view.modeWrapper.hidden = !running; view.mode.disabled = blocked;
      var recoverable = !!pending && !pending.verifying && !loading && (!!pending.error || restoredPending);
      var reloadConversation = !!history.failure();
      view.recovery.hidden = !recoverable && !reloadConversation; view.recover.hidden = view.recovery.hidden;
      view.recover.textContent = reloadConversation ? "重新加载对话" : "恢复提交";
      view.edit.hidden = !recoverable || pending.phase === "prompt" && !pending.error;
      view.recover.disabled = reloadConversation ? !serviceConnected : !recoverable || !connected || !history.ready();
      view.edit.disabled = !recoverable;
      var hint = message;
      if (!hint && pending && pending.verifying) hint = "正在核对消息状态…";
      if (!hint && recoverable) hint = pending.error || "上一次提交尚未确认。";
      if (!hint && !connected) hint = "正在连接工作台…";
      else if (!hint && !history.ready()) hint = "正在载入对话…";
      else if (!hint && permissionState.error) hint = permissionState.error;
      else if (!hint && attachmentError) hint = attachmentError;
      else if (!hint && !view.model.value) hint = "请连接模型。";
      else if (!hint && model && model.pending) hint = "所选模型暂不可用，请重新连接或选择其他模型。";
      else if (!hint && invalid) hint = "消息不能包含 NUL，且不能超过 32768 字节。";
      view.setHint(hint); view.feedback.hidden = view.root.hidden;
      stop.hidden = !sessionID || !running;
      stop.disabled = !connected || stopManager.has(sessionID);
      stop.textContent = stopManager.has(sessionID) ? "停止中…" : "停止";
      restart.hidden = !engineFailed;
      restart.disabled = restarting; restart.textContent = restarting ? "重启中…" : "重启引擎";
      reconnect.hidden = !connected || !offerChat || auth.signingIn;
      customAPI.hidden = !connected || !modelPending;
      cancelLogin.hidden = !connected || !offerChat || !auth.signingIn;
      reconnect.disabled = !!chatModelRefresh;
      if (chatModelRefresh) reconnect.textContent = "刷新中…";
      else if (!auth.authenticated) reconnect.textContent = "使用 ChatGPT 登录";
      else if (!auth.planEnabled) reconnect.textContent = "切换 ChatGPT 账号";
      else reconnect.textContent = "刷新模型";
    }
    function render() {
      directory.render({ projectID: projectID, sessionID: sessionID, navigationActive: navigationActive,
        connected: connected, engineFailed: engineFailed });
      queue.setSession(sessionID, active && connected);
      var needsModel = !modelChoices.length;
      var showWelcome = connected && modelsLoaded && !sessionID && !pending && needsModel;
      welcome.update(showWelcome, needsModel, auth, message);
      conversation.root.hidden = showWelcome;
      view.root.hidden = false;
      var workspace = workspaceRequests.get(sessionID);
      workspacePrompt.hidden = !workspace;
      workspacePromptText.textContent = "此任务需要工作文件夹，选择后继续。";
      workspaceButton.disabled = bindingSessions.has(sessionID) || stopManager.has(sessionID);
      workspaceButton.textContent = bindingSessions.has(sessionID) ? "正在选择…" : "选择文件夹";
      var transcript = history.snapshot();
      var project = S.safeArray(page.projects).find(function (item) { return item.id === projectID; });
      var queuedPending = pending && pending.wasRunning && pending.mode === "queue";
      var visiblePending = pending && !queuedPending && pending.projectID === projectID && (!sessionID || pending.sessionId === sessionID) ? pending : null;
      conversation.update(sessionID, project && project.title || "", transcript.records, transcript.streamText,
        visiblePending, transcript.streamReasoning, { projections: transcript.projections, running: running,
          streamTools: transcript.streamTools, hasMore: transcript.hasMore, loadingEarlier: history.loadingEarlier(), onLoadEarlier: loadEarlier });
      actions.update({ sessionID: sessionID, connected: connected, running: running, pending: !!pending,
        title: directory.label(sessionID) });
      validate();
      updateStartup();
    }
    function listSessions() { return directory.list(); }
    function listModels(providerID, force) {
      var request = ++modelRequest, requestedDefaultRevision = defaultRevision;
      modelRefresh = T.call("models.list", force ? { refresh: true } : {}).then(function (value) {
        if (request !== modelRequest) return;
        models = M.mergedGroups(models, value);
        catalogFailures = S.safeArray(value && value.failures);
        modelsLoaded = true;
        if (requestedDefaultRevision === defaultRevision) {
          catalogDefault = M.defaultSelection(value, models, catalogFailures); followCatalogDefault();
        }
        if (!chosenModel && !restoringSelection && catalogDefault) {
          chosenModel = catalogDefault.model; chosenEffort = catalogDefault.effort; chosenExplicit = catalogDefault.explicit;
        }
        updateModels(); render();
      });
      function awaitCurrent(revision, pendingRefresh) {
        return pendingRefresh.then(function () {
          if (revision !== modelRequest) return awaitCurrent(modelRequest, modelRefresh);
          return modelChoices.filter(function (item) { return !item.pending && (typeof providerID !== "string" || item.provider === providerID); }).length;
        }, function (failure) {
          if (revision !== modelRequest) return awaitCurrent(modelRequest, modelRefresh);
          throw failure;
        });
      }
      return awaitCurrent(request, modelRefresh);
    }
    function loadPending() {
      return T.read("pending.list", function () {
        var revision = workspaceRequests.version();
        return T.call("pending.list", {}).then(function (value) {
          var items = S.safeArray(value && value.items);
          interactions.replacePending(items.filter(function (item) { return item.type !== "workspace"; }));
          var workspaces = value && Array.isArray(value.workspaceRequests) ? value.workspaceRequests
            : items.filter(function (item) { return item.type === "workspace"; });
          if (workspaceRequests.replace(workspaces, revision)) render();
        });
      });
    }
    function loadAuthentication() {
      var revision = authRevision;
      return T.call("settings.get", {}).then(function (value) {
        if (revision !== authRevision) return;
        var state = value && value.chatgpt || {};
        authKnown = true;
        auth = { authenticated: !!state.authenticated, signingIn: !!state.signingIn, planEnabled: !!state.planEnabled,
          availability: state.availability || "ready" };
        updateModels();
        render();
      });
    }
    function refreshChatModels() {
      if (chatModelRefresh) return chatModelRefresh;
      welcome.setRefreshing(true); message = "正在刷新模型…";
      chatModelRefresh = T.call("auth.refreshModels", {}).then(function () { return listModels(undefined, true); }).then(function () {
        if (message === "正在刷新模型…") message = "模型已刷新。";
      }).catch(showError).finally(function () {
        chatModelRefresh = null; welcome.setRefreshing(false); render();
      });
      render(); return chatModelRefresh;
    }
    function loadHistory(recoveryAttempt) { return history.load(recoveryAttempt); }
    function loadEarlier() { return history.loadEarlier(); }
    function select(id, nextDraftProjectID) {
      var target = directory.get(id);
      var nextProject = id ? target && target.projectID || null
        : nextDraftProjectID !== undefined ? nextDraftProjectID : page.selectedProjectID || null;
      if (id === sessionID && nextProject === projectID) return Promise.resolve();
      navigationRevision++; sessionNavigation++;
      if (mentions) mentions.hide();
      saveDraft(); sessionID = id || null; projectID = nextProject; refreshPending(); history.setSession(sessionID);
      delete startupFailures.history;
      running = !!(directory.get(sessionID) || {}).running;
      interactions.setSession(sessionID);
      if (sessionID && connected) stopManager.restore(sessionID);
      message = "";
      if (pending && pending.projectID === projectID && pending.sessionId === sessionID && pending.error) message = pending.error;
      selected[projectKey(projectID)] = sessionID; persist(); loadDraft(); render();
      if (sessionID) return loadHistory().catch(showError);
      return Promise.resolve();
    }
    function openSession(id) {
      if (!active) return Promise.resolve();
      if (!connected) { pendingOpenSession = id; return Promise.resolve(); }
      if (id === sessionID) return history.ready() ? Promise.resolve() : loadHistory();
      if (!id) return select(null);
      var ticket = ++sessionNavigation, revision = navigationRevision;
      return listSessions().then(function () {
        if (!active || ticket !== sessionNavigation || revision !== navigationRevision) return;
        var item = directory.get(id);
        if (!item) throw new Error("找不到此会话，请刷新后重试。");
        return select(id);
      }).catch(function (error) {
        if (ticket === sessionNavigation) showError(error);
      });
    }
    function openSessionAt(id, seq) {
      return openSession(id).then(function () {
        function locate(attempt) {
          if (id !== sessionID) return;
          if (conversation.revealSequence && conversation.revealSequence(seq)) return;
          if (attempt >= 10 || !history.snapshot().hasMore) {
            message = "请继续加载更早的消息以查看匹配位置。"; render(); return;
          }
          var before = history.snapshot().beforeSeq;
          return loadEarlier().then(function () {
            if (history.snapshot().beforeSeq === before) return;
            return locate(attempt + 1);
          });
        }
        return locate(0);
      });
    }
    function newSession(nextProjectID) {
      select(null, nextProjectID === undefined ? page.selectedProjectID || null : nextProjectID || null);
      message = ""; render(); view.input.focus();
    }
    function selectProvider(providerID) {
      if (running || pending) return false;
      var model = M.firstAvailableForProvider(modelChoices, providerID);
      if (!model) return false;
      chosenModel = model.id; chosenEffort = ""; chosenExplicit = true; restoringSelection = false; draftSelectionEdited = true;
      updateModels(); saveDraft(); render();
      return true;
    }
    function showError(error) { message = error && error.message || "工作台操作失败。"; render(); }
    function modelSelection() {
      try { var values = JSON.parse(view.model.value); return { provider: values[0], model: values[1], reasoningEffort: view.effort.value || undefined }; }
      catch (_) { return null; }
    }
    async function ensureCommandSession() {
      if (sessionID) return sessionID;
      if (!connected || commandPreparing || pending) throw new Error("会话正在准备中，请稍后重试。");
      var id = T.requestID(), project = projectID, revision = navigationRevision;
      var preset = permissionState.selected, selection = modelSelection();
      commandPreparing = true; message = "正在准备会话…"; render();
      try {
        var created = await T.call("session.create", { sessionId: id, projectID: project });
        if (!created || created.sessionId !== id) throw new Error("会话身份未能确认，请重试。");
        if (preset) await permissions.apply(id, preset);
        if (selection) await T.call("session.selectModel", Object.assign({ sessionId: id }, selection));
        directory.upsert(id, project);
        if (revision === navigationRevision && project === projectID && !sessionID) {
          saveDraft(); var oldKey = currentDraftKey(); sessionID = id;
          if (drafts[oldKey]) { drafts[currentDraftKey()] = drafts[oldKey]; delete drafts[oldKey]; }
          selected[projectKey(projectID)] = id; history.setSession(id, true);
          interactions.setSession(id); permissions.open(id, null, connected); refreshPending();
          message = ""; persist(); render();
        }
        listSessions().catch(showError); return id;
      } finally { commandPreparing = false; render(); }
    }
    function ownsPendingView(job, origin) {
      return P.ownsJobView(job, origin, { projectID: projectID, sessionID: sessionID, revision: navigationRevision });
    }
    function followPendingSession(job, origin) {
      if (!ownsPendingView(job, origin) || sessionID === job.sessionId) return;
      sessionID = job.sessionId; history.setSession(sessionID, true); selected[projectKey(projectID)] = sessionID; interactions.setSession(sessionID);
      refreshPending();
      permissions.open(sessionID, null, job.phase !== "permission" && job.phase !== "create" && connected); persist();
    }
    function finishJob(job) {
      if (!jobs.has(job)) return;
      jobs.remove(job); inFlight.delete(job.requestId);
      var showing = job.projectID === projectID && job.sessionId === sessionID;
      if (showing) { running = true; message = ""; pendingOrigin = null; }
      refreshPending(); persist(); render();
      listSessions().catch(showError);
      if (showing) { loadHistory().catch(showError); queue.refresh(); }
    }
    function operationFailed(job, operation) {
      job.verifying = false;
      job.error = operation && operation.phase === "cancelled" ? "消息已停止。" : "消息发送失败，请查看会话状态。";
      inFlight.delete(job.requestId); refreshPending(); persist(); render();
    }
    function submitPromptOperation(job) {
      var input = { sessionId: job.sessionId, requestId: job.requestId, text: job.text,
        mode: job.mode, attachmentPaths: job.attachmentPaths, attachmentRefs: job.attachmentRefs || [] };
      return T.call("operations.submit", { operationID: job.requestId, kind: "session.prompt", legacyPending: !!job.legacyPending,
        sessionID: job.sessionId, requestID: job.requestId, input: input }, { timeoutMs: 10000 }).then(function (result) {
        if (job.legacyPending && O.snapshot(result, job.requestId)) { delete job.legacyPending; persist(); }
        return result;
      });
    }
    function inspectOperation(job, result) { return recovery.inspect(job, result); }
    function reconcileJob(job, delay) { recovery.schedule(job, delay); }
    function sendPending(nextJob) {
      var job = nextJob || pending;
      if (!job || inFlight.has(job.requestId) || job === pending && !history.ready() && job.phase !== "create") return;
      var restoredDraft = !sessionID && pendingOrigin && pendingOrigin.follow && pendingOrigin.revision === navigationRevision;
      var origin = { sessionID: sessionID, revision: navigationRevision,
        follow: projectID === job.projectID && (sessionID === job.sessionId || !sessionID && (job.phase === "create" || restoredDraft)) };
      delete job.error;
      pendingOrigin = origin; inFlight.add(job.requestId); refreshPending();
      if (origin.follow) message = "正在发送…"; render();
      Promise.resolve().then(async function () {
        if (job.phase === "create") {
          var created = await T.call("session.create", { projectID: job.projectID, sessionId: job.sessionId });
          if (!created || created.sessionId !== job.sessionId) throw new Error("会话身份未能确认，请重试。");
          job.sessionId = created.sessionId; job.phase = job.permissionPreset ? "permission" : "select"; persist();
          directory.invalidateRead(); directory.upsert(job.sessionId, job.projectID);
          var jobKey = JSON.stringify([job.projectID, job.sessionId]);
          if (job.selection && !drafts[jobKey]) drafts[jobKey] = { text: "", model: JSON.stringify([job.selection.provider, job.selection.model]),
            effort: job.selection.reasoningEffort || "", attachmentPaths: [] };
          followPendingSession(job, origin);
          if (job.sessionId === sessionID) permissions.open(sessionID, null, job.phase !== "permission" && connected);
          persist(); render(); listSessions().catch(showError);
        }
        followPendingSession(job, origin);
        if (job.phase === "permission") {
          await permissions.apply(job.sessionId, job.permissionPreset);
          job.phase = "select"; persist();
        }
        if (job.phase === "select") {
          if (job.selection) {
            var result = await T.call("session.selectModel", Object.assign({ sessionId: job.sessionId }, job.selection));
            var selection = result && result.selected || job.selection;
            defaultRevision++;
            catalogDefault = { model: JSON.stringify([selection.provider, selection.model]),
              effort: selection.reasoningEffort || "", explicit: true };
            followCatalogDefault(); render();
          }
          job.phase = "prompt"; persist();
        }
        var result = await submitPromptOperation(job);
        if (!inspectOperation(job, result)) reconcileJob(job, 10000);
      }).catch(function (error) {
        if (job.phase === "prompt" && (!error.code || ["embedded_dsh_transport_timeout", "embedded_dsh_runtime", "service_unavailable"].includes(error.code))) {
          if (ownsPendingView(job, origin)) message = "";
          reconcileJob(job, 0); return;
        }
        if (jobs.has(job)) { job.error = error && error.message || "工作台操作失败。"; persist(); }
        if (ownsPendingView(job, origin) || job.projectID === projectID && job.sessionId === sessionID) showError(error);
        else if (message === "正在发送…") message = "";
      })
        .finally(function () { inFlight.delete(job.requestId); refreshPending(); render(); });
    }
    function submit() {
      if (view.send.disabled || pending) return;
      var text = view.input.value, selection = running ? null : modelSelection();
      pending = { projectID: projectID, sessionId: sessionID || T.requestID(), requestId: T.requestID(),
        text: text, selection: selection, mode: running ? view.mode.value : "queue",
        wasRunning: running, attachmentPaths: attachmentPaths.slice(), attachmentRefs: attachmentRefs.slice(),
        attachmentItems: attachmentItems.slice(), permissionPreset: sessionID ? null : permissionState.selected,
        phase: sessionID ? selection ? "select" : "prompt" : "create", originDraft: !sessionID };
      jobs.add(pending);
      restoredPending = false;
      view.input.value = ""; attachmentPaths = []; attachmentRefs = []; attachmentItems = []; attachmentError = ""; draftSelectionEdited = false;
      permissions.releaseDraft();
      saveDraft();
      if (!sessionID) {
        var job = pending;
        directory.upsert(job.sessionId, job.projectID);
        followPendingSession(job, { sessionID: null, revision: navigationRevision, follow: true });
        job.originDraft = false;
      }
      updateAttachments(); persist(); sendPending();
    }
    function applyEvents(value, resynchronize) {
      if (!value || typeof value.cursor !== "number") return;
      cursor = value.cursor;
      var refreshSessions = !!value.reset || resynchronize, refreshHistory = refreshSessions;
      var refreshModels = false, refreshPermissions = false, refreshQueue = false, refreshPendingList = false;
      S.safeArray(value.events).forEach(function (item) {
        if (item.type === "runtime.failed") {
          failEngine(new Error(item.payload && item.payload.message || "工作台引擎已退出。"));
          return;
        }
        interactions.receive(item);
        if (item.type === "workspace.required" && item.payload) {
          workspaceRequests.apply(item);
        }
        if (item.type === "pending.changed") refreshPendingList = true;
        if (eventListener) eventListener(item);
        if (item.type === "auth.changed") {
          authRevision++;
          authKnown = true;
          auth = { authenticated: !!(item.payload && item.payload.authenticated), signingIn: !!(item.payload && item.payload.signingIn),
            planEnabled: !!(item.payload && item.payload.planEnabled), availability: item.payload && item.payload.availability || "ready" };
          if (!auth.authenticated && !auth.signingIn) {
            models = models.filter(function (group) { return group.id !== "chatgpt-siwc"; });
          }
          updateModels();
          if (item.payload && item.payload.error) message = item.payload.error;
          else message = "";
          if (!eventListener) refreshModels = true;
        }
        if (item.type === "models.changed" && !eventListener) refreshModels = true;
        if (item.type === "session/title" || item.type === "session/created" || item.type === "status") refreshSessions = true;
        if (!item.sessionID || item.sessionID === sessionID) {
          var change = history.receive(item);
          if (change.resync) refreshHistory = true;
          if (item.type === "model/selection" && !pending && item.payload && item.payload.provider && item.payload.model) {
            chosenModel = JSON.stringify([item.payload.provider, item.payload.model]);
            chosenEffort = item.payload.reasoningEffort || ""; chosenExplicit = true; restoringSelection = false;
            draftSelectionEdited = false; updateModels(); saveDraft();
          }
          if (item.type === "permission/preset" || item.type === "sandbox/mode" || item.type === "approval/policy") refreshPermissions = true;
          if (["turn/end", "agent/inbox/spliced"].includes(item.type)
            || item.type === "assistant-stream" && item.payload && item.payload.type === "end") refreshHistory = true;
          if (item.type === "agent/inbox/spliced") refreshQueue = true;
          if (item.type === "status") {
            running = item.payload && item.payload.status === "running";
            if (!running) stopManager.observe(sessionID, running);
          }
        }
      });
      render();
      if (refreshHistory && sessionID) loadHistory().catch(showError);
      if (refreshQueue) queue.refresh();
      if (refreshSessions) listSessions().catch(showError);
      if (refreshModels) listModels().catch(showError);
      if (refreshPermissions && !pending) permissions.refresh().catch(showError);
      if (value.reset || resynchronize || refreshPendingList) loadPending().catch(showError);
    }
    function clearPollRetry() {
      if (pollTimer) global.clearTimeout(pollTimer);
      pollTimer = null;
    }
    function clearRecoveryTimers() {
      recovery.clearTimers();
    }
    function poll(token, retries) {
      if (!active || token !== generation) return;
      retries = retries || 0;
      T.call("events", { after: cursor, timeoutMs: 20000 }, { timeoutMs: 30000 }).then(function (value) {
        if (!active || token !== generation) return;
        if (message === synchronizationMessage) message = "";
        applyEvents(value, retries > 0); poll(token);
      }).catch(function (error) {
        if (!active || token !== generation) return;
        if (error.code === "busy" && error.retryable === true) {
          if (!message || message === synchronizationMessage) { message = synchronizationMessage; render(); }
          pollTimer = global.setTimeout(function () {
            pollTimer = null; poll(token, Math.min(retries + 1, 5));
          }, Math.min(4000, 250 * Math.pow(2, retries)));
          return;
        }
        failEngine(error);
      });
    }
    function failEngine(error) {
      clearPollRetry();
      startupFailure("engine", error);
      started = false; connected = false; directory.invalidate(); engineFailed = true; generation++; showError(error);
    }
    function activate() {
      if (started || !active || !serviceConnected) return;
      started = true; var token = ++generation, attempts = 0;
      T.read("startup.status:" + startupScope + ":" + token, function () {
        if (!active || token !== generation) return null;
        if (attempts++) { message = "正在重新连接工作台引擎…"; render(); }
        return T.call("status", {});
      }).then(function () {
        if (!active || token !== generation) return;
        connected = true; engineFailed = false; delete startupFailures.engine; message = "";
        startupModelsSettled = false; startupPermissionsSettled = false; render();
        var initialModels = listModels().finally(function () {
          if (active && token === generation) { startupModelsSettled = true; render(); }
        });
        var initialPermissions = permissions.refresh().finally(function () {
          if (active && token === generation) { startupPermissionsSettled = true; render(); }
        });
        Promise.all([startupRead("sessions", listSessions), initialModels, startupRead("history", loadHistory),
          loadPending(), loadAuthentication(), initialPermissions]).catch(function (error) {
          if (active && token === generation) showError(error);
        });
        jobs.list().forEach(function (job) {
          if (job.phase === "prompt" && !job.legacyPending) reconcileJob(job, 0);
          else if (!inFlight.has(job.requestId)) sendPending(job);
        });
        if (pendingOpenSession) {
          var requestedSession = pendingOpenSession; pendingOpenSession = null;
          openSession(requestedSession).catch(showError);
        }
        stopManager.resume();
        if (sessionID) stopManager.restore(sessionID);
        poll(token);
      }).catch(function (error) {
        if (token !== generation) return;
        failEngine(error);
      });
    }
    function update(nextPage, nextEmit, enabled, nextServiceConnected) {
      page = nextPage || {}; emit = nextEmit; T.configure(emit);
      nextServiceConnected = !!nextServiceConnected;
      if (serviceConnected !== nextServiceConnected) serviceGeneration++;
      if (serviceConnected && !nextServiceConnected) {
        clearPollRetry(); clearRecoveryTimers(); generation++; started = false; connected = false; directory.invalidate();
        startupFailures = {}; startupReads = {}; startupModelsSettled = false; startupPermissionsSettled = false;
        if (engineFailed) message = "";
        engineFailed = false; history.disconnect();
      }
      serviceConnected = nextServiceConnected;
      var nextProject = page.selectedProjectID || null;
      if (!projectInitialized || !sessionID && nextProject !== projectID) {
        if (composing) { deferredUpdate = [nextPage, nextEmit, enabled, nextServiceConnected]; return; }
        navigationRevision++; sessionNavigation++;
        if (projectInitialized) saveDraft();
        if (!projectInitialized && saved.activeSessionID) {
          sessionID = saved.activeSessionID; projectID = saved.activeProjectID || null;
        } else {
          projectID = nextProject;
          sessionID = !projectInitialized ? selected[projectKey(projectID)] || selected[projectID] || null : null;
        }
        projectInitialized = true; refreshPending();
        message = "";
        if (pending && !pendingOrigin && projectID === pending.projectID && !sessionID) {
          pendingOrigin = { sessionID: null, revision: navigationRevision, follow: true };
        }
        running = !!(directory.get(sessionID) || {}).running;
        history.setSession(sessionID); delete startupFailures.history; loadDraft();
        interactions.setSession(sessionID);
        if (active && sessionID) loadHistory().catch(showError);
      }
      if (active !== enabled) {
        clearPollRetry(); if (!enabled) clearRecoveryTimers();
        active = enabled; generation++; started = false;
        if (!startupFinished) startupReads = {};
        interactions.setActive(active);
      }
      if (active && serviceConnected && !engineFailed && !restarting) { activate(); }
      render();
    }
    function addAttachment(id, path) {
      if (id !== projectID || pending || running || !/\.(png|jpe?g|webp)$/i.test(path)) return false;
      if (attachmentPaths.indexOf(path) < 0) {
        if (attachmentPaths.length >= 8) return false;
        attachmentPaths.push(path);
      }
      attachmentError = "";
      updateAttachments(); saveDraft(); validate(); return true;
    }
    view.input.addEventListener("input", function () { message = ""; saveDraft(); S.autoGrowTextArea(view.input); validate(); if (mentions) mentions.update(); });
    view.input.addEventListener("click", function () { if (mentions) mentions.update(); });
    view.input.addEventListener("paste", function (event) {
      var files = Array.from(event.clipboardData && event.clipboardData.files || []);
      if (!files.length || !attachmentView || !attachmentView.importFiles) return;
      event.preventDefault();
      var text = event.clipboardData.getData("text/plain");
      if (text) {
        view.input.setRangeText(text, view.input.selectionStart, view.input.selectionEnd, "end");
        saveDraft(); S.autoGrowTextArea(view.input); validate();
      }
      attachmentView.importFiles(files);
    });
    view.root.addEventListener("dragover", function (event) {
      if (event.dataTransfer && Array.from(event.dataTransfer.types || []).includes("Files")) event.preventDefault();
    });
    view.root.addEventListener("drop", function (event) {
      var files = Array.from(event.dataTransfer && event.dataTransfer.files || []);
      if (!files.length || !attachmentView || !attachmentView.importFiles) return;
      event.preventDefault(); attachmentView.importFiles(files);
    });
    view.input.addEventListener("compositionstart", function () { composing = true; });
    view.input.addEventListener("compositionend", function () {
      composing = false; saveDraft();
      if (deferredUpdate) { var next = deferredUpdate; deferredUpdate = null; update(next[0], next[1], next[2], next[3]); }
    });
    view.input.addEventListener("keydown", function (event) {
      if (mentions && mentions.keydown(event)) return;
      if (event.key === "/" && !event.metaKey && !event.ctrlKey && !event.altKey && !view.input.value
        && !event.isComposing && !composing && actions.openCommands) {
        event.preventDefault(); actions.openCommands(); return;
      }
      if (event.key === "Enter" && !event.shiftKey && !event.isComposing && !composing) { event.preventDefault(); submit(); }
    });
    view.model.addEventListener("change", function () { chosenModel = view.model.value; chosenEffort = ""; chosenExplicit = !!chosenModel; restoringSelection = false; draftSelectionEdited = true; updateModels(); saveDraft(); validate(); });
    view.effort.addEventListener("change", function () { chosenEffort = view.effort.value; draftSelectionEdited = true; saveDraft(); });
    view.permission.addEventListener("change", function () {
      permissions.choose(view.permission.value); if (!sessionID) saveDraft();
    });
    view.send.addEventListener("click", submit);
    workspaceButton.addEventListener("click", function () {
      var id = sessionID, request = workspaceRequests.get(id);
      if (!id || !request || bindingSessions.has(id)) return;
      bindingSessions.add(id); render();
      T.call("workspace.pick", { sessionId: id }, { timeoutMs: 3600000 }).then(function (result) {
        if (!result || result.cancelled) {
          return T.call("session.cancelProjectSelection", { sessionId: id, requestId: request.requestId,
            toolCallId: request.toolCallId }).then(function () { workspaceRequests.remove(id); });
        }
        if (!result.projectID) throw new Error("未取得工作文件夹，请重试。");
        return T.call("session.bindProject", { sessionId: id, projectID: result.projectID,
          requestId: request.bindRequestId, toolCallId: request.toolCallId }).then(function () {
          directory.setProject(id, result.projectID);
          jobs.list().forEach(function (job) { if (job.sessionId === id) job.projectID = result.projectID; });
          workspaceRequests.remove(id);
          if (id === sessionID) {
            saveDraft();
            var previous = currentDraftKey(), draft = drafts[previous], oldProject = projectID;
            projectID = result.projectID;
            if (draft) { drafts[currentDraftKey()] = draft; delete drafts[previous]; }
            if (selected[projectKey(oldProject)] === id) delete selected[projectKey(oldProject)];
            selected[projectKey(projectID)] = id; message = "正在继续任务…"; refreshPending();
          }
          persist(); listSessions().catch(showError);
        });
      }).catch(function (error) { if (id === sessionID) showError(error); }).finally(function () {
        bindingSessions.delete(id); render();
      });
    });
    view.recover.addEventListener("click", function () {
      if (!history.failure()) {
        if (pending && pending.phase === "prompt" && !pending.error) reconcileJob(pending, 0);
        else sendPending();
        return;
      }
      if (!serviceConnected) return;
      history.clearFailure(); message = "正在重新加载对话…";
      loadHistory().catch(showError); render();
    });
    view.edit.addEventListener("click", function () {
      if (!pending || pending.phase === "prompt" && !pending.error) return;
      var job = pending, target = job.phase === "create" ? null : job.sessionId;
      var draftKey = JSON.stringify([job.projectID, target || "new"]), draft = drafts[draftKey] || {};
      draft.text = job.text; draft.attachmentPaths = S.safeArray(job.attachmentPaths).slice();
      draft.attachmentRefs = S.safeArray(job.attachmentRefs).slice(); draft.attachmentItems = S.safeArray(job.attachmentItems).slice(); draft.attachmentError = "";
      if (job.selection) { draft.model = JSON.stringify([job.selection.provider, job.selection.model]); draft.effort = job.selection.reasoningEffort || ""; draft.selectionEdited = true; }
      if (!target && job.permissionPreset) draft.permissionPreset = job.permissionPreset;
      drafts[draftKey] = draft; jobs.remove(job); pendingOrigin = null; message = ""; refreshPending(); persist();
      if (job.projectID !== projectID) {
        selected[projectKey(job.projectID)] = target; persist(); select(target, job.projectID);
      } else if (target !== sessionID) select(target);
      else loadDraft();
      render(); view.input.focus();
    });
    stop.addEventListener("click", function () { stopManager.stop(sessionID); });
    reconnect.addEventListener("click", function () {
      if (auth.authenticated && auth.planEnabled) { refreshChatModels(); return; }
      if (openSettings) openSettings(auth.authenticated ? "chatgpt-add" : "chatgpt");
    });
    customAPI.addEventListener("click", function () { if (openSettings) openSettings("api"); });
    cancelLogin.addEventListener("click", function () { T.call("auth.cancel", {}).catch(showError); });
    function restartEngine() {
      if (restarting) return Promise.resolve(false);
      restarting = true;
      var serviceToken = serviceGeneration;
      clearPollRetry();
      generation++; started = false; connected = false; directory.invalidate(); history.disconnect();
      message = "正在重启工作台引擎…"; render();
      return T.call("runtime.restart", {}, { timeoutMs: 60000 }).then(function () {
        cursor = 0; started = false; engineFailed = false;
        if (active && serviceConnected) { activate(); }
      }).catch(function (failure) {
        if (serviceToken === serviceGeneration) failEngine(failure);
        throw failure;
      }).finally(function () {
        restarting = false;
        if (active && serviceConnected && !engineFailed) { activate(); }
        render();
      });
    }
    restart.addEventListener("click", function () { restartEngine().catch(function () {}); });
    updateAttachments();
    return { root: root, sidebar: sidebar, searchRoot: search && search.root, toolbarContext: toolbarContext, toolbarActions: toolbarActions,
      update: update, newSession: newSession,
      addAttachment: addAttachment, refreshModels: listModels, refreshSessions: listSessions,
      currentSessionID: function () { return sessionID; }, showError: showError,
      navigationIdentity: function () { return JSON.stringify([sessionID, projectID, navigationRevision]); },
      currentProjectID: function () { return projectID; }, openSession: openSession,
      toggleSearch: function () { if (search) search.toggle(); },
      setNavigationActive: function (value) { navigationActive = value; },
      selectProvider: selectProvider,

      setBottomInset: function (value) { conversation.setBottomInset(value); },
      focus: function () { if (!view.root.hidden) view.input.focus(); },
      restart: restartEngine,
      setEventListener: function (listener) { eventListener = listener; },
      interaction: interaction, subagents: subagents };
  }
  global.CodexBridgeDesktopEmbeddedDSH = { create: create };
}(window));
