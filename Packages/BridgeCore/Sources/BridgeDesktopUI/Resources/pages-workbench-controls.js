(function (global) {
  "use strict";

  var S = global.CodexBridgeDesktopPageSupport, P = global.CodexBridgeDesktopWorkbenchSubmissions;
  var drafts = new Map(), currentKey = null, currentPage = null;
  var persistedDrafts, draftStorageKey = "codexbridge.workbench.drafts.v1";
  var controls = null, paneComposer = null;

  // Receipts and restored operations settle here whichever layout is shown. In the split view
  // `findPaneComposer(pending)` returns the pane composer of that session, if one is open.
  function receive(page, emit, findPaneComposer) {
    paneComposer = findPaneComposer;
    P.setSettled(function (pending) { applySubmission(pending, emit); });
    var pending = P.acknowledge(page);
    if (pending) applySubmission(pending);
  }

  function render(page, emit) {
    currentPage = page;
    var footer = document.getElementById("workbench-inspector-footer");
    if (!controls) {
      controls = S.node("div", "workbench-controls");
      footer.appendChild(controls);
      if (global.ResizeObserver) {
        var width = 0;
        new global.ResizeObserver(function (entries) {
          var next = entries[0].contentRect.width;
          if (next === width) return;
          width = next;
          S.autoGrowTextArea(controls.__activeForm && controls.__activeForm.__inputControl);
        }).observe(footer);
      }
    }
    var detail = page && page.selectedTask;
    receive(page, emit);
    var key = detail ? draftKey(detail) : "";
    // The same composer keeps serving its session while the session's task or ID changes.
    if (continuesSession(controls.__activeForm, detail)) currentKey = key;
    if (key !== currentKey) {
      var updateControls = function () {
        var focused = captureFocus();
        S.clear(controls);
        controls.__activeForm = null;
        if (detail) {
          controls.__activeForm = global.CodexBridgeDesktopWorkbenchSessionComposer.create(detail, emit, hooks);
          controls.appendChild(controls.__activeForm);
        }
        currentKey = key;
        if (controls.__activeForm) controls.__activeForm.__update(detail, page, emit);
        S.autoGrowTextArea(controls.__activeForm && controls.__activeForm.__inputControl);
        restoreFocus(focused, detail);
      };
      var renderControlsStable = global.CodexBridgeDesktopStableRender;
      if (renderControlsStable) renderControlsStable(controls, key, updateControls);
      else updateControls();
    }
    var form = controls.__activeForm;
    if (continuesSession(form, detail)) form.__update(detail, page, emit);
    if (global.CodexBridgeDesktopWorkbenchHandoff) {
      global.CodexBridgeDesktopWorkbenchHandoff.render(
        detail, emit, page && page.commandReceipt
      );
    }
  }

  function continuesSession(form, owner) { return !!form && !!owner && form.__continues(owner); }

  function applySubmission(pending, emit) {
    if (!paneComposer) { applyTo(pending, emit, controls && controls.__activeForm, currentPage, true); return; }
    var pane = paneComposer(pending);
    applyTo(pending, emit, pane && pane.form, pane && pane.page, false);
  }

  // A split-view pane follows its session through the session row, so only the main
  // composer moves the selection to the follow-up task.
  function applyTo(pending, emit, form, page, followSelection) {
    var shown = continuesSession(form, pending) ? form : null;
    var draft = shown ? shown.__draft : draftFor(pending), value = null;
    draft.error = pending.state === "failed" ? pending.message || "发送失败，请重试。" : "";
    if (pending.state === "accepted" && !pending.visible && draft.input === pending.input) value = "";
    if (pending.state === "failed" && pending.visible && !draft.input) value = pending.input;
    if (value !== null && shown) shown.__setInput(value);
    else if (value !== null) { draft.input = value; persistDraft(pending, draft); }
    if (form && form.__validate) form.__validate();
    if (form && form.__updateQueue) form.__updateQueue();
    if (emit && pending.state === "accepted") {
      emit("refreshTasks", {});
      if (followSelection && pending.command === "resumeTask" && pending.resultingTaskID && page
        && page.selectedTaskID === pending.taskID) {
        emit("selectTask", { taskID: pending.resultingTaskID });
      }
    }
  }

  var draftHooks = { draftKey: draftKey, draftFor: draftFor, persistDraft: persistDraft, rekeyDraft: rekeyDraft };
  var hooks = Object.assign({}, draftHooks, {
    apply: applySubmission,
    begin: function (request) { return P.begin(currentPage, request); }
  });

  // Hooks for a split-view pane composer: drafts are shared by session, submissions are
  // tracked against the pane's own page view.
  function paneHooks(getPage, getForm) {
    return Object.assign({}, draftHooks, {
      apply: function (pending, emit) { applyTo(pending, emit, getForm(), getPage(), false); },
      begin: function (request) { return P.begin(getPage(), request); }
    });
  }

  // A draft belongs to a continuing session (Provider + session ID), not to one of its tasks.
  // `owner` is a task detail or a submission; both carry the three identifiers.
  function draftKey(owner) {
    return JSON.stringify([owner.providerID || "", owner.sessionID || owner.taskID]);
  }

  function draftFor(owner) {
    var key = draftKey(owner);
    if (!drafts.has(key)) {
      // Earlier versions saved drafts under the task ID; such a draft moves over on its next save.
      var saved = readPersistedDrafts(), stored = saved[key] || saved[owner.taskID];
      drafts.set(key, {
        input: stored && typeof stored.input === "string" ? stored.input : "",
        mode: stored && typeof stored.mode === "string" ? stored.mode : "queued",
        modelID: "", effort: ""
      });
    }
    return drafts.get(key);
  }

  function rekeyDraft(previous, next, draft) {
    var from = draftKey(previous), to = draftKey(next);
    if (from === to) return;
    drafts.delete(from); drafts.set(to, draft);
    delete readPersistedDrafts()[from];
    persistDraft(next, draft);
  }

  function readPersistedDrafts() {
    if (persistedDrafts) return persistedDrafts;
    persistedDrafts = {};
    try {
      var raw = global.localStorage && global.localStorage.getItem(draftStorageKey);
      var decoded = raw ? JSON.parse(raw) : {};
      var now = Date.now();
      Object.keys(decoded || {}).forEach(function (key) {
        var item = decoded[key];
        if (item && now - Number(item.updatedAt || 0) <= 7 * 24 * 60 * 60 * 1000) {
          persistedDrafts[key] = item;
        }
      });
    } catch (_) {}
    return persistedDrafts;
  }

  function persistDraft(owner, draft) {
    var stored = readPersistedDrafts(), key = draftKey(owner);
    delete stored[owner.taskID];
    if (!draft.input && draft.mode === "queued") delete stored[key];
    else stored[key] = { input: draft.input || "", mode: draft.mode || "queued", updatedAt: Date.now() };
    try {
      if (global.localStorage) global.localStorage.setItem(draftStorageKey, JSON.stringify(stored));
    } catch (_) {}
  }

  function captureFocus() {
    var element = document.activeElement;
    if (!element || !controls.contains(element)) return null;
    return { id: element.id, taskID: element.dataset.taskID, start: element.selectionStart,
      end: element.selectionEnd, direction: element.selectionDirection };
  }

  function restoreFocus(focused, detail) {
    if (!focused || !detail || focused.taskID !== detail.taskID) return;
    var element = document.getElementById(focused.id);
    if (!element) return;
    element.focus({ preventScroll: true });
    if (typeof focused.start === "number") element.setSelectionRange(focused.start, focused.end, focused.direction);
  }

  global.CodexBridgeDesktopWorkbenchControls = {
    render: render,
    receive: receive,
    paneHooks: paneHooks,
    hasForm: function () { return !!(controls && controls.__activeForm); }
  };
}(window));
