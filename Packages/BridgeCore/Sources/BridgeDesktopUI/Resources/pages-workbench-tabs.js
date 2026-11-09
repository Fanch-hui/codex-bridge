(function (global) {
  "use strict";
  // Top tab strip of the web workbench: one tab per opened Agent session plus an optional
  // draft tab for a new Agent task. The open tabs span every project and are remembered in this
  // browser only; builds that kept one list per project (v1) are merged into the single list.
  var S = global.CodexBridgeDesktopPageSupport;
  var storageKey = "codexbridge.workbench.tabs.v2", legacyStorageKey = "codexbridge.workbench.tabs.v1";
  var stored = [], draftTab = false, lastSelectedKey = null, closedKey = null, signature = null, root = null, strip = null;
  var context = { page: null, emit: null };
  try {
    var saved = JSON.parse(global.localStorage.getItem(storageKey) || "null");
    if (Array.isArray(saved)) stored = saved;
    else {
      var legacy = JSON.parse(global.localStorage.getItem(legacyStorageKey) || "null");
      Object.keys(legacy && typeof legacy === "object" ? legacy : {}).forEach(function (project) {
        S.safeArray(legacy[project]).forEach(function (id) { if (stored.indexOf(id) < 0) stored.push(id); });
      });
    }
  } catch (_) {}

  function newTask() { return global.CodexBridgeDesktopWorkbenchNewTask || null; }
  // In the split view the tabs follow the focused pane and new tasks open in panes.
  function split() { var panes = global.CodexBridgeDesktopWorkbenchPanes; return panes && panes.isSplit() ? panes : null; }
  function draftActive() { var panel = newTask(); return !!panel && panel.isOpen(); }
  function persist() {
    try { global.localStorage.setItem(storageKey, JSON.stringify(stored)); } catch (_) {}
  }
  function tabsFor() {
    return stored.filter(function (id) { return typeof id === "string" && id; });
  }
  function setTabs(tabs) { stored = tabs; persist(); }

  // Tabs follow sessions, not task IDs: every follow-up turn creates a new task while the
  // session row stays the same. Stored entries are "s:<provider>\u001f<session>" keys; a "t:"
  // entry holds a selected task that has not reached the session list yet. Plain entries are
  // task IDs saved by older builds and are converted once the list contains them.
  function sessionKey(row) { return "s:" + (row.providerID || "") + "\u001f" + (row.sessionID || row.taskID); }

  function snapshot(page) {
    var rows = S.safeArray(page.tasks), byKey = new Map(), keyOfTask = new Map(), selectedRow = null;
    rows.forEach(function (row) {
      var key = sessionKey(row);
      byKey.set(key, row); keyOfTask.set(row.taskID, key);
      if (row.selected) selectedRow = row;
    });
    var selectedKey = selectedRow ? sessionKey(selectedRow)
      : (page.selectedTaskID ? (keyOfTask.get(page.selectedTaskID) || "t:" + page.selectedTaskID) : null);
    return { rows: rows, byKey: byKey, keyOfTask: keyOfTask, selectedKey: selectedKey };
  }

  // Keeps the stored tabs in step with the session list and the current selection.
  function reconcile(page) {
    var model = snapshot(page), tabs = tabsFor(), loaded = model.rows.length > 0, next = [];
    tabs.forEach(function (id) {
      var key = id;
      if (id.indexOf("s:") !== 0) {
        var taskID = id.indexOf("t:") === 0 ? id.slice(2) : id;
        key = model.keyOfTask.get(taskID) || (page.selectedTaskID === taskID ? model.selectedKey : "t:" + taskID);
      }
      // An empty list may still be loading, so it never prunes tabs.
      if (loaded && !model.byKey.has(key) && key !== model.selectedKey) return;
      if (next.indexOf(key) < 0) next.push(key);
    });
    if (model.selectedKey !== lastSelectedKey) closedKey = null;
    // A selected session always has a tab, unless the user closed it while it stayed selected.
    if (model.selectedKey && model.selectedKey !== closedKey && next.indexOf(model.selectedKey) < 0) {
      next.push(model.selectedKey);
    }
    lastSelectedKey = model.selectedKey;
    if (draftActive()) draftTab = true;
    if (JSON.stringify(next) !== JSON.stringify(tabs)) setTabs(next);
    model.tabs = next;
    return model;
  }

  function taskIDFor(key) {
    var model = snapshot(context.page || {}), row = model.byKey.get(key);
    return row ? row.taskID : (key.indexOf("t:") === 0 ? key.slice(2) : null);
  }
  function select(key) {
    var panel = newTask(), panes = split();
    if (panel) panel.close();
    if (panes) panes.reveal(key);
    var page = context.page || {}, taskID = taskIDFor(key);
    if (context.emit && taskID && snapshot(page).selectedKey !== key) {
      context.emit("selectTask", { taskID: taskID });
    }
    refresh();
  }
  function openDraft() {
    var panes = split();
    if (panes) { panes.openDraft(); return; }
    draftTab = true;
    var panel = newTask();
    if (panel) panel.open();
    refresh();
  }
  function closeTask(key) {
    var page = context.page || {}, tabs = tabsFor(), index = tabs.indexOf(key);
    if (index < 0) return;
    tabs.splice(index, 1); setTabs(tabs);
    // A closed tab closes its pane too, which then starts a new task.
    var panes = split();
    if (panes) {
      if (snapshot(page).selectedKey === key) closedKey = key;
      panes.closeSession(key);
      return;
    }
    var active = !draftActive() && snapshot(page).selectedKey === key;
    if (active) {
      closedKey = key;
      var neighbor = tabs[Math.min(index, tabs.length - 1)];
      if (neighbor) select(neighbor); else openDraft();
      return;
    }
    refresh();
  }
  function closeDraft() {
    draftTab = false;
    var panel = newTask();
    if (panel) panel.discard();
    var page = context.page || {}, tabs = tabsFor(), selected = snapshot(page).selectedKey;
    if (selected && tabs.indexOf(selected) < 0) {
      if (tabs.length) { select(tabs[tabs.length - 1]); return; }
      closedKey = null;
      tabs.push(selected); setTabs(tabs);
    }
    refresh();
  }

  function tab(title, active, onSelect, onClose, extraClass) {
    var item = S.node("div", "workbench-tab" + (active ? " is-active" : "") + (extraClass ? " " + extraClass : ""));
    item.setAttribute("role", "presentation");
    var button = S.node("button", "workbench-tab-button");
    button.type = "button"; button.title = title;
    button.setAttribute("role", "tab"); button.setAttribute("aria-selected", String(active));
    button.appendChild(S.node("span", "workbench-tab-title", title));
    button.addEventListener("click", onSelect);
    item.appendChild(button);
    var close = S.node("button", "workbench-tab-close", "×");
    close.type = "button"; close.title = "关闭标签页"; close.setAttribute("aria-label", "关闭 " + title);
    close.addEventListener("click", function (event) { event.stopPropagation(); onClose(); });
    item.appendChild(close);
    return item;
  }

  function draw() {
    var page = context.page || {}, model = reconcile(page), tabs = model.tabs, drafting = draftActive();
    var panes = split(), activeKey = panes ? panes.focusedKey() : (drafting ? null : model.selectedKey);
    var rowFor = function (key) {
      var row = model.byKey.get(key);
      if (row) return row;
      var selected = page.selectedTask;
      return selected && key === "t:" + selected.taskID ? selected : {};
    };
    var showDraft = draftTab && !panes;
    var next = JSON.stringify([tabs, drafting, showDraft, activeKey, tabs.map(function (key) {
      var row = rowFor(key);
      return [row.title, row.isRunning, row.status];
    })]);
    root.hidden = false;
    if (next === signature) return;
    signature = next;
    S.clear(strip);
    tabs.forEach(function (key) {
      var row = rowFor(key), title = row.title || "Agent 会话";
      var item = tab(title, activeKey === key,
        function () { select(key); }, function () { closeTask(key); }, row.isRunning ? "is-running" : "");
      if (row.provider) item.firstChild.title = title + " · " + row.provider;
      strip.appendChild(item);
    });
    if (showDraft) strip.appendChild(tab("新建任务", drafting, openDraft, closeDraft, "is-draft"));
    var active = strip.querySelector(".workbench-tab.is-active");
    if (active && active.scrollIntoView) active.scrollIntoView({ block: "nearest", inline: "nearest" });
  }

  function ensureRoot() {
    if (root) return root;
    root = document.getElementById("workbench-task-tabs");
    if (!root) return null;
    strip = S.node("div", "workbench-tab-strip");
    strip.setAttribute("role", "tablist"); strip.setAttribute("aria-label", "Agent 任务标签页");
    var add = S.node("button", "workbench-tab-add icon-button");
    add.type = "button"; add.title = "新建 Agent 任务"; add.setAttribute("aria-label", add.title);
    add.appendChild(S.icon("plus"));
    add.addEventListener("click", openDraft);
    root.appendChild(strip); root.appendChild(add);
    return root;
  }
  function refresh() { if (root && context.page) draw(); }

  var panel = newTask();
  if (panel && panel.setOnAccepted) panel.setOnAccepted(function () { draftTab = false; signature = null; });

  global.CodexBridgeDesktopWorkbenchTabs = {
    render: function (page, emit) {
      if (!ensureRoot()) return;
      context.page = page || {}; context.emit = emit;
      draw();
    },
    hide: function () { if (ensureRoot()) root.hidden = true; },
    openDraft: openDraft,
    sessionKey: sessionKey,
    openKeys: function () { return tabsFor(); },
    close: closeTask,
    // Adds a session tab without selecting it, used when a split pane shows the session.
    open: function (_page, key) {
      var tabs = tabsFor();
      if (!key || tabs.indexOf(key) >= 0) return;
      tabs.push(key); setTabs(tabs); signature = null;
    },
    root: function () { return ensureRoot(); }
  };
}(window));
