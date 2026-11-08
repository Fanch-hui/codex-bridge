(function (global) {
  "use strict";
  // One composer for an open Agent session, behaving like a native coding agent:
  // - idle sessions continue with the chosen model, effort and permission;
  // - running sessions accept input only when the Agent supports steering, otherwise
  //   the send button becomes a stop button and a short note explains why;
  // - progress is shown in the conversation, the composer only reports problems.
  var S = global.CodexBridgeDesktopPageSupport, P = global.CodexBridgeDesktopWorkbenchSubmissions;
  function C() { return global.CodexBridgeDesktopWorkbenchComposer; }

  function clean(value) {
    var text = typeof value === "string" ? value.trim() : "";
    return text && text !== "provider-default" ? text : null;
  }
  function taskPermission(detail) { return detail.permissionMode === "read-only" ? "read-only" : "full"; }
  // Continuing a session keeps its own permission unless the user picks another one here.
  function chosenPermission(detail, draft) {
    return draft && (draft.permissionMode === "read-only" || draft.permissionMode === "full")
      ? draft.permissionMode : taskPermission(detail);
  }
  function isRunning(detail) {
    if (detail.isTerminal === true) return false;
    if (detail.isTerminal === false) return true;
    return !!(detail.canSteer || detail.canInterrupt || detail.canStop);
  }

  function create(detail, emit, hooks) {
    var draft = hooks.draftFor(detail.taskID), state = { detail: detail, page: null, emit: emit, stopping: false };
    var view = C().create({
      className: "workbench-session-composer", inputID: "workbench-task-input", label: "消息",
      value: draft.input, placeholder: "",
      onSend: submit, onStop: stop,
      onPermission: function (value) { draft.permissionMode = value; refresh(); },
      onModel: function (value) { draft.modelID = value; draft.effort = ""; refresh(); },
      onEffort: function (value) { draft.effort = value; refresh(); }
    });
    view.input.dataset.taskID = detail.taskID;
    var mode = C().choice("发送方式", function (value) {
      draft.mode = value; hooks.persistDraft(detail.taskID, draft); refresh();
    }, "workbench-composer-mode");
    mode.control.id = "workbench-steer-mode";
    mode.control.dataset.taskID = detail.taskID;
    view.trailing.insertBefore(mode.wrapper, view.trailing.firstChild);
    var retry = S.button("重试", null, {}, null, "small workbench-composer-retry", false);
    retry.title = "用原始指令重新开始任务";
    retry.addEventListener("click", function () { restart(); });
    view.leading.appendChild(retry);
    var queue = S.node("details", "workbench-queued-menu"); queue.dataset.popup = "";
    var queueLabel = S.node("summary"), queueItems = S.node("ul", "workbench-queued-list");
    queue.appendChild(queueLabel); queue.appendChild(queueItems); view.leading.appendChild(queue);
    view.input.addEventListener("input", function () {
      draft.input = view.input.value; draft.error = "";
      hooks.persistDraft(detail.taskID, draft); S.autoGrowTextArea(view.input); validate();
    });
    S.autoGrowTextArea(view.input);

    function modes() {
      var options = S.safeArray(state.page && state.page.steerModes).filter(function (item) { return item.enabled !== false; });
      return options.length ? options : [{ id: "queued", title: "插入当前对话" }];
    }
    function selection() {
      var agent = C().agentFor(detail.providerID, detail.installationID);
      return C().setModels(view, agent, draft.modelID, draft.effort || clean(detail.executionEffort),
        clean(detail.executionModel));
    }
    function updateQueue() {
      var items = P.queued(state.page);
      queue.hidden = !items.length;
      queueLabel.textContent = "待发送 " + items.length + " 条";
      S.clear(queueItems);
      items.forEach(function (item) { queueItems.appendChild(S.node("li", null, item.input)); });
    }

    function refresh() {
      var current = state.detail, running = isRunning(current);
      var options = modes();
      if (!options.some(function (item) { return item.id === draft.mode; })) draft.mode = options[0].id;
      forms().selectOptions(mode.control, options, false);
      mode.control.value = draft.mode;
      mode.wrapper.hidden = !(running && current.canSteer === true && options.length > 1);
      selection();
      [view.model, view.effort].forEach(function (control) { control.disabled = running; });
      C().setPermission(view, chosenPermission(current, draft), true);
      retry.hidden = running || current.canRestart !== true;
      if (!running) state.stopping = false;
      view.input.placeholder = running
        ? (current.canSteer === true ? "输入消息，插入当前对话" : "Agent 正在执行…")
        : current.canResume ? "继续对话…" : "该会话无法继续对话";
      updateQueue();
      validate();
    }

    function validate() {
      var current = state.detail, running = isRunning(current), value = view.input.value;
      var invalid = value.indexOf("\u0000") >= 0 || new TextEncoder().encode(value).length > 32768;
      var pending = P.isPending(current.taskID);
      var canSend = running ? current.canSteer === true : current.canResume === true;
      var canStop = running && !!(current.canInterrupt || current.canStop);
      view.input.disabled = !running && !current.canResume;
      if (canStop && (!canSend || !value.trim())) {
        C().setAction(view, "stop", state.stopping, state.stopping ? "正在停止" : "停止");
      } else {
        C().setAction(view, "send", pending || !canSend || !value.trim() || invalid);
      }
      view.action.setAttribute("aria-busy", String(pending));
      view.action.setAttribute("data-pending", String(pending));
      retry.disabled = pending;
      view.input.setAttribute("aria-invalid", String(invalid));
      var note = running && current.canSteer !== true ? "当前 Agent 不支持插入对话，完成后即可发送。" : "";
      C().setHint(view, invalid ? "消息不能包含 NUL 字符，且不能超过 32768 字节。" : draft.error || note);
    }

    function executionSelection() {
      var current = state.detail, chosen = selection();
      var permission = chosenPermission(current, draft);
      var modelChanged = (chosen.modelID || null) !== clean(current.executionModel);
      // Until the user picks an effort, an unchanged model keeps the session's own effort,
      // even while the model catalog (and so the effort list) is still loading.
      var effort = modelChanged || draft.effort ? (chosen.effort || null) : clean(current.executionEffort);
      var changed = modelChanged || effort !== clean(current.executionEffort) || permission !== taskPermission(current);
      return changed ? { modelID: chosen.modelID, effort: effort, permissionMode: permission } : null;
    }

    function submit() {
      if (view.action.disabled || view.action.__mode !== "send") return;
      var current = state.detail, value = view.input.value, running = isRunning(current);
      draft.error = "";
      var command = running ? "steerTask" : "resumeTask";
      var request = { command: command, requestID: P.newRequestID(), taskID: current.taskID, input: value };
      if (running) request.mode = draft.mode;
      var pending = hooks.begin(request);
      var payload = { taskID: current.taskID, input: value };
      if (running) payload.mode = draft.mode;
      else {
        // A continuation waits in the project queue when the concurrent Agent limit is reached.
        payload.queueIfBusy = true;
        var selected = executionSelection();
        if (selected) payload.executionSelection = selected;
      }
      var saved = P.sendOperation(pending, payload, function (result) { hooks.apply(result, state.emit); });
      if (pending.visible && saved && pending.state !== "failed") hooks.updateDraft(current.taskID, "", view.input);
      updateQueue(); validate();
    }
    function restart() {
      var current = state.detail;
      if (P.isPending(current.taskID) || !current.canRestart) return;
      var requestID = P.newRequestID();
      hooks.begin({ command: "restartTask", requestID: requestID, taskID: current.taskID, input: null });
      state.emit("restartTask", { taskID: current.taskID,
        attachmentPaths: S.safeArray(current.attachmentPaths).slice() }, requestID);
      validate();
    }
    function stop() {
      var current = state.detail;
      if (state.stopping) return;
      state.stopping = true;
      state.emit(current.canInterrupt ? "interruptTask" : "stopTask", { taskID: current.taskID });
      validate();
    }

    var form = view.root;
    form.__taskID = detail.taskID;
    form.__inputControl = view.input;
    form.__validate = validate;
    form.__updateQueue = updateQueue;
    form.__update = function (nextDetail, page, nextEmit) {
      state.detail = nextDetail; state.page = page; state.emit = nextEmit;
      if (nextDetail.isTerminal === true || !isRunning(nextDetail)) state.stopping = false;
      refresh();
    };
    return form;
  }
  function forms() { return global.CodexBridgeDesktopFormDraft; }

  global.CodexBridgeDesktopWorkbenchSessionComposer = { create: create, isRunning: isRunning };
}(window));
