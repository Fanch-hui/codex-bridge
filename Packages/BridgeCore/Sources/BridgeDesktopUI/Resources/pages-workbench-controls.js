(function (global) {
  "use strict";

  var S = global.CodexBridgeDesktopPageSupport;
  var drafts = new Map(), currentKey = null;
  var controls = null, status = null;

  function render(page, emit) {
    var footer = document.getElementById("workbench-inspector-footer");
    if (!controls) {
      controls = S.node("div", "workbench-controls");
      status = S.node("div", "workbench-status-bar");
      footer.appendChild(controls);
      footer.appendChild(status);
    }
    var detail = page && page.selectedTask;
    var modes = page ? S.safeArray(page.steerModes) : [];
    var kind = detail && detail.canSteer === true ? "steer" : detail && (detail.canResume || detail.canRestart) ? "retry" : "";
    var key = detail ? JSON.stringify([detail.taskID, kind, detail.canResume, detail.canRestart, modes]) : "";
    if (key !== currentKey) {
      var focused = captureFocus();
      S.clear(controls);
      if (kind === "steer") controls.appendChild(steerForm(detail, modes, emit));
      if (kind === "retry") controls.appendChild(retryForm(detail, emit));
      currentKey = key;
      restoreFocus(focused, detail);
    }
    S.clear(status);
    status.appendChild(S.node("span", "footer-status-text", page ? page.engineStatus || "等待引擎状态" : "等待本机 Service"));
    var refresh = S.button("刷新", null, {}, emit, "small link-button", false);
    refresh.title = "刷新状态与当前会话";
    refresh.addEventListener("click", function () {
      emit("refresh", {});
      if (page && page.selectedTaskID) emit("refreshConversation", { taskID: page.selectedTaskID });
    });
    status.appendChild(refresh);
  }

  function draftFor(taskID) {
    if (!drafts.has(taskID)) drafts.set(taskID, { input: "", mode: "queued" });
    return drafts.get(taskID);
  }

  function inputField(detail, label, placeholder) {
    var draft = draftFor(detail.taskID);
    var field = S.textField(label, draft.input, placeholder, "full");
    field.control.id = "workbench-task-input";
    field.control.dataset.taskID = detail.taskID;
    field.wrapper.querySelector("label").htmlFor = field.control.id;
    field.control.addEventListener("input", function () { draft.input = field.control.value; });
    return field;
  }

  function steerForm(detail, modes, emit) {
    var draft = draftFor(detail.taskID), form = S.node("div", "steer-form");
    var grid = S.node("div", "form-grid workbench-steer-grid");
    var input = inputField(detail, "补充指令", "当前轮完成后继续");
    grid.appendChild(input.wrapper);
    var options = modes.length ? modes : [{ id: "queued", title: "当前轮结束后继续" }];
    if (!options.some(function (mode) { return mode.id === draft.mode && mode.enabled !== false; })) draft.mode = options[0].id;
    var mode = S.selectField("发送方式", draft.mode, options, function (value) { draft.mode = value; }, "");
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
      send.disabled = !value.trim() || invalid;
      hint.textContent = invalid ? "指令不能包含 NUL 字符，且不能超过 32768 字节。" : "";
      hint.hidden = !invalid;
      input.control.setAttribute("aria-invalid", String(invalid));
    }
    function submit() {
      if (send.disabled) return;
      var value = input.control.value;
      draft.input = "";
      input.control.value = "";
      validate();
      emit("steerTask", { taskID: detail.taskID, input: value, mode: draft.mode });
    }
    input.control.addEventListener("input", validate);
    input.control.addEventListener("keydown", function (event) {
      if (event.key === "Enter" && !event.isComposing) { event.preventDefault(); submit(); }
    });
    send.addEventListener("click", submit);
    form.appendChild(grid); form.appendChild(hint);
    validate();
    return form;
  }

  function retryForm(detail, emit) {
    var form = S.node("div", "retry-form"), draft = draftFor(detail.taskID);
    var actions = S.node("div", "form-actions");
    if (detail.canResume) {
      var input = inputField(detail, "补充说明", "输入下一条指令，沿用当前会话上下文");
      form.appendChild(input.wrapper);
      function resume() {
        var value = input.control.value;
        draft.input = ""; input.control.value = "";
        emit("resumeTask", { taskID: detail.taskID, input: value || null });
      }
      var button = S.button("继续对话", null, {}, emit, "small primary", false);
      button.addEventListener("click", resume);
      input.control.addEventListener("keydown", function (event) {
        if (event.key === "Enter" && !event.isComposing) { event.preventDefault(); resume(); }
      });
      actions.appendChild(button);
    }
    if (detail.canRestart) {
      var restart = S.button("重新开始", null, {}, emit, "small", false);
      restart.addEventListener("click", function () {
        if (!global.confirm("使用原始指令在当前项目开启全新会话？")) return;
        draft.input = "";
        if (input) input.control.value = "";
        emit("restartTask", { taskID: detail.taskID });
      });
      actions.appendChild(restart);
    }
    form.appendChild(actions);
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
