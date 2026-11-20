(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  var shared = global.CodexBridgeDesktopWorkbenchPanes, layouts = shared.layouts();
  var legacyKey = "codexbridge.dsh.collaboration-panes.v1", storageKey = "codexbridge.dsh.collaboration-panes.v2";

  function session(id) { return { kind: "workbenchSession", sessionID: id }; }
  function draft(slot) { return { kind: "draft", slot: slot }; }
  function isExternal(item) { return !!item && (item.kind === "externalTask" || item.kind === "agentDraft"); }
  function extSessionKey(row) {
    if (!row) return "";
    var ext = global.CodexBridgeDesktopDSHExternalAgentPane;
    if (ext && ext.sessionKey) return ext.sessionKey(row);
    var tabs = global.CodexBridgeDesktopWorkbenchTabs;
    return tabs && tabs.sessionKey ? tabs.sessionKey(row)
      : "s:" + (row.providerID || "") + "\u001f" + (row.sessionID || row.taskID || "");
  }
  function isNonEmbeddedTask(row) {
    if (!row || !row.taskID) return false;
    if (Array.isArray(row.sourceKinds) && row.sourceKinds.length) {
      return row.sourceKinds.some(function (kind) { return kind !== "embedded"; });
    }
    return row.sourceKind !== "embedded";
  }
  function identity(value) {
    if (!value) return "";
    if (value.kind === "draft") return JSON.stringify(["draft", value.slot]);
    if (value.kind === "agentDraft") return JSON.stringify(["agentDraft", value.slot]);
    if (value.kind === "externalTask") return JSON.stringify(["externalTask", value.sessionKey || ("t:" + value.taskID)]);
    return JSON.stringify([value.kind, value.sessionID, value.childID || ""]);
  }
  function valid(value) {
    if (!value) return false;
    if (value.kind === "draft" || value.kind === "agentDraft") {
      return Number.isInteger(value.slot) && value.slot >= 0 && value.slot < 4;
    }
    if (value.kind === "externalTask") {
      return (typeof value.sessionKey === "string" && !!value.sessionKey)
        || (typeof value.taskID === "string" && !!value.taskID);
    }
    return typeof value.sessionID === "string" && !!value.sessionID &&
      (value.kind === "workbenchSession" || value.kind === "subagent" && typeof value.childID === "string" && !!value.childID);
  }
  function unique(values) {
    var seen = new Set();
    return S.safeArray(values).map(function (value) {
      if (!valid(value) || seen.has(identity(value))) return null;
      seen.add(identity(value)); return value;
    });
  }
  function layout(id) { return layouts.find(function (item) { return item.id === id; }) || layouts[0]; }
  function restore(saved, legacy, lastSession) {
    var defaultPane = lastSession ? session(lastSession) : draft(0);
    var panes = unique(saved ? saved.panes : legacy && legacy.panes).slice(0, 4);
    if (!saved) panes[0] = defaultPane;
    if (!panes[0]) panes[0] = draft(freeSlot(panes));
    var tabs = unique((saved ? S.safeArray(saved.tabs) : []).concat(panes)).filter(function (item) {
      return item && item.kind !== "draft";
    });
    return { layout: layout(saved && saved.layout).id, panes: panes, tabs: tabs,
      focused: saved && Number.isInteger(saved.focused) && saved.focused >= 0 &&
        saved.focused < layout(saved.layout).count ? saved.focused : 0 };
  }
  function freeSlot(panes, preferred, reserved) {
    var used = new Set(panes.filter(function (item) { return item && item.kind === "draft"; }).map(function (item) { return item.slot; }));
    var slots = [0, 1, 2, 3].filter(function (id) { return !used.has(id); });
    if (reserved) slots = slots.filter(function (id) { return !reserved.has(id); });
    return slots.includes(preferred) ? preferred : slots[0];
  }
  function assignPanes(state, reserved) {
    var count = layout(state.layout).count;
    var used = new Set(state.panes.slice(0, count).map(identity));
    for (var index = 0; index < count; index++) {
      if (state.panes[index]) continue;
      var next = state.tabs.find(function (item) { return !used.has(identity(item)); });
      if (!next) next = draft(freeSlot(state.panes, index, reserved));
      state.panes[index] = next; used.add(identity(next));
    }
  }
  function read(key) {
    try { return JSON.parse(global.localStorage.getItem(key) || "null"); } catch (_) { return null; }
  }

  function create(main, options) {
    var lastSession = main.savedSessionID();
    var stored = read(storageKey), legacy = read(legacyKey);
    var state = restore(stored, legacy && legacy[lastSession], lastSession);
    var root = S.node("div", "workbench-panes dsh-collaboration-panes");
    var tabs = S.node("div", "workbench-task-tabs dsh-collaboration-tabs");
    var control = shared.createLayoutControl(choose, options.onMenuChange);
    var externalPane = global.CodexBridgeDesktopDSHExternalAgentPane || null;
    var launcher = externalPane && externalPane.createAgentLauncher
      ? externalPane.createAgentLauncher({
          onPickAgent: function (agent) { openAgentDraft(agent); },
          onMenuChange: options.onMenuChange
        }) : null;
    var strip = global.CodexBridgeDesktopWorkbenchTabs.createStrip(tabs, {
      label: "工作台会话标签页", addLabel: "新建对话",
      extraAdd: launcher ? launcher.root : null,
      onSelect: function (key) { reveal(state.tabs.find(function (item) { return identity(item) === key; })); },
      onClose: closeTab, onAdd: function () { newDraft(); }
    });
    var entries = [], cells = [], listed = new Map(), agentDraftViews = new Map();
    var context, active = false, rendering = false, needsRender = false, sent = "", lastSelectRequest = null, focusSignature = "", navigation = 0;
    var sessions = new Map(), pendingSessions = new Map(), polls = new Map();
    entries.push({ view: main, slot: 0, target: lastSession && session(lastSession) });
    observe(entries[0]);
    main.setSessionChoiceHandler(function (id, seq) {
      if (id) return openSession(id, seq);
      resetPane(state.focused); return true;
    });
    main.setNewSessionChoiceHandler(function (projectID) { return newDraft({ projectID: projectID }); });

    function persist() {
      try { global.localStorage.setItem(storageKey, JSON.stringify(state)); } catch (_) {}
    }
    function split() { return state.layout !== "single"; }
    function count() { return layout(state.layout).count; }
    function find(item) {
      return state.panes.slice(0, count()).findIndex(function (pane) { return identity(pane) === identity(item); });
    }
    function addTab(item) {
      if (!item || item.kind === "draft") return;
      var index = state.tabs.findIndex(function (pane) { return identity(pane) === identity(item); });
      if (index < 0) state.tabs.push(item); else state.tabs[index] = item;
    }
    function sessionSlots(panes) {
      var ids = new Set(panes.filter(function (item) { return item && !isExternal(item) && item.sessionID; })
        .map(function (item) { return item.sessionID; }));
      return new Set(entries.filter(function (entry) { return entry.target && ids.has(entry.target.sessionID) && entry.target.sessionID; })
        .map(function (entry) { return entry.slot; }));
    }
    function freeAgentDraftSlot() {
      var used = new Set(state.panes.concat(state.tabs)
        .filter(function (item) { return item && item.kind === "agentDraft"; })
        .map(function (item) { return item.slot; }));
      var slots = [0, 1, 2, 3].filter(function (id) { return !used.has(id); });
      return slots.length ? slots[0] : 0;
    }
    function agentTitleForKey(agentKey) {
      var composer = global.CodexBridgeDesktopWorkbenchComposer;
      var found = S.safeArray(composer && composer.agents ? composer.agents() : []).find(function (a) {
        return a && a.key === agentKey;
      });
      if (found && (found.title || found.providerID)) return found.title || found.providerID;
      if (!agentKey) return "外部 Agent";
      return agentKey === "codex" ? "Codex" : agentKey.split(":")[0];
    }
    function taskRowFor(item) {
      if (!item || item.kind !== "externalTask") return null;
      var tasks = S.safeArray(context && context.page && context.page.tasks);
      return (item.sessionKey && tasks.find(function (t) { return extSessionKey(t) === item.sessionKey; }))
        || (item.taskID && tasks.find(function (t) { return t.taskID === item.taskID; })) || null;
    }
    function resolveExternalTaskID(item) {
      var row = taskRowFor(item);
      return (row && row.taskID) || (item && item.taskID) || null;
    }
    function makeExternalTask(taskID, row, fallbackInfo) {
      if (!row && taskID) {
        row = S.safeArray(context && context.page && context.page.tasks)
          .find(function (t) { return t.taskID === taskID; }) || null;
      }
      var effectiveTaskID = (row && row.taskID) || taskID || "";
      var key = row ? extSessionKey(row) : (effectiveTaskID ? "t:" + effectiveTaskID : "");
      var provider = (row && (row.provider || row.providerID)) || (fallbackInfo && fallbackInfo.providerID) || "";
      return { kind: "externalTask", sessionKey: key, taskID: effectiveTaskID,
        title: (row && row.title) || "Agent 会话", provider: provider };
    }
    function openExternalTask(taskID, row) {
      if (!taskID && !row) return false;
      var item = makeExternalTask(taskID, row);
      if (!valid(item)) return false;
      reveal(item);
      return true;
    }
    function openAgentDraft(agent) {
      var agentKey = typeof agent === "string" ? agent
        : (agent && (agent.key || (agent.providerID === "codex" ? "codex"
          : agent.providerID && agent.installationID ? agent.providerID + ":" + agent.installationID : ""))) || "";
      var title = (agent && agent.title) || agentTitleForKey(agentKey) || "外部 Agent";
      var visible = state.panes.slice(0, count());
      var visibleSame = visible.findIndex(function (p) { return p && p.kind === "agentDraft" && p.agentKey === agentKey; });
      if (visibleSame >= 0) {
        focus(visibleSame);
        var shownView = agentDraftViews.get(visible[visibleSame].slot);
        if (shownView && shownView.focus) shownView.focus();
        return true;
      }
      var target = state.focused;
      if (!state.panes[target] || state.panes[target].kind !== "draft") {
        var vacant = visible.findIndex(function (p) { return p && p.kind === "draft"; });
        if (vacant >= 0) target = vacant;
      }
      var reused = state.tabs.find(function (t) { return t && t.kind === "agentDraft" && t.agentKey === agentKey; });
      var item = reused || { kind: "agentDraft", slot: freeAgentDraftSlot(), agentKey: agentKey, title: title };
      navigation++;
      var other = state.panes.findIndex(function (p) { return identity(p) === identity(item); });
      if (other >= 0 && other !== target) state.panes[other] = state.panes[target];
      state.panes[target] = item; state.focused = target;
      addTab(item); persist(); render();
      var draftView = agentDraftViews.get(item.slot);
      if (draftView && draftView.focus) draftView.focus();
      return true;
    }
    function choose(id) {
      if (state.focused >= layout(id).count) {
        var selected = state.panes[state.focused];
        state.panes[state.focused] = state.panes[0]; state.panes[0] = selected;
        state.focused = 0;
      }
      state.layout = id;
      assignPanes(state, sessionSlots(state.panes)); persist(); render();
      root.querySelectorAll(".dsh-native-composer textarea").forEach(S.autoGrowTextArea);
    }
    function focus(index) {
      if (index === state.focused) return;
      state.focused = index; navigation++; persist(); render();
    }
    function reveal(item) {
      if (!item) return;
      navigation++;
      var index = find(item);
      if (index >= 0) {
        state.focused = index;
        state.panes[index] = item;
      } else {
        var remembered = state.panes.findIndex(function (pane) { return identity(pane) === identity(item); });
        if (remembered >= 0) state.panes[remembered] = state.panes[state.focused];
        state.panes[state.focused] = item;
      }
      addTab(item); persist(); render();
    }
    function openSession(id, seq) {
      if (!active || !id) return false;
      var ticket = ++navigation;
      function show() {
        if (!active || ticket !== navigation) return;
        if (!sessions.has(id)) { currentView().showError(new Error("找不到此会话，请刷新后重试。")); return; }
        reveal(session(id));
        if (seq != null) {
          var view = currentView();
          view.revealPaneSequence(id, seq).catch(view.showError);
        }
      }
      if (sessions.has(id)) show();
      else main.refreshSessions().then(show).catch(function (error) {
        if (ticket === navigation) currentView().showError(error);
      });
      return true;
    }
    function openChild(id, child) {
      if (!id || !child) return false;
      var item = { kind: "subagent", sessionID: id, childID: child, openedFromChild: true };
      if (!split()) {
        state.layout = "main-stack";
        assignPanes(state, sessionSlots(state.panes));
        state.focused = 1;
      } else if (find(item) < 0 && state.panes[state.focused].kind !== "draft") {
        var vacant = state.panes.slice(0, count()).findIndex(function (pane) { return pane.kind === "draft"; });
        if (vacant >= 0) state.focused = vacant;
        else if (state.panes[state.focused].sessionID === id) state.focused = (state.focused + 1) % count();
      }
      reveal(item); return true;
    }
    function pick(index, key) {
      var row = choices().find(function (item) { return !item.external && item.key === key; });
      if (!row) return;
      navigation++;
      var other = state.panes.findIndex(function (item) { return identity(item) === key; });
      if (other >= 0 && other !== index) state.panes[other] = state.panes[index];
      state.panes[index] = row.item; state.focused = index;
      addTab(row.item); persist(); render();
    }
    function resetPane(index) {
      navigation++;
      var remaining = state.panes.filter(function (_, paneIndex) { return paneIndex !== index; });
      var preferred = cells[index] && cells[index].entry ? cells[index].entry.slot : index;
      var slot = freeSlot(remaining, preferred, sessionSlots(remaining));
      state.panes[index] = draft(slot); state.focused = index;
      persist(); render();
      currentView().resetPaneDraft();
    }
    function closeTab(key) {
      var tabIndex = state.tabs.findIndex(function (item) { return identity(item) === key; });
      if (tabIndex < 0) return;
      var closed = state.tabs.splice(tabIndex, 1)[0];
      if (closed && closed.kind === "agentDraft") {
        var draftView = agentDraftViews.get(closed.slot);
        if (draftView && (!draftView.hasPending || !draftView.hasPending()) && draftView.reset) draftView.reset();
      }
      var index = state.panes.findIndex(function (item) { return identity(item) === key; });
      if (index >= 0 && index < count()) {
        var neighbor = state.tabs[Math.min(tabIndex, state.tabs.length - 1)];
        if (!split() && neighbor) {
          state.panes[index] = null;
          reveal(neighbor);
        } else resetPane(index);
        return;
      }
      if (index >= 0) state.panes[index] = null;
      persist(); render();
    }
    function newDraft(request) {
      if (!active) return false;
      var index = state.panes.slice(0, count()).findIndex(function (item) { return item && item.kind === "draft"; });
      if (index < 0) resetPane(state.focused); else focus(index);
      var view = currentView();
      if (request && request.agentDraft) Promise.resolve(view.newAgentDraft(request)).catch(view.showError);
      else if (request && request.projectID) view.newSession(request.projectID);
      else view.focus();
      return true;
    }

    function observe(entry) {
      entry.view.setPaneObserver({
        sessionChanged: function (id) {
          if (rendering || !entry.target || id === entry.target.sessionID || !id) return;
          var previous = entry.target;
          var item = session(id);
          var row = entry.view.sessionItems().find(function (value) { return value.sessionId === id; });
          if (row) { pendingSessions.set(id, row); sessions.set(id, row); }
          entry.target = item;
          state.panes = state.panes.map(function (pane) { return identity(pane) === identity(previous) ? item : pane; });
          addTab(item); persist(); render();
        },
        directoryChanged: function (items) {
          if (entry.slot !== 0) return;
          sessions = new Map(items.map(function (item) { return [item.sessionId, item]; }));
          pendingSessions.forEach(function (row, id) {
            if (sessions.has(id)) pendingSessions.delete(id); else sessions.set(id, row);
          });
          discardMissingSessions();
          render();
        },
        childrenChanged: function (id, items) {
          if (id) {
            listed.set(id, items);
            discardLegacyExternalChildren(id, items);
            render();
          }
        },
        pollEvents: pollEvents,
        openChild: openChild,
        focusChild: function (id, child) {
          var index = find({ kind: "subagent", sessionID: id, childID: child });
          if (index >= 0) focus(index);
        }
      });
    }
    function pollEvents(cursor) {
      // A shared long poll leaves transport capacity for input, approvals and history.
      var request = polls.get(cursor);
      if (!request) {
        request = global.CodexBridgeDesktopEmbeddedDSHTransport.call("events",
          { after: cursor, timeoutMs: 20000 }, { timeoutMs: 30000 }).finally(function () { polls.delete(cursor); });
        polls.set(cursor, request);
      }
      return request;
    }
    function discardMissingSessions() {
      function missing(item) {
        return item && (item.kind === "workbenchSession" || item.kind === "subagent")
          && item.sessionID && !sessions.has(item.sessionID);
      }
      var tabs = state.tabs.filter(function (item) { return !missing(item); });
      if (tabs.length === state.tabs.length) return;
      state.tabs = tabs;
      state.panes = state.panes.map(function (item) {
        return missing(item) ? null : item;
      });
      assignPanes(state, sessionSlots(state.panes)); persist();
    }
    function reconcileExternalTasks() {
      var tasks = S.safeArray(context && context.page && context.page.tasks);
      if (!tasks.length) return;
      var byKey = new Map(), byTask = new Map();
      tasks.forEach(function (row) {
        if (!row || !row.taskID) return;
        var key = extSessionKey(row);
        byKey.set(key, row); byTask.set(row.taskID, { key: key, row: row });
      });
      var changed = false;
      function upgrade(item) {
        if (!item || item.kind !== "externalTask") return item;
        var row = item.sessionKey ? byKey.get(item.sessionKey) : null, key = item.sessionKey;
        if (!row && item.taskID && byTask.has(item.taskID)) {
          var found = byTask.get(item.taskID); row = found.row; key = found.key;
        }
        if (!row) return item;
        var title = row.title || item.title || "Agent 会话";
        var provider = row.provider || row.providerID || item.provider || "";
        if (item.sessionKey === key && item.taskID === row.taskID && item.title === title && item.provider === provider) return item;
        changed = true;
        return { kind: "externalTask", sessionKey: key, taskID: row.taskID, title: title, provider: provider };
      }
      state.panes = state.panes.map(upgrade);
      var seen = new Set(), nextTabs = [];
      state.tabs.forEach(function (item) {
        var next = upgrade(item), id = identity(next);
        if (seen.has(id)) { changed = true; return; }
        seen.add(id); nextTabs.push(next);
      });
      state.tabs = nextTabs;
      if (changed) persist();
    }
    function discardLegacyExternalChildren(parentID, children) {
      var external = new Set(S.safeArray(children).filter(function (child) {
        return child.mode === "external";
      }).map(function (child) { return child.childId || child.id || child.sessionId; }));
      function outdated(item) {
        return item && item.kind === "subagent" && item.sessionID === parentID
          && item.openedFromChild !== true && external.has(item.childID);
      }
      var removed = false;
      state.tabs = state.tabs.filter(function (item) {
        if (!outdated(item)) return true;
        removed = true; return false;
      });
      state.panes = state.panes.map(function (item) {
        if (!outdated(item)) return item;
        removed = true; return null;
      });
      if (!removed) return;
      state.panes.forEach(function (item, index) {
        if (!item) state.panes[index] = draft(freeSlot(state.panes, index, sessionSlots(state.panes)));
      });
      persist();
    }
    function entryAt(slot) {
      while (entries.length <= slot) {
        var index = entries.length;
        // Keep the existing editor storage for the three additional controllers.
        var view = global.CodexBridgeDesktopEmbeddedDSH.create(null, options.openSettings, options.openExternalResult,
          options.onProjectChange, { storageKey: legacyKey + ".pane-" + index, inputSuffix: "-pane-" + index });
        var entry = { view: view, slot: index };
        entries.push(entry); observe(entry); options.onCreate(view);
        view.setEventListener(function (item) { options.onEvent(item, view); });
      }
      return entries[slot];
    }
    function owners(panes) {
      var result = new Map(), used = new Set();
      panes.forEach(function (item) {
        if (item && item.kind === "draft") {
          var entry = entryAt(item.slot);
          result.set(identity(item), entry); used.add(entry);
        }
      });
      var ids = Array.from(new Set(panes.filter(function (item) { return item && !isExternal(item) && item.sessionID; })
        .map(function (item) { return item.sessionID; })));
      ids.forEach(function (id) {
        var entry = entries.find(function (value) { return !used.has(value) && value.target && value.target.sessionID === id; });
        if (entry) { result.set(id, entry); used.add(entry); }
      });
      ids.forEach(function (id) {
        if (result.has(id)) return;
        var entry = entries.find(function (value) { return !used.has(value); }) || entryAt(entries.length);
        result.set(id, entry); used.add(entry);
      });
      return result;
    }
    function choices() {
      var rows = [];
      sessions.forEach(function (item, id) {
        if (item.origin === "subagent") return;
        var title = global.CodexBridgeDesktopEmbeddedDSHSessionDirectory.label(item);
        rows.push({ key: identity(session(id)), item: session(id), title: title, projectID: item.projectID,
          running: item.running, status: item.running ? "运行中" : item.archived ? "已归档" : "" });
        S.safeArray(listed.get(id)).forEach(function (child) {
          var childID = child.childId || child.id || child.sessionId;
          if (!childID) return;
          var descriptor = { kind: "subagent", sessionID: id, childID: childID };
          var running = child.running || child.status === "running";
          rows.push({ key: identity(descriptor), item: descriptor, external: child.mode === "external", projectID: item.projectID,
            title: (child.label || child.name || child.providerID || "子 Agent") + " · " + title,
            running: running, status: running ? "运行中" : "" });
        });
      });
      var seenExternal = new Set();
      S.safeArray(context && context.page && context.page.tasks).forEach(function (task) {
        if (!isNonEmbeddedTask(task)) return;
        var sKey = extSessionKey(task);
        if (seenExternal.has(sKey)) return;
        seenExternal.add(sKey);
        var provider = task.provider || task.providerID || "", title = task.title || "Agent 会话";
        var descriptor = { kind: "externalTask", sessionKey: sKey, taskID: task.taskID, title: title, provider: provider };
        rows.push({ key: identity(descriptor), item: descriptor, externalTask: true, projectID: task.projectID,
          title: provider ? title + " · " + provider : title, tabTitle: title, provider: provider,
          running: !!task.isRunning, status: task.status || (task.isRunning ? "运行中" : "") });
      });
      return rows;
    }
    function agentDraftViewFor(slot, agentKey) {
      if (!externalPane || !externalPane.createAgentDraftView) return null;
      if (!agentDraftViews.has(slot)) {
        agentDraftViews.set(slot, externalPane.createAgentDraftView({
          slot: slot, agentKey: agentKey,
          onSwitchToDSH: function () {
            var draftID = identity({ kind: "agentDraft", slot: slot });
            var tabIdx = state.tabs.findIndex(function (t) { return identity(t) === draftID; });
            if (tabIdx >= 0) state.tabs.splice(tabIdx, 1);
            var paneIdx = state.panes.findIndex(function (p) { return identity(p) === draftID; });
            resetPane(paneIdx >= 0 && paneIdx < count() ? paneIdx : state.focused);
          },
          onAgentChange: function (nextKey) {
            var draftID = identity({ kind: "agentDraft", slot: slot }), nextTitle = agentTitleForKey(nextKey);
            var updateItem = function (it) {
              return identity(it) === draftID ? { kind: "agentDraft", slot: slot, agentKey: nextKey, title: nextTitle } : it;
            };
            state.panes = state.panes.map(updateItem); state.tabs = state.tabs.map(updateItem);
            persist(); render();
          },
          onAccepted: function (taskID, info) {
            var draftID = identity({ kind: "agentDraft", slot: slot });
            var tabIdx = state.tabs.findIndex(function (t) { return identity(t) === draftID; });
            var paneIdx = state.panes.findIndex(function (p) { return identity(p) === draftID; });
            if (!taskID) return;
            var nextItem = makeExternalTask(taskID, null, info);
            if (tabIdx >= 0) {
              var dup = state.tabs.findIndex(function (t) { return identity(t) === identity(nextItem); });
              if (dup >= 0) state.tabs.splice(tabIdx, 1); else state.tabs[tabIdx] = nextItem;
            } else addTab(nextItem);
            if (paneIdx >= 0) {
              state.panes[paneIdx] = nextItem;
              if (paneIdx < count()) state.focused = paneIdx;
              persist(); render();
            } else reveal(nextItem);
          }
        }));
      }
      return agentDraftViews.get(slot);
    }
    function createCell(index) {
      var node = S.node("section", "workbench-pane");
      node.dataset.pane = String(index);
      node.addEventListener("pointerdown", function () { focus(index); });
      node.addEventListener("focusin", function () { focus(index); });
      var header = shared.createPaneHeader(index, function (key) { pick(index, key); }, function () {
        var item = state.panes[index];
        if (item.kind === "draft") resetPane(index); else closeTab(identity(item));
      });
      var body = S.node("div", "dsh-collaboration-pane-body");
      var note = S.node("p", "workbench-pane-empty");
      node.appendChild(header.root); node.appendChild(body); node.appendChild(note); root.appendChild(node);
      return { node: node, header: header, body: body, note: note, extSession: null };
    }
    function syncCell(cell, index, item, entry, groups, row) {
      cell.header.root.hidden = !split();
      if (item.kind === "externalTask") {
        cell.header.update(groups, identity(item), row && row.status);
        cell.node.classList.toggle("is-running", !!(row && row.running));
        if (externalPane && externalPane.createAgentSessionView) {
          if (!cell.extSession) cell.extSession = externalPane.createAgentSessionView({ paneIndex: index });
          if (cell.extSession.root.parentNode !== cell.body) cell.body.appendChild(cell.extSession.root);
          cell.extSession.update(item, context.page, context.emit);
          cell.body.hidden = false; cell.note.hidden = true;
        } else {
          cell.body.hidden = true; cell.note.hidden = false; cell.note.textContent = "正在载入会话…";
        }
        return;
      }
      if (item.kind === "agentDraft") {
        cell.header.update(groups, false, agentTitleForKey(item.agentKey) || item.title || "外部 Agent");
        cell.node.classList.toggle("is-running", false);
        var draftView = agentDraftViewFor(item.slot, item.agentKey);
        if (draftView) {
          if (draftView.root.parentNode !== cell.body) cell.body.appendChild(draftView.root);
          draftView.update(context.page, context.emit, item.agentKey);
          cell.body.hidden = false; cell.note.hidden = true;
        } else {
          cell.body.hidden = true; cell.note.hidden = false; cell.note.textContent = "正在载入外部 Agent…";
        }
        return;
      }
      cell.header.update(groups, item.kind !== "draft" && identity(item), row && row.status);
      cell.node.classList.toggle("is-running", !!(row && row.running));
      var mounted = item.kind === "subagent" ? entry.view.mountChildPane(item.childID, cell.body)
        : item.kind === "draft" || entry.view.currentSessionID() === item.sessionID;
      if (mounted && item.kind !== "subagent" && entry.view.root.parentNode !== cell.body) cell.body.appendChild(entry.view.root);
      cell.body.hidden = !mounted;
      cell.note.hidden = mounted;
      cell.note.textContent = !row && item.kind === "workbenchSession" && main.sessionDirectoryReady()
        ? "找不到此会话。" : "正在载入会话…";
    }
    function currentView() {
      var cell = cells[state.focused];
      return cell && cell.entry ? cell.entry.view : main;
    }
    function isExternalFocused() { return isExternal(state.panes[state.focused]); }
    function focusedProjectID() {
      var focused = state.panes[state.focused], cell = cells[state.focused];
      if (focused && focused.kind === "externalTask") {
        var row = taskRowFor(focused);
        return (cell && cell.extSession && cell.extSession.currentProjectID())
          || (row && row.projectID) || currentView().currentProjectID();
      }
      if (focused && focused.kind === "agentDraft") {
        var dv = agentDraftViews.get(focused.slot);
        return (dv && dv.currentProjectID()) || currentView().currentProjectID();
      }
      return currentView().currentProjectID();
    }
    function focusedTaskID() {
      var focused = state.panes[state.focused], cell = cells[state.focused];
      if (!focused || focused.kind !== "externalTask") return null;
      return (cell && cell.extSession && cell.extSession.currentTaskID()) || resolveExternalTaskID(focused) || null;
    }
    function composerFor(pending) {
      for (var i = 0; i < cells.length; i++) {
        var cell = cells[i];
        if (cell.item && cell.item.kind === "externalTask" && cell.extSession) {
          var matched = cell.extSession.matchesComposer(pending);
          if (matched) return matched;
        }
      }
      return null;
    }
    function updateEntry(entry, target) {
      var enabled = active && (entry.slot === 0 || !!target);
      if (entry.context !== context || entry.active !== enabled) {
        entry.context = context; entry.active = enabled;
        entry.view.update(context.page, context.emit, enabled, context.connected, context.disabled, context.connections);
      }
      if (!target) return;
      if (target.kind === "draft" && identity(entry.target) !== identity(target)) entry.view.showPaneDraft();
      entry.target = target;
      var row = sessions.get(target.sessionID);
      if (row && entry.view.currentSessionID() !== row.sessionId) entry.view.selectPaneSession(row);
    }
    function render() {
      if (!context) return;
      if (rendering) { needsRender = true; return; }
      rendering = true;
      try {
        reconcileExternalTasks();
        root.hidden = tabs.hidden = !active; control.update(state.layout, active);
        if (launcher) { if (!active) launcher.close(); else launcher.update(); }
        root.dataset.layout = state.layout;
        var panes = active ? state.panes.slice(0, count()) : [];
        var assigned = owners(panes), targets = new Map();
        var next = panes.map(function (item) {
          if (!item || isExternal(item)) return null;
          var entry = assigned.get(item.sessionID || identity(item));
          targets.set(entry, item.sessionID ? session(item.sessionID) : item);
          return entry;
        });
        while (cells.length < panes.length) cells.push(createCell(cells.length));
        cells.forEach(function (cell, index) {
          var nextItem = panes[index], nextEntry = next[index];
          if (cell.item && (cell.entry !== nextEntry || identity(cell.item) !== identity(nextItem))) {
            if (cell.item.kind === "subagent" && cell.entry) cell.entry.view.releaseChildPane(cell.item.childID);
            else if (cell.entry && (cell.entry !== nextEntry || !nextItem || nextItem.kind === "subagent" || isExternal(nextItem))) {
              var previousRoot = cell.entry.view.root;
              if (previousRoot.parentNode === cell.body) previousRoot.remove();
            }
            if (cell.item.kind === "externalTask" && cell.extSession && (!nextItem || nextItem.kind !== "externalTask")) {
              if (cell.extSession.root.parentNode === cell.body) cell.extSession.root.remove();
            }
            if (cell.item.kind === "agentDraft") {
              var prevDraft = agentDraftViews.get(cell.item.slot);
              if (prevDraft && prevDraft.root.parentNode === cell.body) prevDraft.root.remove();
            }
          }
          cell.item = nextItem; cell.entry = nextEntry;
        });
        entries.forEach(function (entry) { updateEntry(entry, targets.get(entry)); });
        agentDraftViews.forEach(function (draftView, slot) {
          var shown = panes.some(function (p) { return p && p.kind === "agentDraft" && p.slot === slot; });
          if (!shown && draftView.hasPending && draftView.hasPending()) draftView.update(context.page, context.emit);
        });
        if (active && panes.some(function (p) { return p && p.kind === "externalTask"; })) {
          if (global.CodexBridgeDesktopWorkbenchSubmissions && global.CodexBridgeDesktopWorkbenchSubmissions.bind) {
            global.CodexBridgeDesktopWorkbenchSubmissions.bind(context.page, function () { if (active) render(); });
          }
          if (global.CodexBridgeDesktopWorkbenchControls && global.CodexBridgeDesktopWorkbenchControls.receive) {
            global.CodexBridgeDesktopWorkbenchControls.receive(context.page, context.emit, composerFor);
          }
        }
        var allRows = choices();
        var dshRows = allRows.filter(function (row) { return !row.external && !row.externalTask; });
        var extRows = allRows.filter(function (row) { return row.externalTask; });
        var byKey = new Map(allRows.map(function (row) { return [row.key, row]; }));
        var projects = S.safeArray(context.page && context.page.projects);
        var groups = projects.length > 1 ? S.groupByProject(dshRows, projects, S.defaultProjectID(context.page),
          function (row) { return row.projectID; }) : [{ title: "", rows: dshRows }];
        groups = groups.map(function (group) {
          return { title: group.title, options: group.rows.map(function (row) { return { id: row.key, title: row.title }; }) };
        });
        if (extRows.length) {
          groups.push({ title: "外部 Agent 会话",
            options: extRows.map(function (row) { return { id: row.key, title: row.title }; }) });
        }
        cells.forEach(function (cell, index) {
          cell.node.hidden = !cell.item;
          cell.node.classList.toggle("is-focused", index === state.focused);
          if (cell.item) {
            var row = byKey.get(identity(cell.item)), cellGroups = groups;
            if (row && row.external && cell.item.openedFromChild) {
              cellGroups = groups.concat([{ title: "", options: [{ id: row.key, title: row.title, hidden: true, disabled: true }] }]);
            }
            syncCell(cell, index, cell.item, cell.entry, cellGroups, row);
          }
        });
        strip.update(state.tabs.map(function (item) {
          var key = identity(item), row = byKey.get(key);
          if (item.kind === "externalTask") {
            return { key: key, title: (row && row.tabTitle) || item.title || "Agent 会话",
              provider: (row && row.provider) || item.provider || "", running: !!(row && row.running), external: true };
          }
          if (item.kind === "agentDraft") {
            var label = agentTitleForKey(item.agentKey) || item.title || "外部 Agent";
            return { key: key, title: label + " · 新建", provider: label, draft: true, external: true };
          }
          return { key: key, title: (row && row.title) || (item.kind === "subagent" ? "子 Agent" : "会话"),
            running: !!(row && row.running) };
        }), identity(state.panes[state.focused]));
        syncDescriptors();
      } finally { rendering = false; }
      if (needsRender) { needsRender = false; render(); return; }
      var focused = state.panes[state.focused], cell = cells[state.focused];
      var signature = JSON.stringify([active, identity(focused), cell && cell.entry && cell.entry.slot,
        focused && focused.kind === "externalTask" ? resolveExternalTaskID(focused) : null]);
      if (signature === focusSignature) return;
      focusSignature = signature;
      main.setSidebarSession(active && focused ? focused.sessionID || null : undefined);
      options.onFocus();
    }
    function descriptorFor(item) {
      if (!item) return null;
      if (item.kind === "workbenchSession" && item.sessionID) return { kind: "workbenchSession", sessionID: item.sessionID };
      if (item.kind === "subagent" && item.sessionID && item.childID) {
        return { kind: "subagent", sessionID: item.sessionID, childID: item.childID };
      }
      if (item.kind === "externalTask") {
        var taskID = resolveExternalTaskID(item);
        if (taskID) return { kind: "webTask", taskID: taskID };
      }
      return null;
    }
    function syncDescriptors() {
      var visible = active ? state.panes.slice(0, count()) : [];
      var hasExternal = visible.some(function (item) { return item && item.kind === "externalTask"; });
      var panes = active && (split() || hasExternal) ? visible.map(descriptorFor).filter(Boolean) : [];
      var signature = JSON.stringify(panes);
      if (signature !== sent) { sent = signature; context.emit("setWorkbenchPanes", { panes: panes }); }
      var focused = active ? state.panes[state.focused] : null;
      if (focused && focused.kind === "externalTask") {
        var taskID = resolveExternalTaskID(focused);
        if (taskID && context.page && context.page.selectedTaskID !== taskID && lastSelectRequest !== taskID) {
          lastSelectRequest = taskID;
          context.emit("selectTask", { taskID: taskID });
        } else if (taskID && context.page && context.page.selectedTaskID === taskID) {
          lastSelectRequest = null;
        }
      } else lastSelectRequest = null;
    }
    assignPanes(state);
    main.sessionItems().forEach(function (item) { sessions.set(item.sessionId, item); });
    return { root: root, tabs: tabs, control: control.root, openSession: openSession, openChild: openChild,
      openExternalTask: openExternalTask, openAgentDraft: openAgentDraft, newDraft: newDraft,
      currentView: currentView, focusedProjectID: focusedProjectID, focusedTaskID: focusedTaskID,
      isExternalFocused: isExternalFocused, composerFor: composerFor,
      update: function (page, emit, isActive, connected, disabled, connections) {
        context = { page: page, emit: emit, connected: connected, disabled: disabled, connections: connections };
        if (active && !isActive) navigation++;
        active = isActive; render();
      }
    };
  }
  global.CodexBridgeDesktopEmbeddedDSHPanes = { create: create, restore: restore, assignPanes: assignPanes };
}(window));
