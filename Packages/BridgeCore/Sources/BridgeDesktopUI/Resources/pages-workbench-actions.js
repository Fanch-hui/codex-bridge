(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  var pendingTaskID = null;

  function render(actions, detail, row, emit) {
    actions.__detail = detail;
    actions.__emit = emit;
    actions.__canDelete = !!row.canDelete;
    if (pendingTaskID !== detail.taskID || !row.canDelete) pendingTaskID = null;
    if (actions.__taskID !== detail.taskID) {
      S.clear(actions);
      actions.__buttons = Object.create(null);
      actions.__deleteConfirmation = null;
      actions.__taskID = detail.taskID;
    }
    var buttons = actions.__buttons, specs = [];
    if (detail.canInterrupt) specs.push(["interruptTask", "中断", "small danger"]);
    if (detail.canStop) specs.push(["stopTask", "停止", "small danger"]);
    if (row.canDelete) specs.push(["deleteSession", "删除会话", "small danger"]);
    specs.push(["refreshConversation", "刷新当前对话", "small"]);
    var active = Object.create(null);
    specs.forEach(function (spec, index) {
      var command = spec[0], button = buttons[command];
      active[command] = true;
      if (!button) button = buttons[command] = actionButton(actions, spec);
      var atIndex = actions.children[index];
      if (atIndex !== button) {
        if (atIndex) actions.insertBefore(button, atIndex);
        else actions.appendChild(button);
      }
    });
    Object.keys(buttons).forEach(function (command) {
      if (!active[command]) { buttons[command].remove(); delete buttons[command]; }
    });
    if (!row.canDelete && actions.__deleteConfirmation) {
      actions.__deleteConfirmation.remove();
      actions.__deleteConfirmation = null;
    }
    if (actions.__deleteConfirmation && actions.lastChild !== actions.__deleteConfirmation) {
      actions.appendChild(actions.__deleteConfirmation);
    }
  }

  function actionButton(actions, spec) {
    var command = spec[0], button = S.button(spec[1], null, {}, actions.__emit, spec[2], false);
    if (command === "deleteSession") {
      actions.__deleteConfirmation = deleteConfirmation(actions, button);
    } else {
      button.addEventListener("click", function () {
        actions.__emit(command, { taskID: actions.__detail.taskID });
      });
    }
    return button;
  }

  function deleteConfirmation(actions, trigger) {
    var taskID = actions.__taskID;
    var root = S.node("div", "agent-confirmation session-confirmation");
    root.id = "workbench-session-delete-confirmation";
    root.hidden = pendingTaskID !== taskID;
    root.setAttribute("role", "group");
    root.setAttribute("aria-label", "删除会话确认");
    trigger.setAttribute("aria-controls", root.id);
    trigger.setAttribute("aria-expanded", String(!root.hidden));
    root.appendChild(S.node("span", null, "删除此会话的全部任务、事件和对话记录？此操作无法撤销。"));
    var accept = S.button("确认删除", null, {}, actions.__emit, "small danger", false);
    var cancel = S.button("取消", null, {}, actions.__emit, "small", false);
    root.appendChild(accept);
    root.appendChild(cancel);
    function close() {
      pendingTaskID = null;
      root.hidden = true;
      trigger.setAttribute("aria-expanded", "false");
      trigger.focus();
    }
    trigger.addEventListener("click", function () {
      if (!actions.__canDelete || actions.__taskID !== taskID) return;
      pendingTaskID = taskID;
      root.hidden = false;
      trigger.setAttribute("aria-expanded", "true");
      cancel.focus();
    });
    accept.addEventListener("click", function () {
      if (pendingTaskID !== taskID || !actions.__canDelete || actions.__taskID !== taskID) return;
      var current = actions.__detail;
      close();
      actions.__emit("deleteSession", { taskID: current.taskID, sessionID: current.sessionID });
    });
    cancel.addEventListener("click", close);
    root.addEventListener("keydown", function (event) {
      if (event.key !== "Escape" || root.hidden) return;
      event.preventDefault();
      event.stopPropagation();
      close();
    });
    return root;
  }

  global.CodexBridgeDesktopWorkbenchActions = {
    render: render,
    reset: function () { pendingTaskID = null; }
  };
}(window));
