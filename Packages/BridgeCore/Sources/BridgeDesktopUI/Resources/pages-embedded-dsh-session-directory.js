(function (global) {
  "use strict";
  function label(item) {
    return item && (item.title || item.name || item.projections && item.projections.values && item.projections.values.title) || "新对话";
  }
  function createStore(initial) {
    var items = Array.isArray(initial) ? initial.map(function (item) { return Object.assign({}, item); }) : [];
    var ready = false, revision = 0;
    function find(id) { return items.find(function (item) { return item.sessionId === id; }); }
    return {
      begin: function () { return ++revision; },
      commit: function (ticket, values, pending) {
        if (ticket !== revision) return false;
        items = Array.isArray(values) ? values.map(function (item) { return Object.assign({}, item); }) : [];
        (Array.isArray(pending) ? pending : []).forEach(function (job) {
          if (job.phase === "create" && !find(job.sessionId)) items.unshift({ sessionId: job.sessionId, projectID: job.projectID });
        });
        ready = true; return true;
      },
      upsert: function (id, projectID) {
        if (!id || find(id)) return;
        items.unshift({ sessionId: id, projectID: projectID || null }); revision++;
      },
      setProject: function (id, projectID) {
        var index = items.findIndex(function (item) { return item.sessionId === id; });
        if (index >= 0) { items[index] = Object.assign({}, items[index], { projectID: projectID || null }); revision++; }
      },
      invalidate: function () { ready = false; revision++; },
      invalidateRead: function () { revision++; },
      ready: function () { return ready; },
      get: function (id) { var item = find(id); return item ? Object.assign({}, item) : null; },
      items: function () { return items.map(function (item) { return Object.assign({}, item); }); }
    };
  }
  function create(initial, options) {
    var S = global.CodexBridgeDesktopPageSupport, T = global.CodexBridgeDesktopEmbeddedDSHTransport;
    var store = createStore(initial), sidebar = S.node("nav", "dsh-session-list dsh-embedded-sessions"), signature = "";
    var currentState = null, archivedOpen = false, renameDialog = null, renameInput = null, renameStatus = null, renameTargetID = null, renameSaving = false;
    sidebar.setAttribute("aria-label", "对话");

    if (typeof document !== "undefined" && document.addEventListener) {
      document.addEventListener("click", function (event) {
        Array.prototype.forEach.call(sidebar.querySelectorAll("details.dsh-session-menu[open]"), function (menu) {
          if (!menu.contains(event.target)) menu.open = false;
        });
      });
    }

    function ensureRenameDialog() {
      if (renameDialog) return;
      renameDialog = S.node("dialog", "component-dialog dsh-session-rename-dialog");
      renameDialog.setAttribute("aria-label", "编辑会话名称");
      var header = S.node("header", "dsh-settings-header");
      header.appendChild(S.node("h2", null, "编辑会话名称"));
      var closeBtn = S.button("取消", null, {}, null, "small");
      header.appendChild(closeBtn);
      var body = S.node("div", "dsh-settings-body");
      renameInput = S.input("text", "", "输入会话名称");
      body.appendChild(S.field("会话名称", renameInput));
      var actionsRow = S.node("div", "form-actions");
      var saveBtn = S.button("保存", null, {}, null, "primary small");
      actionsRow.appendChild(saveBtn);
      body.appendChild(actionsRow);
      renameStatus = S.node("p", "hint", "");
      body.appendChild(renameStatus);
      renameDialog.appendChild(header);
      renameDialog.appendChild(body);
      function closeRename() {
        if (renameDialog.open && renameDialog.close) renameDialog.close();
        else renameDialog.removeAttribute("open");
      }
      function submitRename() {
        var nextTitle = renameInput.value.trim();
        if (!renameTargetID || !nextTitle || renameSaving) return;
        renameSaving = true;
        saveBtn.disabled = true;
        renameStatus.textContent = "正在保存…";
        T.call("session.rename", { sessionId: renameTargetID, title: nextTitle }).then(function () {
          closeRename();
          return list();
        }).catch(function (error) {
          renameStatus.textContent = error && error.message || "修改名称失败，请重试。";
        }).finally(function () {
          renameSaving = false;
          saveBtn.disabled = false;
        });
      }
      closeBtn.addEventListener("click", closeRename);
      saveBtn.addEventListener("click", submitRename);
      renameInput.addEventListener("keydown", function (event) {
        if (event.key === "Enter" && !global.CodexBridgeDesktopPageSupport.isIMEKeyEvent(event)) { event.preventDefault(); submitRename(); }
      });
      if (typeof document !== "undefined" && document.body) document.body.appendChild(renameDialog);
    }

    function openRename(item) {
      ensureRenameDialog();
      renameTargetID = item.sessionId;
      renameInput.value = label(item);
      renameStatus.textContent = "";
      if (renameDialog.showModal && !renameDialog.open) renameDialog.showModal();
      else renameDialog.setAttribute("open", "");
      renameInput.focus();
      renameInput.select();
    }

    function selectFallbackAfterRemove(removedID) {
      var remaining = store.items().filter(function (entry) {
        return entry.origin !== "subagent" && !entry.archived && entry.sessionId !== removedID;
      });
      if (options.onSelect) options.onSelect(remaining.length ? remaining[0].sessionId : null);
    }

    function toggleArchive(item) {
      var archiving = !item.archived;
      var wasSelected = currentState && currentState.sessionID === item.sessionId;
      T.call(archiving ? "session.archive" : "session.unarchive", { sessionId: item.sessionId }).then(function () {
        return list();
      }).then(function () {
        if (archiving && wasSelected) selectFallbackAfterRemove(item.sessionId);
      }).catch(function (error) {
        if (options.onError) options.onError(error);
      });
    }

    function removeSession(item) {
      var wasSelected = currentState && currentState.sessionID === item.sessionId;
      T.call("session.delete", { sessionId: item.sessionId }).then(function () {
        return list();
      }).then(function () {
        if (wasSelected) selectFallbackAfterRemove(item.sessionId);
      }).catch(function (error) {
        if (options.onError) options.onError(error);
      });
    }

    function renderSessionRow(item, state) {
      var selected = state.navigationActive && item.sessionId === state.sessionID;
      var row = S.node("div", "dsh-session-row" + (selected ? " is-active" : ""));
      row.dataset.sessionId = item.sessionId;
      var button = S.button("", null, {}, null, "dsh-session-button" + (selected ? " is-active" : ""));
      button.setAttribute("aria-current", selected ? "true" : "false");
      button.dataset.sessionId = item.sessionId;
      button.appendChild(S.node("span", "dsh-session-title", label(item)));
      var status = "";
      if (!state.connected) status = "待连接";
      else if (store.ready() && item.running) status = "运行中";
      if (status) button.appendChild(S.node("span", "dsh-session-status", status));
      button.addEventListener("click", function () { options.onSelect(item.sessionId); });
      row.appendChild(button);

      var menu = S.node("details", "dsh-session-menu"); menu.dataset.popup = "";
      var summary = S.node("summary", "dsh-session-menu-toggle");
      summary.setAttribute("aria-label", "会话操作");
      summary.title = "会话操作";
      summary.appendChild(S.icon ? S.icon("ellipsis") : S.node("span", "icon"));
      var actions = S.node("div", "dsh-session-menu-actions");
      var renameBtn = S.button("编辑名称", null, {}, null, "small");
      var archiveBtn = S.button(item.archived ? "取消归档" : "归档会话", null, {}, null, "small");
      var deleteBtn = S.button("删除会话", null, {}, null, "small dsh-session-action-danger");
      renameBtn.addEventListener("click", function (event) {
        if (event && event.stopPropagation) event.stopPropagation();
        menu.open = false;
        openRename(item);
      });
      archiveBtn.addEventListener("click", function (event) {
        if (event && event.stopPropagation) event.stopPropagation();
        menu.open = false;
        toggleArchive(item);
      });
      deleteBtn.addEventListener("click", function (event) {
        if (event && event.stopPropagation) event.stopPropagation();
        menu.open = false;
        removeSession(item);
      });
      menu.addEventListener("toggle", function () {
        if (!menu.open) return;
        Array.prototype.forEach.call(sidebar.querySelectorAll("details.dsh-session-menu[open]"), function (other) {
          if (other !== menu) other.open = false;
        });
      });
      [renameBtn, archiveBtn, deleteBtn].forEach(function (btn) { actions.appendChild(btn); });
      menu.appendChild(summary);
      menu.appendChild(actions);
      row.appendChild(menu);
      return { row: row, button: button };
    }

    function sessionRows(items, state, target, focusTargets) {
      items.forEach(function (item) {
        var rendered = renderSessionRow(item, state);
        target.appendChild(rendered.row);
        focusTargets.set("s:" + item.sessionId, rendered.button);
      });
    }

    function render(state) {
      currentState = state;
      var visible = store.items().filter(function (item) { return item.origin !== "subagent"; });
      var projects = S.safeArray(state.projects);
      var next = JSON.stringify([state.projectID, state.sessionID, state.navigationActive, store.ready(), state.connected,
        state.engineFailed, projects, state.defaultProjectID,
        visible.map(function (item) { return [item.sessionId, label(item), item.running, !!item.archived, item.projectID]; })]);
      if (next === signature) return;
      signature = next;
      var active = typeof document !== "undefined" && document.activeElement, focusTargets = new Map();
      var focusKey = active && active.dataset && (active.dataset.sessionId ? "s:" + active.dataset.sessionId
        : active.dataset.groupId !== undefined ? (active.dataset.groupNew !== undefined ? "n:" : "g:") + active.dataset.groupId : null);
      S.clear(sidebar);
      var activeItems = visible.filter(function (item) { return !item.archived; });
      var archivedItems = visible.filter(function (item) { return !!item.archived; });
      if (!activeItems.length && !archivedItems.length) {
        var emptyLabel = "正在同步对话…";
        if (state.engineFailed) emptyLabel = "等待恢复会话连接。";
        else if (store.ready()) emptyLabel = "还没有对话。";
        sidebar.appendChild(S.node("p", "hint", emptyLabel));
      }
      // Conversations are grouped by project once the project list is known; those started
      // before projects existed belong to the default workspace.
      if (!projects.length) sessionRows(activeItems, state, sidebar, focusTargets);
      else S.groupByProject(activeItems, projects, state.defaultProjectID, function (item) { return item.projectID; }).forEach(function (group) {
        var rendered = S.projectGroup(group, { scope: "chat", newLabel: "新建对话", onNew: options.onNew });
        sessionRows(group.rows, state, rendered.body, focusTargets);
        sidebar.appendChild(rendered.root);
        var toggle = rendered.root.querySelector(".dsh-group-toggle"), add = rendered.root.querySelector(".dsh-group-new");
        focusTargets.set("g:" + group.projectID, toggle);
        if (add) focusTargets.set("n:" + group.projectID, add);
      });
      if (archivedItems.length) {
        var archivedGroup = S.node("details", "dsh-archived-sessions");
        var selectedArchived = archivedItems.some(function (item) { return state.navigationActive && item.sessionId === state.sessionID; });
        archivedGroup.open = archivedOpen || selectedArchived;
        archivedGroup.addEventListener("toggle", function () { archivedOpen = archivedGroup.open; });
        var archivedSummary = S.node("summary", "dsh-archived-summary");
        archivedSummary.appendChild(S.node("span", null, "已归档"));
        archivedSummary.appendChild(S.node("span", "dsh-archived-count", String(archivedItems.length)));
        archivedGroup.appendChild(archivedSummary);
        var archivedList = S.node("div", "dsh-archived-list");
        sessionRows(archivedItems, state, archivedList, focusTargets);
        archivedGroup.appendChild(archivedList);
        sidebar.appendChild(archivedGroup);
      }
      var restored = focusKey && focusTargets.get(focusKey);
      if (restored) restored.focus({ preventScroll: true });
    }
    function list() {
      var generation = options.generation();
      return T.read("session.list", function () {
        var ticket = store.begin();
        return T.call("session.list", {}).then(function (value) {
          if (generation !== options.generation() || !options.connected()) return store.items();
          if (store.commit(ticket, value && value.items, options.pending())) options.onChange();
          return store.items();
        });
      }).catch(function (error) {
        if (options.active() && generation === options.generation()) options.onError(error);
        throw error;
      });
    }
    return { root: sidebar, list: list, render: render, ready: store.ready, get: store.get, items: store.items,
      upsert: store.upsert, setProject: store.setProject, invalidate: store.invalidate, invalidateRead: store.invalidateRead,
      label: function (id) { var item = store.get(id); return item ? label(item) : ""; } };
  }
  var api = { create: create, createStore: createStore, label: label };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  if (global) global.CodexBridgeDesktopEmbeddedDSHSessionDirectory = api;
}(typeof window === "undefined" ? null : window));
