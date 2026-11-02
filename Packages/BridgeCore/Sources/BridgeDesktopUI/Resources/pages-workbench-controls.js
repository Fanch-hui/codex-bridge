(function (global) {
  "use strict";

  var S = global.CodexBridgeDesktopPageSupport, P = global.CodexBridgeDesktopWorkbenchSubmissions;
  var drafts = new Map(), currentKey = null, currentPage = null;
  var persistedDrafts, draftStorageKey = "codexbridge.workbench.drafts.v1";
  var controls = null, status = null;

  function render(page, emit) {
    currentPage = page;
    P.setSettled(function (pending) { applySubmission(pending, emit); });
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
    acknowledgeSubmission(page);
    var modes = page ? S.safeArray(page.steerModes) : [];
    var canRetry = !!(detail && detail.canRestart);
    var kind = detail && detail.canSteer === true ? "steer" : detail && (detail.canResume || canRetry) ? "continue" : "";
    var key = detail ? JSON.stringify([detail.taskID, kind, detail.canResume, canRetry, modes]) : "";
    if (key !== currentKey) {
      var updateControls = function () {
        var focused = captureFocus();
        S.clear(controls);
        controls.__activeForm = null;
        if (kind === "steer") {
          controls.__activeForm = steerForm(detail, modes, emit);
          controls.appendChild(controls.__activeForm);
        }
        if (kind === "continue") {
          controls.__activeForm = continuationForm(detail, emit, canRetry);
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
    if (controls.__activeForm && controls.__activeForm.__updateQueue) controls.__activeForm.__updateQueue();
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

  function acknowledgeSubmission(page) {
    var pending = P.acknowledge(page);
    if (!pending) return;
    applySubmission(pending);
  }

  function applySubmission(pending, emit) {
    var draft = draftFor(pending.taskID), value = null;
    draft.error = pending.state === "failed" ? pending.message || "发送失败，请重试。" : "";
    if (pending.state === "accepted" && !pending.visible && draft.input === pending.input) value = "";
    if (pending.state === "failed" && pending.visible && !draft.input) value = pending.input;
    var form = controls && controls.__activeForm;
    if (value !== null) updateDraft(pending.taskID, value,
      form && form.__taskID === pending.taskID ? form.__inputControl : null);
    if (form && form.__validate) form.__validate();
    if (form && form.__updateQueue) form.__updateQueue();
    if (emit && pending.state === "accepted") {
      emit("refreshTasks", {});
      if (pending.command === "resumeTask" && pending.resultingTaskID && currentPage
        && currentPage.selectedTaskID === pending.taskID) {
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

  function beginSubmission(request, input) {
    return P.begin(currentPage, request);
  }

  function renderStatus(page, emit) {
    S.clear(status);
    status.appendChild(S.node("span", "footer-status-text", page ? page.engineStatus || "等待引擎状态" : "等待后台服务"));

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
      draft.error = "";
      persistDraft(detail.taskID, draft);
      S.autoGrowTextArea(field.control);
    });
    S.autoGrowTextArea(field.control);
    return field;
  }

  function messageComposer(input, className) {
    var form = S.node("div", className + " message-composer");
    var surface = S.node("div", "message-composer-surface");
    var inputRow = S.node("div", "message-composer-input-row");
    var toolbar = S.node("div", "message-composer-toolbar");
    var tools = S.node("div", "message-composer-tools");
    input.wrapper.classList.add("message-composer-input");
    input.wrapper.querySelector("label").hidden = true;
    inputRow.appendChild(input.wrapper); toolbar.appendChild(tools);
    surface.appendChild(inputRow); surface.appendChild(toolbar); form.appendChild(surface);
    return { form: form, toolbar: toolbar, tools: tools };
  }

  function steerForm(detail, modes, emit) {
    var draft = draftFor(detail.taskID);
    var input = inputField(detail, "补充指令", "");
    var composer = messageComposer(input, "steer-form"), form = composer.form;
    var options = modes.length ? modes : [{ id: "queued", title: "当前任务结束后继续" }];
    if (!options.some(function (mode) { return mode.id === draft.mode && mode.enabled !== false; })) draft.mode = options[0].id;
    var mode = S.selectField("发送方式", draft.mode, options, function (value) {
      draft.mode = value;
      persistDraft(detail.taskID, draft);
      updateModeText();
    }, "");
    mode.control.id = "workbench-steer-mode";
    mode.control.dataset.taskID = detail.taskID;
    mode.wrapper.querySelector("label").htmlFor = mode.control.id;
    mode.wrapper.querySelector("label").hidden = true;
    mode.wrapper.classList.add("message-composer-choice");
    if (options.length > 1) {
      composer.tools.appendChild(mode.wrapper);
    }
    var queue = S.node("details", "workbench-queued-menu");
    var queueLabel = S.node("summary"), queueItems = S.node("ul", "workbench-queued-list");
    queue.appendChild(queueLabel); queue.appendChild(queueItems); composer.tools.appendChild(queue);
    function updateQueue() {
      var items = P.queued(currentPage);
      queue.hidden = !items.length;
      queueLabel.textContent = "排队 " + items.length + " 条";
      S.clear(queueItems);
      items.forEach(function (item) { queueItems.appendChild(S.node("li", null, item.input)); });
    }
    var send = S.button("发送指令", null, {}, emit, "small primary", false);
    send.classList.add("workbench-composer-send");
    function updateModeText() {
      var immediate = draft.mode === "interrupt-current-then-continue";
      input.control.placeholder = immediate ? "输入指令，中断当前任务并发送" : "输入指令，当前任务结束后运行";
      send.textContent = immediate ? "中断并发送" : "结束后运行";
      send.title = immediate ? "中断当前任务并继续执行这条指令" : "当前任务结束后执行这条指令";
    }
    updateModeText();
    composer.toolbar.appendChild(send);
    var hint = S.node("span", "hint workbench-composer-hint");
    hint.id = "workbench-input-hint";
    hint.setAttribute("role", "status");
    composer.tools.appendChild(hint);
    input.control.setAttribute("aria-describedby", hint.id);
    function validate() {
      var value = input.control.value;
      var invalid = value.indexOf("\u0000") >= 0 || new TextEncoder().encode(value).length > 32768;
      var pending = P.isPending(detail.taskID);
      send.disabled = pending || !value.trim() || invalid;
      updateModeText();
      send.setAttribute("aria-busy", String(pending));
      send.setAttribute("data-pending", String(pending));
      hint.textContent = invalid ? "指令不能包含 NUL 字符，且不能超过 32768 字节。" : draft.error || "";
      hint.hidden = !hint.textContent;
      input.control.setAttribute("aria-invalid", String(invalid));
    }
    function submit() {
      if (send.disabled) return;
      var value = input.control.value;
      draft.error = "";
      var requestID = P.newRequestID();
      var pending = beginSubmission({
        command: "steerTask", requestID: requestID,
        taskID: detail.taskID, input: value, mode: draft.mode
      }, input.control);
      var payload = { taskID: detail.taskID, input: value, mode: draft.mode };
      var saved = P.sendOperation(pending, payload, function (result) { applySubmission(result, emit); });
      if (pending.visible && saved && pending.state !== "failed") updateDraft(detail.taskID, "", input.control);
      validate();
      updateQueue();
    }
    input.control.addEventListener("input", validate);
    input.control.addEventListener("keydown", function (event) {
      if (event.key === "Enter" && !event.shiftKey && !event.isComposing) {
        event.preventDefault(); submit();
      }
    });
    send.addEventListener("click", submit);
    form.__taskID = detail.taskID;
    form.__inputControl = input.control;
    form.__validate = validate;
    form.__updateQueue = updateQueue;
    validate();
    updateQueue();
    return form;
  }

  function continuationForm(detail, emit, canRetry) {
    var input = null, composer = null, buttons = [];
    if (detail.canResume) {
      input = inputField(detail, "消息", "输入消息，续写当前会话");
      composer = messageComposer(input, "workbench-continuation-form");
      input.control.addEventListener("keydown", function (event) {
        if (event.key === "Enter" && !event.shiftKey && !event.isComposing) {
          event.preventDefault(); submit("resumeTask");
        }
      });
    }
    var form = composer ? composer.form : S.node("div", "workbench-continuation-form");
    var actions = composer ? composer.tools : S.node("div", "form-actions");
    if (input) {
      var send = addAction("插入对话", "resumeTask", "small primary");
      send.classList.add("workbench-composer-send");
      composer.toolbar.appendChild(send);
    }
    if (canRetry) actions.appendChild(addAction("失败重试", "restartTask", "small"));
    function addAction(title, command, style) {
      var button = S.button(title, null, {}, emit, style, false);
      button.addEventListener("click", function () { submit(command); });
      buttons.push(button); return button;
    }
    function submit(command) {
      if (P.isPending(detail.taskID)) return;
      var value = command === "resumeTask" ? input.control.value : null;
      var requestID = P.newRequestID();
      var pending = beginSubmission({
        command: command, requestID: requestID,
        taskID: detail.taskID, input: value
      }, input && input.control);
      var payload = { taskID: detail.taskID };
      if (command === "resumeTask") payload.input = value;
      else payload.attachmentPaths = S.safeArray(detail.attachmentPaths).slice();
      if (command === "resumeTask") {
        var saved = P.sendOperation(pending, payload, function (result) { applySubmission(result, emit); });
        if (pending.visible && saved && pending.state !== "failed") updateDraft(detail.taskID, "", input.control);
      } else emit(command, payload, requestID);
      validate();
    }
    function validate() {
      var pending = P.isPending(detail.taskID);
      buttons.forEach(function (button) {
        button.disabled = pending;
        button.setAttribute("aria-busy", String(pending));
        button.setAttribute("data-pending", String(pending));
      });
    }
    if (!composer) form.appendChild(actions);
    form.__taskID = detail.taskID;
    form.__inputControl = input && input.control;
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
