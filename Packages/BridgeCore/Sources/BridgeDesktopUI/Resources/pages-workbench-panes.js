(function (global) {
  "use strict";
  // Split view of the web workbench, modelled on the macOS "Fill & Arrange" layouts: up to
  // four Agent sessions side by side, each pane with its own live conversation and composer.
  // The layout and the sessions per pane are remembered in this browser only and span every
  // project (earlier builds kept one list per project, which is merged); the host streams one
  // conversation per pane (`paneTasks`) after `setWorkbenchPanes`.
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
  var context = { page: null, emit: null }, focusedIndex = 0;

  function persist() {
    try { global.localStorage.setItem(storageKey, JSON.stringify(saved)); } catch (_) {}
  }
  function tabs() { return global.CodexBridgeDesktopWorkbenchTabs; }
  function layout() {
    return LAYOUTS.find(function (item) { return item.id === saved.layout; }) || LAYOUTS[0];
  }
  function draftOpen() {
    var panel = global.CodexBridgeDesktopWorkbenchNewTask;
    return !!panel && panel.isOpen();
  }
  function keyOf(row) { return tabs() ? tabs().sessionKey(row) : "s:" + row.taskID; }

  // Fills each pane with the session saved for it, else the selected session or an open tab,
  // without showing one session twice. Panes beyond the open tabs stay blank for a new task
  // rather than pulling sessions back from history.
  function assignment(page, count) {
    var rows = S.safeArray(page.tasks), byKey = new Map(), used = new Set(), result = [];
    rows.forEach(function (row) { byKey.set(keyOf(row), row); });
    var wanted = S.safeArray(saved.panes);
    var selected = rows.find(function (row) { return row.selected; });
    var open = tabs() ? tabs().openKeys(page) : [];
    var candidates = (selected ? [keyOf(selected)] : []).concat(open);
    for (var index = 0; index < count; index += 1) {
      var key = wanted[index];
      if (key === "__draft__") {
        result.push(null);
        continue;
      }
      if (!byKey.has(key) || used.has(key) || open.indexOf(key) < 0) {
        key = candidates.find(function (candidate) { return byKey.has(candidate) && !used.has(candidate); });
      }
      if (key) used.add(key);
      result.push(key ? byKey.get(key) : null);
    }
    saved.panes = result.map(function (row, idx) {
      return row ? keyOf(row) : (wanted[idx] === "__draft__" ? "__draft__" : null);
    });
    persist();
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
  function choose(id) {
    saved.layout = id; persist();
    if (menu) menu.hidden = true;
    if (id !== "single" && draftOpen()) global.CodexBridgeDesktopWorkbenchNewTask.close();
    rerender();
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
      var list = S.safeArray(saved.panes).slice();
      var chosen = cell.picker.value;
      var other = chosen ? list.indexOf(chosen) : -1;
      if (other >= 0 && other !== index) list[other] = list[index] || null;
      list[index] = chosen || "__draft__";
      saved.panes = list; persist();
      // A session shown in a pane is an open session, so it also gets a tab.
      if (chosen && tabs()) tabs().open(context.page, chosen);
      rerender();
    });
    cell.status = S.node("span", "workbench-pane-status");
    header.appendChild(cell.picker); header.appendChild(cell.status);
    cell.body = S.node("div", "workbench-pane-body");
    cell.body.addEventListener("scroll", function () {
      cell.following = cell.body.scrollHeight - cell.body.clientHeight - cell.body.scrollTop <= 40;
    }, { passive: true });
    cell.composer = S.node("div", "workbench-controls workbench-pane-composer");
    cell.root.appendChild(header); cell.root.appendChild(cell.body); cell.root.appendChild(cell.composer);
    return cell;
  }

  // The focused pane is the selected session, so the toolbar, tabs and approvals follow it.
  function focus(cell) {
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
    var options = [{ id: "", title: "新建 Agent 任务" }];
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
      options.forEach(function (option) { addOption(cell.picker, option); });
      grouped.forEach(function (group) {
        var target = cell.picker;
        if (projects.length > 1) { target = S.node("optgroup"); target.label = group.title; cell.picker.appendChild(target); }
        group.options.forEach(function (option) { addOption(target, option); });
      });
    }
    cell.picker.value = row ? keyOf(row) : "";
  }

  function newTask() { return global.CodexBridgeDesktopWorkbenchNewTask; }

  // The first blank pane hosts the new task draft; further blank panes stay empty.
  function renderBlank(cell, page, emit, hostsDraft) {
    if (hostsDraft) {
      if (cell.blank !== "draft") { S.clear(cell.body); S.clear(cell.composer); cell.blank = "draft"; }
      newTask().mount(cell.body, cell.composer, page, emit);
      return;
    }
    if (cell.blank === "empty") return;
    if (cell.blank === "draft") newTask().unmount();
    S.clear(cell.body); S.clear(cell.composer); cell.blank = "empty";
    cell.body.appendChild(S.node("p", "workbench-pane-empty", "在上方选择会话，或用标签栏的 + 新建 Agent 任务。"));
  }

  function renderCell(cell, page, row, detail, emit, hostsDraft) {
    updatePicker(cell, page, row);
    cell.root.classList.toggle("is-running", !!(row && row.isRunning));
    cell.status.textContent = row ? row.status || "" : "";
    var key = row ? keyOf(row) : null;
    if (cell.key !== key) {
      if (cell.blank === "draft") newTask().unmount();
      cell.key = key; cell.taskID = null; cell.detail = null; cell.inputs = null; cell.following = true; cell.blank = null;
      S.clear(cell.body); cell.conversation = null;
      S.clear(cell.composer); cell.form = null;
    }
    if (!row) { renderBlank(cell, page, emit, hostsDraft); return; }
    if (!detail) {
      if (!cell.conversation) {
        S.clear(cell.body);
        cell.body.appendChild(S.node("p", "workbench-pane-empty", "正在载入会话…"));
      }
      return;
    }
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
    if (newTask()) newTask().unmount();
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
    if (!ensureRoot() || !page || current.count < 2 || draftOpen()) { hide(); return false; }
    var rows = assignment(page, current.count);
    var details = new Map(S.safeArray(page.paneTasks).map(function (detail) { return [detail.taskID, detail]; }));
    sendPanes(rows.filter(Boolean).map(function (row) { return row.taskID; }));
    root.hidden = false;
    root.dataset.layout = current.id;
    var pane = document.getElementById("workbench-inspector-pane");
    if (pane) pane.classList.add("is-split");
    while (cells.length < current.count) cells.push(createCell(cells.length));
    cells.forEach(function (cell, index) {
      var active = index < current.count;
      if (active && cell.root.parentNode !== root) root.appendChild(cell.root);
      if (!active && cell.root.parentNode) { cell.root.remove(); cell.inputs = null; }
    });
    if (focusedIndex >= current.count) focusedIndex = 0;
    var draftIndex = rows.indexOf(null);
    cells.forEach(function (cell, index) {
      if ((index >= current.count || index !== draftIndex) && cell.blank === "draft") {
        newTask().unmount();
        cell.blank = null;
      }
    });
    rows.forEach(function (row, index) {
      var cell = cells[index];
      cell.root.classList.toggle("is-focused", index === focusedIndex);
      renderCell(cell, page, row, row ? details.get(row.taskID) : null, emit, index === draftIndex);
    });
    return true;
  }

  global.CodexBridgeDesktopWorkbenchPanes = {
    render: render,
    hide: hide,
    layouts: function () { return LAYOUTS.slice(); },
    choose: choose
  };
}(window));
