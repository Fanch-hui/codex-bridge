(function (global) {
  "use strict";

  var S = global.CodexBridgeDesktopPageSupport;
  var drafts = new Map(), pendingSubmissions = new Map(), currentKey = null;
  var persistedDrafts, draftStorageKey = "codexbridge.workbench.drafts.v1";
  var submissionSequence = 0;
  var controls = null, status = null;

  function render(page, emit) {
    var footer = document.getElementById("workbench-inspector-footer");
    if (!controls) {
      controls = S.node("div", "workbench-controls");
      status = S.node("div", "workbench-status-bar");
      footer.appendChild(controls);
      footer.appendChild(status);
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
    controls.__receiptID = page && page.commandReceipt ? page.commandReceipt.receiptID : null;
    acknowledgeSubmission(page);
    var modes = page ? S.safeArray(page.steerModes) : [];
    var kind = detail && detail.canSteer === true ? "steer" : detail && (detail.canResume || detail.canRestart) ? "retry" : "";
    var key = detail ? JSON.stringify([detail.taskID, kind, detail.canResume, detail.canRestart, modes]) : "";
    if (key !== currentKey) {
      var updateControls = function () {
        var focused = captureFocus();
        S.clear(controls);
        controls.__activeForm = null;
        if (kind === "steer") {
          controls.__activeForm = steerForm(detail, modes, emit, controls.__receiptID);
          controls.appendChild(controls.__activeForm);
        }
        if (kind === "retry") {
          controls.__activeForm = retryForm(detail, emit, controls.__receiptID);
          controls.appendChild(controls.__activeForm);
        }
        currentKey = key;
        S.autoGrowTextArea(controls.__activeForm && controls.__activeForm.__inputControl);
        restoreFocus(focused, detail);
      };
      var renderControlsStable = global.CodexBridgeDesktopStableRender;
      if (renderControlsStable) renderControlsStable(controls, key, updateControls);
      else updateControls();
    }
    if (global.CodexBridgeDesktopWorkbenchHandoff) {
      global.CodexBridgeDesktopWorkbenchHandoff.render(
        detail, emit, page && page.commandReceipt
      );
    }
    var statusSignature = JSON.stringify([
      page && page.engineStatus,
      page && page.selectedTaskID
    ]);
    var renderStatusStable = global.CodexBridgeDesktopStableRender;
    if (renderStatusStable) {
      renderStatusStable(status, statusSignature, function () { renderStatus(page, emit); });
    } else {
      renderStatus(page, emit);
    }
  }

  function newSubmissionRequestID() {
    submissionSequence += 1;
    return "workbench-" + Date.now().toString(36) + "-" + submissionSequence + "-"
      + Math.random().toString(36).slice(2, 10);
  }

  function acknowledgeSubmission(page) {
    var receipt = page && page.commandReceipt;
    if (!receipt || !receipt.receiptID || !receipt.requestID || !receipt.command) return;
    var receiptInput = receipt.input == null ? null : receipt.input;
    pendingSubmissions.forEach(function (pending, taskID) {
      if (pending.baselineReceiptID && pending.baselineReceiptID === receipt.receiptID) return;
      if (pending.requestID !== receipt.requestID || pending.command !== receipt.command
        || pending.taskID !== receipt.taskID || pending.input !== receiptInput) return;
      pendingSubmissions.delete(taskID);
      var draft = draftFor(taskID);
      if (receipt.accepted === true && draft.input === pending.input) {
        draft.input = "";
        persistDraft(taskID, draft);
        var form = controls && controls.__activeForm;
        if (form && form.__taskID === taskID && form.__inputControl) {
          form.__inputControl.value = "";
          S.autoGrowTextArea(form.__inputControl);
        }
      }
      var activeForm = controls && controls.__activeForm;
      if (activeForm && activeForm.__validate) activeForm.__validate();
    });
  }

  function renderStatus(page, emit) {
    S.clear(status);
    status.appendChild(S.node("span", "footer-status-text", page ? page.engineStatus || "等待引擎状态" : "等待本机 Service"));
    var refresh = S.button(
      "刷新", null, {}, emit, "small link-button", !page || !page.selectedTaskID
    );
    refresh.title = "刷新当前对话";
    refresh.addEventListener("click", function () {
      if (page && page.selectedTaskID) emit("refreshConversation", { taskID: page.selectedTaskID });
    });
    status.appendChild(refresh);
  }

  function draftFor(taskID) {
    if (!drafts.has(taskID)) {
      var stored = readPersistedDrafts()[taskID];
      drafts.set(taskID, {
        input: stored && typeof stored.input === "string" ? stored.input : "",
        mode: stored && typeof stored.mode === "string" ? stored.mode : "queued"
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

  function inputField(detail, label, placeholder) {
    var draft = draftFor(detail.taskID);
    var field = S.textAreaField(label, draft.input, placeholder, "full");
    field.control.id = "workbench-task-input";
    field.control.classList.add("workbench-message-input");
    field.control.setAttribute("aria-label", label);
    field.control.dataset.taskID = detail.taskID;
    field.wrapper.querySelector("label").htmlFor = field.control.id;
    field.wrapper.querySelector("label").hidden = label === "消息";
    field.control.addEventListener("input", function () {
      draft.input = field.control.value;
      persistDraft(detail.taskID, draft);
      S.autoGrowTextArea(field.control);
    });
    S.autoGrowTextArea(field.control);
    return field;
  }

  function steerForm(detail, modes, emit, baselineReceiptID) {
    var draft = draftFor(detail.taskID), form = S.node("div", "steer-form");
    var grid = S.node("div", "form-grid workbench-steer-grid");
    var input = inputField(detail, "补充指令", "当前轮完成后继续");
    grid.appendChild(input.wrapper);
    var options = modes.length ? modes : [{ id: "queued", title: "当前轮结束后继续" }];
    if (!options.some(function (mode) { return mode.id === draft.mode && mode.enabled !== false; })) draft.mode = options[0].id;
    var mode = S.selectField("发送方式", draft.mode, options, function (value) {
      draft.mode = value;
      persistDraft(detail.taskID, draft);
    }, "");
    mode.control.id = "workbench-steer-mode";
    mode.control.dataset.taskID = detail.taskID;
    mode.wrapper.querySelector("label").htmlFor = mode.control.id;
    if (options.length > 1) {
      grid.classList.add("has-mode");
      grid.appendChild(mode.wrapper);
    }
    var send = S.button("发送指令", null, {}, emit, "small primary", false);
    var actions = S.node("div", "form-actions workbench-steer-actions");
    actions.appendChild(send);
    grid.appendChild(actions);
    var hint = S.node("p", "hint");
    hint.id = "workbench-input-hint";
    input.control.setAttribute("aria-describedby", hint.id);
    function validate() {
      var value = input.control.value;
      var invalid = value.indexOf("\u0000") >= 0 || new TextEncoder().encode(value).length > 32768;
      var pending = pendingSubmissions.has(detail.taskID);
      send.disabled = pending || !value.trim() || invalid;
      send.textContent = "发送指令";
      send.setAttribute("aria-busy", String(pending));
      send.setAttribute("data-pending", String(pending));
      hint.textContent = invalid ? "指令不能包含 NUL 字符，且不能超过 32768 字节。" : "";
      hint.hidden = !invalid;
      input.control.setAttribute("aria-invalid", String(invalid));
    }
    function submit() {
      if (send.disabled) return;
      var value = input.control.value;
      var requestID = newSubmissionRequestID();
      pendingSubmissions.set(detail.taskID, {
        command: "steerTask",
        requestID: requestID,
        baselineReceiptID: baselineReceiptID,
        taskID: detail.taskID,
        input: value
      });
      validate();
      emit("steerTask", { taskID: detail.taskID, input: value, mode: draft.mode }, requestID);
    }
    input.control.addEventListener("input", validate);
    input.control.addEventListener("keydown", function (event) {
      if (event.key === "Enter" && !event.shiftKey && !event.isComposing) {
        event.preventDefault(); submit();
      }
    });
    send.addEventListener("click", submit);
    form.appendChild(grid); form.appendChild(hint);
    form.__taskID = detail.taskID;
    form.__inputControl = input.control;
    form.__validate = validate;
    validate();
    return form;
  }

  function retryForm(detail, emit, baselineReceiptID) {
    var form = S.node("div", "retry-form"), draft = draftFor(detail.taskID);
    var actions = S.node("div", "form-actions");
    var resumeButton = null, restartButton = null;
    var queueLabel = S.node("label", "checkbox-row");
    var queueInput = S.node("input"); queueInput.type = "checkbox";
    queueInput.checked = !!draft.queueIfBusy;
    queueInput.addEventListener("change", function () { draft.queueIfBusy = queueInput.checked; });
    queueLabel.appendChild(queueInput);
    queueLabel.appendChild(S.node("span", null, "项目忙时排队"));
    form.appendChild(queueLabel);
    if (detail.canResume) {
      var input = inputField(detail, "消息", "输入下一条指令，沿用当前会话上下文");
      form.appendChild(input.wrapper);
      function resume() {
        if (resumeButton.disabled) return;
        var value = input.control.value;
        var requestID = newSubmissionRequestID();
        pendingSubmissions.set(detail.taskID, {
          command: "resumeTask",
          requestID: requestID,
          baselineReceiptID: baselineReceiptID,
          taskID: detail.taskID,
          input: value
        });
        validate();
        emit("resumeTask", { taskID: detail.taskID, input: value || null, ...(queueInput.checked ? { queueIfBusy: true } : {}) }, requestID);
      }
      resumeButton = S.button("发送", null, {}, emit, "small primary", false);
      resumeButton.addEventListener("click", resume);
      input.control.addEventListener("keydown", function (event) {
        if (event.key === "Enter" && !event.shiftKey && !event.isComposing) {
          event.preventDefault(); resume();
        }
      });
      form.__taskID = detail.taskID;
      form.__inputControl = input.control;
      actions.appendChild(resumeButton);
    }
    if (detail.canRestart) {
      restartButton = S.button("重新开始", null, {}, emit, "small", false);
      restartButton.addEventListener("click", function () {
        if (restartButton.disabled) return;
        if (!global.confirm("使用原始指令在当前项目开启全新会话？")) return;
        var requestID = newSubmissionRequestID();
        pendingSubmissions.set(detail.taskID, {
          command: "restartTask",
          requestID: requestID,
          baselineReceiptID: baselineReceiptID,
          taskID: detail.taskID,
          input: null
        });
        validate();
        emit("restartTask", { taskID: detail.taskID, ...(queueInput.checked ? { queueIfBusy: true } : {}) }, requestID);
      });
      actions.appendChild(restartButton);
    }
    function validate() {
      var pending = pendingSubmissions.has(detail.taskID);
      if (resumeButton) {
        resumeButton.disabled = pending;
        resumeButton.textContent = "发送";
        resumeButton.setAttribute("aria-busy", String(pending));
        resumeButton.setAttribute("data-pending", String(pending));
      }
      if (restartButton) {
        restartButton.disabled = pending;
        restartButton.textContent = "重新开始";
        restartButton.setAttribute("aria-busy", String(pending));
        restartButton.setAttribute("data-pending", String(pending));
      }
    }
    form.appendChild(actions);
    form.__validate = validate;
    validate();
    return form;
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

  global.CodexBridgeDesktopWorkbenchControls = { render: render };
}(window));
