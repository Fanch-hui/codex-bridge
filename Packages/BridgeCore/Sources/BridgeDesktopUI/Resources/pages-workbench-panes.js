(function (global) {
  "use strict";
  // Split view of the web workbench, modelled on the macOS "Fill & Arrange" layouts: up to
  // four panes side by side that behave like windows. A pane shows one Agent session with its
  // own conversation and composer, or its own new task draft; closing a pane turns it into a
  // fresh draft. Saved entries are session keys, "t:<taskID>" for a task just created in the
  // pane, or null for a draft. The layout and panes are remembered in this browser only and
  // span every project; the host streams one conversation per pane (`paneTasks`) after
  // `setWorkbenchPanes`.
  var S = global.CodexBridgeDesktopPageSupport;
  var storageKey = "codexbridge.workbench.panes.v1";
  var LAYOUTS = [
    { id: "single", count: 1, title: "单个会话" },
    { id: "columns", count: 2, title: "左右两格" },
    { id: "main-stack", count: 3, title: "左一右二" },
    { id: "grid", count: 4, title: "四宫格" }
  ];
  var saved = { layout: "single", panes: [] };
  try {
    var stored = JSON.parse(global.localStorage.getItem(storageKey) || "null");
    if (stored && typeof stored === "object") {
      if (LAYOUTS.some(function (item) { return item.id === stored.layout; })) saved.layout = stored.layout;
      if (Array.isArray(stored.panes)) saved.panes = stored.panes;
      else if (stored.panes && typeof stored.panes === "object") {
        Object.keys(stored.panes).forEach(function (project) {
          S.safeArray(stored.panes[project]).forEach(function (key) {
            if (key && saved.panes.indexOf(key) < 0 && saved.panes.length < LAYOUTS[LAYOUTS.length - 1].count) saved.panes.push(key);
          });
        });
      }
    }
  } catch (_) {}
  var root = null, cells = [], menu = null, button = null, control = null, sentIDs = "[]";
  saved.panes = saved.panes.map(function (key) { return typeof key === "string" && key !== "__draft__" ? key : null; });
  var context = { page: null, emit: null }, focusedIndex = 0, lastSelectedKey, drafts = [];

  function persist() {
    try { global.localStorage.setItem(storageKey, JSON.stringify(saved)); } catch (_) {}
  }
  function tabs() { return global.CodexBridgeDesktopWorkbenchTabs; }
  function layout() {
    return LAYOUTS.find(function (item) { return item.id === saved.layout; }) || LAYOUTS[0];
  }
  function keyOf(row) { return tabs() ? tabs().sessionKey(row) : "s:" + row.taskID; }
  function isSplit() { return layout().count > 1; }
  function slots(count) {
    var list = S.safeArray(saved.panes).slice();
    while (list.length < count) list.push(undefined);
    return list;
  }
  function store(list) {
    saved.panes = list.map(function (key) { return key === undefined ? null : key; });
    persist();
  }

  // Each pane keeps its own draft, so new tasks can be prepared in several panes at once.
  function draftOf(index) {
    if (!drafts[index]) {
      drafts[index] = global.CodexBridgeDesktopWorkbenchNewTask.create({
        storageKey: "codexbridge.workbench.new-task.pane-" + index + ".v1", idSuffix: "-pane-" + index, inline: true,
        onAccepted: function (taskID) {
          var list = slots(index + 1);
          list[index] = taskID ? "t:" + taskID : null;
          focusedIndex = index; store(list);
        }
      });
    }
    return drafts[index];
  }

  // Shows a session in the split view: focuses the pane that already shows it, otherwise the
  // focused pane switches to it. Tabs, the sidebar and new task receipts all go through here.
  function place(key, count) {
    var list = slots(count), index = list.slice(0, count).indexOf(key);
    if (index >= 0) { focusedIndex = index; return; }
    list[focusedIndex] = key; store(list);
  }
  // Keeps the panes in step with created tasks and the selection before assignment. A task made
  // in a pane stays there once its session is listed; the first selection seen only fills panes
  // through `assignment`.
  function follow(page, count) {
    var rows = S.safeArray(page.tasks), list = slots(count), changedList = false;
    list.forEach(function (key, index) {
      if (typeof key !== "string" || key.indexOf("t:") !== 0) return;
      var row = rows.find(function (item) { return item.taskID === key.slice(2); });
      if (!row) return;
      list[index] = keyOf(row); changedList = true;
      if (tabs()) tabs().open(page, list[index]);
    });
    if (changedList) store(list);
    var selected = rows.find(function (row) { return row.selected; });
    var selectedKey = selected ? keyOf(selected) : null;
    if (selectedKey && lastSelectedKey !== undefined && selectedKey !== lastSelectedKey) place(selectedKey, count);
    lastSelectedKey = selectedKey;
  }

  // Resolves each pane to a session row, `null` for a draft or `"loading"` for a task created
  // in the pane that is not listed yet. Panes never filled before take the selected session or
  // an open tab; a session whose tab was closed leaves a draft behind.
  function assignment(page, count) {
    var rows = S.safeArray(page.tasks), byKey = new Map(), used = new Set(), result = [];
    rows.forEach(function (row) { byKey.set(keyOf(row), row); });
    var list = slots(count);
    var selected = rows.find(function (row) { return row.selected; });
    var open = tabs() ? tabs().openKeys(page) : [];
    var candidates = (selected ? [keyOf(selected)] : []).concat(open);
    list.slice(0, count).forEach(function (key) { if (byKey.has(key) && open.indexOf(key) >= 0) used.add(key); });
    for (var index = 0; index < count; index += 1) {
      var key = list[index];
      if (key === undefined) {
        key = candidates.find(function (candidate) { return byKey.has(candidate) && !used.has(candidate); }) || null;
        if (key) used.add(key);
        list[index] = key;
      }
      if (typeof key === "string" && key.indexOf("t:") === 0) { result.push("loading"); continue; }
      var shown = key && byKey.has(key) && open.indexOf(key) >= 0 && result.every(function (row) { return !row || row === "loading" || keyOf(row) !== key; });
      if (!shown) list[index] = null;
      result.push(shown ? byKey.get(key) : null);
    }
    // Panes beyond the current layout keep what they showed for a later, larger layout.
    if (rows.length) store(list);
    return result;
  }

  function sendPanes(taskIDs) {
    var next = JSON.stringify(taskIDs);
    if (next === sentIDs || !context.emit) return;
    sentIDs = next;
    context.emit("setWorkbenchPanes", { taskIDs: taskIDs });
  }

  function glyph(item) {
    var node = S.node("span", "workbench-layout-glyph");
    node.dataset.layout = item.id;
    for (var index = 0; index < item.count; index += 1) node.appendChild(S.node("span"));
    node.setAttribute("aria-hidden", "true");
    return node;
  }

  // The layout button sits in the window toolbar next to the other web workbench actions.
  function ensureButton() {
    var host = document.querySelector("#workspace-toolbar-actions .inspector-toolbar-actions");
    if (!host) return;
    if (control && control.parentNode === host) return;
    control = S.node("span", "workbench-layout-control");
    button = S.node("button", "button small workbench-layout-button");
    button.type = "button"; button.title = "分屏布局"; button.setAttribute("aria-label", "分屏布局");
    button.setAttribute("aria-haspopup", "true");
    button.addEventListener("click", function (event) {
      if (event && event.stopPropagation) event.stopPropagation();
      toggleMenu();
    });
    menu = S.node("div", "workbench-layout-menu");
    menu.setAttribute("role", "menu"); menu.hidden = true; menu.dataset.browserOccluder = "";
    menu.appendChild(S.node("p", "workbench-layout-menu-title", "填充与排列"));
    var options = S.node("div", "workbench-layout-options");
    LAYOUTS.forEach(function (item) {
      var option = S.node("button", "workbench-layout-option");
      option.type = "button"; option.title = item.title;
      option.setAttribute("role", "menuitemradio"); option.setAttribute("aria-label", item.title);
      option.dataset.layout = item.id;
      option.appendChild(glyph(item));
      option.addEventListener("click", function () { choose(item.id); });
      options.appendChild(option);
    });
    menu.appendChild(options);
    control.appendChild(button); control.appendChild(menu);
    host.insertBefore(control, host.querySelector(".workbench-task-actions"));
    if (typeof document !== "undefined" && document.addEventListener && !ensureButton.listening) {
      ensureButton.listening = true;
      document.addEventListener("click", function (event) {
        if (!menu || menu.hidden || (event && event.target && control.contains(event.target))) return;
        menu.hidden = true; updateButton();
      });
    }
  }

  function updateButton() {
    if (!button) return;
    if (global.CodexBridgeDesktopPages && context && context.emit) {
      global.CodexBridgeDesktopPages.measureBrowserViewport(context.emit);
    }
    S.clear(button);
    button.appendChild(glyph(layout()));
    button.setAttribute("aria-expanded", String(menu && !menu.hidden));
    if (menu) menu.querySelectorAll(".workbench-layout-option").forEach(function (option) {
      option.setAttribute("aria-checked", String(option.dataset.layout === saved.layout));
      option.classList.toggle("is-selected", option.dataset.layout === saved.layout);
    });
  }

  function toggleMenu() { if (!menu) return; menu.hidden = !menu.hidden; updateButton(); }
  // The single view's draft tab steps aside in the split view, where drafts live in panes;
  // its text stays for when the single view returns.
  function choose(id) {
    saved.layout = id; persist();
    if (menu) menu.hidden = true;
    if (id !== "single" && newTask().isOpen()) newTask().close();
    rerender();
  }
  function reveal(key) {
    if (!isSplit() || !key) return;
    place(key, layout().count);
    rerender();
  }
  // "+" in the split view: the first draft pane takes focus, otherwise the focused pane becomes one.
  function openDraft(options) {
    var count = layout().count, list = slots(count), index = list.slice(0, count).indexOf(null);
    if (index < 0) { index = focusedIndex; list[index] = null; store(list); }
    focusedIndex = index;
    draftOf(index).open(options);
    rerender();
  }
  // Closing a pane is like closing a window: its session tab closes and the pane starts a brand
  // new task. Closing the tab of a shown session lands here through `closeSession`.
  function closePane(index) {
    var key = slots(index + 1)[index];
    if (typeof key === "string" && tabs() && tabs().openKeys().indexOf(key) >= 0) { tabs().close(key); return; }
    resetPane(index);
  }
  function closeSession(key) {
    var index = slots(layout().count).slice(0, layout().count).indexOf(key);
    if (index >= 0) resetPane(index); else rerender();
  }
  function resetPane(index) {
    var list = slots(index + 1);
    list[index] = null; store(list);
    focusedIndex = index;
    draftOf(index).reset();
    rerender();
    draftOf(index).focus();
  }
  function rerender() {
    var page = global.CodexBridgeDesktopWorkbenchPage;
    if (page && context.page) page.renderShared(context.page, context.emit, false);
  }

  function ensureRoot() {
    if (root) return root;
    root = document.getElementById("workbench-panes");
    return root;
  }

  function createCell(index) {
    var cell = { index: index, key: null, taskID: null, detail: null, inputs: null, form: null, following: true };
    cell.root = S.node("section", "workbench-pane");
    cell.root.dataset.pane = String(index);
    cell.root.addEventListener("pointerdown", function () { focus(cell); });
    cell.root.addEventListener("focusin", function () { focus(cell); });
    var header = S.node("div", "workbench-pane-header");
    cell.picker = S.node("select", "workbench-pane-picker");
    cell.picker.setAttribute("aria-label", "第 " + (index + 1) + " 格显示的会话");
    cell.picker.addEventListener("change", function () {
      var chosen = cell.picker.value;
      if (!chosen) return;
      // Picking a session shown elsewhere swaps the two panes.
      var list = slots(layout().count), other = list.indexOf(chosen);
      if (other >= 0 && other !== index) list[other] = list[index] === undefined ? null : list[index];
      list[index] = chosen; store(list);
      // A session shown in a pane is an open session, so it also gets a tab.
      if (tabs()) tabs().open(context.page, chosen);
      rerender();
    });
    cell.status = S.node("span", "workbench-pane-status");
    cell.close = S.node("button", "workbench-pane-close", "×");
    cell.close.type = "button";
    cell.close.addEventListener("click", function (event) {
      if (event && event.stopPropagation) event.stopPropagation();
      closePane(index);
    });
    header.appendChild(cell.picker); header.appendChild(cell.status); header.appendChild(cell.close);
    cell.body = S.node("div", "workbench-pane-body");
    cell.body.addEventListener("scroll", function () {
      cell.following = cell.body.scrollHeight - cell.body.clientHeight - cell.body.scrollTop <= 40;
    }, { passive: true });
    cell.composer = S.node("div", "workbench-controls workbench-pane-composer");
    cell.root.appendChild(header); cell.root.appendChild(cell.body); cell.root.appendChild(cell.composer);
    return cell;
  }

  // The focused pane is the selected session, so the toolbar, tabs and approvals follow it.
  // A focused draft pane leaves no tab active.
  function focus(cell) {
    var moved = focusedIndex !== cell.index;
    focusedIndex = cell.index;
    cells.forEach(function (item) {
      item.root.classList.toggle("is-focused", item === cell);
      if (item !== cell) item.lastFocusRequest = null;
    });
    var page = context.page;
    if (cell.detail && page && context.emit && page.selectedTaskID !== cell.detail.taskID
      && cell.lastFocusRequest !== cell.detail.taskID) {
      cell.lastFocusRequest = cell.detail.taskID;
      context.emit("selectTask", { taskID: cell.detail.taskID });
    } else if (page && cell.detail && page.selectedTaskID === cell.detail.taskID) {
      cell.lastFocusRequest = null;
    }
    if (moved && page && tabs()) tabs().render(page, context.emit);
  }

  function paneProjectID(page, detail, row) {
    if (detail && detail.projectID) return detail.projectID;
    if (row && row.projectID) return row.projectID;
    if (detail && page && Array.isArray(page.tasks)) {
      var matched = page.tasks.find(function (item) { return item.taskID === detail.taskID; });
      if (matched && matched.projectID) return matched.projectID;
    }
    return page && page.selectedProjectID;
  }

  function panePage(page, detail, row) {
    return Object.assign({}, page, {
      selectedTask: detail,
      selectedTaskID: detail ? detail.taskID : null,
      selectedProjectID: paneProjectID(page, detail, row)
    });
  }

  // Everything the pane conversation reads: the detail, the project fallback of its context key,
  // the earlier-messages flag, pending submissions and the search reveal. The page object itself
  // is replaced by every state patch, so comparing it would redraw each pane every time.
  function conversationInputs(page, detail, revision, row) {
    return [detail, revision, paneProjectID(page, detail, row), !!(page.browser && page.browser.canLoadEarlierConversation),
      global.CodexBridgeDesktopWorkbenchConversation.hasSearchReveal(detail.taskID)];
  }
  function sameInputs(previous, next) {
    return !!previous && previous.length === next.length && next.every(function (value, index) {
      return value === previous[index];
    });
  }

  // Every session is listed, grouped by project when there is more than one.
  function updatePicker(cell, page, row) {
    var rows = S.safeArray(page.tasks), projects = S.safeArray(page.projects);
    var groups = projects.length > 1 ? S.groupByProject(rows, projects, S.defaultProjectID(page),
      function (item) { return item.projectID; }, function (item) { return item.projectName; }) : [{ title: "", rows: rows }];
    var grouped = groups.map(function (group) {
      return { title: group.title, options: group.rows.map(function (item) {
        return { id: keyOf(item), title: (item.title || "Agent 会话") + " · " + (item.provider || "") };
      }) };
    });
    var signature = JSON.stringify([grouped, projects.length > 1]);
    if (cell.pickerSignature !== signature) {
      cell.pickerSignature = signature;
      S.clear(cell.picker);
      function addOption(target, option) {
        var node = S.node("option", null, option.title);
        node.value = option.id;
        target.appendChild(node);
      }
      // A draft pane shows the placeholder; it is not a choice of its own.
      var placeholder = S.node("option", null, "新会话");
      placeholder.value = ""; placeholder.disabled = true; placeholder.hidden = true;
      cell.picker.appendChild(placeholder);
      grouped.forEach(function (group) {
        var target = cell.picker;
        if (projects.length > 1) { target = S.node("optgroup"); target.label = group.title; cell.picker.appendChild(target); }
        group.options.forEach(function (option) { addOption(target, option); });
      });
    }
    cell.picker.value = row ? keyOf(row) : "";
  }

  function newTask() { return global.CodexBridgeDesktopWorkbenchNewTask; }

  // A draft pane shows its own new task draft; it already received this page state.
  function renderDraft(cell, page, emit) {
    if (cell.blank === "draft") return;
    S.clear(cell.body); S.clear(cell.composer); cell.blank = "draft";
    draftOf(cell.index).mount(cell.body, cell.composer, page, emit);
  }
  function loadingNote(cell) {
    if (cell.conversation || cell.body.firstChild) return;
    cell.body.appendChild(S.node("p", "workbench-pane-empty", "正在载入会话…"));
  }

  function renderCell(cell, page, row, detail, emit) {
    var session = row && row !== "loading" ? row : null;
    updatePicker(cell, page, session);
    cell.root.classList.toggle("is-running", !!(session && session.isRunning));
    cell.status.textContent = session ? session.status || "" : "";
    cell.close.title = row ? "关闭此会话" : "清空，重新开始";
    cell.close.setAttribute("aria-label", cell.close.title);
    var key = session ? keyOf(session) : row;
    if (cell.key !== key) {
      if (cell.blank === "draft") draftOf(cell.index).unmount();
      cell.key = key; cell.taskID = null; cell.detail = null; cell.inputs = null; cell.following = true; cell.blank = null;
      S.clear(cell.body); cell.conversation = null;
      S.clear(cell.composer); cell.form = null;
    }
    if (!row) { renderDraft(cell, page, emit); return; }
    if (!session || !detail) { loadingNote(cell); return; }
    row = session;
    var view = panePage(page, detail, row);
    var submissions = global.CodexBridgeDesktopWorkbenchSubmissions;
    var inputs = conversationInputs(page, detail, submissions ? submissions.revision() : 0, row);
    if (!sameInputs(cell.inputs, inputs)) {
      cell.inputs = inputs;
      if (!cell.conversation) {
        S.clear(cell.body);
        cell.conversation = S.node("div", "workbench-pane-conversation");
        cell.body.appendChild(cell.conversation);
      }
      global.CodexBridgeDesktopWorkbenchConversation.render(
        cell.conversation, detail.conversation || [], view, emit, { owner: cell.body });
      if (cell.following) cell.body.scrollTop = cell.body.scrollHeight;
    }
    if (!cell.form || cell.taskID !== detail.taskID) {
      S.clear(cell.composer);
      var hooks = global.CodexBridgeDesktopWorkbenchControls.paneHooks(
        function () { return panePage(context.page || {}, cell.detail); },
        function () { return cell.form; });
      cell.form = global.CodexBridgeDesktopWorkbenchSessionComposer.create(detail, emit, hooks);
      if (cell.form.__inputControl) cell.form.__inputControl.id = "workbench-pane-input-" + cell.index;
      cell.form.querySelectorAll("select").forEach(function (control) {
        if (control.id === "workbench-steer-mode") control.id = "workbench-pane-mode-" + cell.index;
      });
      cell.composer.appendChild(cell.form);
      cell.taskID = detail.taskID;
    }
    cell.detail = detail;
    cell.form.__update(detail, view, emit);
  }

  function hide() {
    drafts.forEach(function (draft) { if (draft) draft.unmount(); });
    // Hidden panes lose their scroll offset, so they redraw (and follow the end) when shown again.
    cells.forEach(function (cell) { cell.inputs = null; if (cell.blank === "draft") cell.blank = null; });
    if (ensureRoot()) root.hidden = true;
    var pane = document.getElementById("workbench-inspector-pane");
    if (pane) pane.classList.remove("is-split");
    sendPanes([]);
  }

  // Returns whether the split view owns the inspector this render.
  function render(page, emit) {
    context.page = page; context.emit = emit;
    ensureButton(); updateButton();
    var current = layout();
    // Pane drafts take their submission receipts even while the single view is shown.
    if (page) drafts.forEach(function (draft) { if (draft) draft.receive(page, emit); });
    if (!ensureRoot() || !page || current.count < 2) { hide(); return false; }
    if (focusedIndex >= current.count) focusedIndex = 0;
    follow(page, current.count);
    var rows = assignment(page, current.count);
    var details = new Map(S.safeArray(page.paneTasks).map(function (detail) { return [detail.taskID, detail]; }));
    sendPanes(rows.filter(function (row) { return row && row !== "loading"; }).map(function (row) { return row.taskID; }));
    root.hidden = false;
    root.dataset.layout = current.id;
    var pane = document.getElementById("workbench-inspector-pane");
    if (pane) pane.classList.add("is-split");
    while (cells.length < current.count) cells.push(createCell(cells.length));
    cells.forEach(function (cell, index) {
      var active = index < current.count;
      if (active && cell.root.parentNode !== root) root.appendChild(cell.root);
      if (!active && cell.root.parentNode) {
        cell.root.remove(); cell.inputs = null;
        if (cell.blank === "draft") { draftOf(index).unmount(); cell.blank = null; }
      }
    });
    rows.forEach(function (row, index) {
      var cell = cells[index];
      cell.root.classList.toggle("is-focused", index === focusedIndex);
      renderCell(cell, page, row, row && row !== "loading" ? details.get(row.taskID) : null, emit);
    });
    return true;
  }

  global.CodexBridgeDesktopWorkbenchPanes = {
    render: render,
    hide: hide,
    isSplit: isSplit,
    reveal: reveal,
    openDraft: openDraft,
    closeSession: closeSession,
    // The session key of the focused pane, or null while it holds a draft or the view is single.
    focusedKey: function () {
      var cell = cells[focusedIndex];
      return isSplit() && cell && typeof cell.key === "string" && cell.key.indexOf("s:") === 0 ? cell.key : null;
    },
    layouts: function () { return LAYOUTS.slice(); },
    choose: choose
  };
}(window));
