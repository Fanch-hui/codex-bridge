(function (global) {
  "use strict";

  var S = global.CodexBridgeDesktopPageSupport, P = global.CodexBridgeDesktopWorkbenchSubmissions;
  var drafts = new Map(), currentKey = null, currentPage = null;
  var persistedDrafts, draftStorageKey = "codexbridge.workbench.drafts.v1";
  var controls = null;

  function render(page, emit) {
    currentPage = page;
    P.setSettled(function (pending) { applySubmission(pending, emit); });
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
    acknowledgeSubmission(page);
    var key = detail ? JSON.stringify([detail.providerID, detail.taskID]) : "";
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
    if (form && detail && form.__taskID === detail.taskID) form.__update(detail, page, emit);
    if (global.CodexBridgeDesktopWorkbenchHandoff) {
      global.CodexBridgeDesktopWorkbenchHandoff.render(
        detail, emit, page && page.commandReceipt
      );
    }
  }

  function acknowledgeSubmission(page) {
    var pending = P.acknowledge(page);
    if (!pending) return;
    applySubmission(pending);
  }

  function applySubmission(pending, emit) {
    applyTo(pending, emit, controls && controls.__activeForm, currentPage, true);
  }

  // A split-view pane follows its session through the session row, so only the main
  // composer moves the selection to the follow-up task.
  function applyTo(pending, emit, form, page, followSelection) {
    var draft = draftFor(pending.taskID), value = null;
    draft.error = pending.state === "failed" ? pending.message || "发送失败，请重试。" : "";
    if (pending.state === "accepted" && !pending.visible && draft.input === pending.input) value = "";
    if (pending.state === "failed" && pending.visible && !draft.input) value = pending.input;
    if (value !== null) updateDraft(pending.taskID, value,
      form && form.__taskID === pending.taskID ? form.__inputControl : null);
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

  function updateDraft(taskID, value, input) {
    var draft = draftFor(taskID);
    draft.input = value;
    persistDraft(taskID, draft);
    if (input) { input.value = value; S.autoGrowTextArea(input); }
  }

  var hooks = {
    draftFor: draftFor, persistDraft: persistDraft, updateDraft: updateDraft, apply: applySubmission,
    begin: function (request) { return P.begin(currentPage, request); }
  };

  // Hooks for a split-view pane composer: drafts are shared by task, submissions are
  // tracked against the pane's own page view.
  function paneHooks(getPage, getForm) {
    return {
      draftFor: draftFor, persistDraft: persistDraft, updateDraft: updateDraft,
      apply: function (pending, emit) { applyTo(pending, emit, getForm(), getPage(), false); },
      begin: function (request) { return P.begin(getPage(), request); }
    };
  }

  function draftFor(taskID) {
    if (!drafts.has(taskID)) {
      var stored = readPersistedDrafts()[taskID];
      drafts.set(taskID, {
        input: stored && typeof stored.input === "string" ? stored.input : "",
        mode: stored && typeof stored.mode === "string" ? stored.mode : "queued",
        modelID: "", effort: ""
      });
    }
    return drafts.get(taskID);
  }

  function readPersistedDrafts() {
    if (persistedDrafts) return persistedDrafts;
    persistedDrafts = {};
    try {
      var raw = global.localStorage && global.localStorage.getItem(draftStorageKey);
      var decoded = raw ? JSON.parse(raw) : {};
      var now = Date.now();
      Object.keys(decoded || {}).forEach(function (taskID) {
        var item = decoded[taskID];
        if (item && now - Number(item.updatedAt || 0) <= 7 * 24 * 60 * 60 * 1000) {
          persistedDrafts[taskID] = item;
        }
      });
    } catch (_) {}
    return persistedDrafts;
  }

  function persistDraft(taskID, draft) {
    var stored = readPersistedDrafts();
    if (!draft.input && draft.mode === "queued") delete stored[taskID];
    else stored[taskID] = { input: draft.input || "", mode: draft.mode || "queued", updatedAt: Date.now() };
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
    paneHooks: paneHooks,
    hasForm: function () { return !!(controls && controls.__activeForm); }
  };
}(window));
