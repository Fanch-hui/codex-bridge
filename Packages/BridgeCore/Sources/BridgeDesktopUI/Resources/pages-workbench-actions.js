(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  var pendingTaskID = null;

  function render(actions, detail, row, emit, options) {
    options = options || {};
    actions.__detail = detail;
    actions.__emit = emit;
    actions.__canDelete = !!row.canDelete;
    if (pendingTaskID !== detail.taskID || !row.canDelete) pendingTaskID = null;
    if (actions.__taskID !== detail.taskID) {
      S.clear(actions);
      actions.__buttons = Object.create(null);
      actions.__deleteConfirmation = null;
      actions.__taskID = detail.taskID;
      actions.__execution = S.node("div", "workbench-execution-controls");
      actions.__execution.setAttribute("role", "group");
      actions.__execution.setAttribute("aria-label", "执行控制");
      actions.__more = S.node("details", "workbench-more");
      var trigger = S.node("summary", "button small workbench-more-toggle", "更多");
      trigger.setAttribute("aria-label", "会话更多操作");
      actions.__more.appendChild(trigger);
      actions.__menu = S.node("div", "workbench-more-actions");
      actions.__more.appendChild(actions.__menu);
      actions.__more.addEventListener("keydown", function (event) {
        if (event.key !== "Escape" || !actions.__more.open) return;
        event.preventDefault(); actions.__more.open = false; trigger.focus();
      });
      actions.appendChild(actions.__execution); actions.appendChild(actions.__more);
    }
    var buttons = actions.__buttons, specs = [];
    if (detail.canInterrupt) specs.push(["interruptTask", "中断", "small danger", true]);
    if (detail.canStop && !(detail.queuePosition && options.queueControl)) specs.push(["stopTask", "停止", "small danger", true]);
    specs.push(["refreshConversation", "刷新当前对话", "small"]);
    if (detail.resultSummary) specs.push(["copyResult", "复制结果", "small"]);
    if (detail.canOpenNativeSession) specs.push(["openDeepSeekHarnessSession", "打开对应会话", "small"]);
    if (options.showDetails) specs.push(["showDetails", "会话详情", "small"]);
    if (row.canDelete) specs.push(["deleteSession", "删除会话", "small danger"]);
    var active = Object.create(null);
    specs.forEach(function (spec) {
      var command = spec[0], button = buttons[command];
      active[command] = true;
      if (!button) button = buttons[command] = actionButton(actions, spec);
      var parent = spec[3] ? actions.__execution : actions.__menu;
      if (button.parentNode !== parent) parent.appendChild(button);
      if (command === "copyResult" && button.__copyText !== detail.resultSummary) {
        button.__copyText = detail.resultSummary; button.textContent = "复制结果";
      }
      if (command === "interruptTask") {
        var pending = button.__pendingTaskID === detail.taskID;
        button.disabled = pending;
        button.textContent = pending ? "中断请求中…" : "中断";
        button.setAttribute("aria-busy", String(pending));
      }
    });
    Object.keys(buttons).forEach(function (command) {
      if (!active[command]) {
        if (document.activeElement === buttons[command]) actions.__more.firstChild.focus();
        buttons[command].remove(); delete buttons[command];
      }
    });
    actions.__execution.hidden = !actions.__execution.children.length;
    if (!row.canDelete && actions.__deleteConfirmation) {
      actions.__deleteConfirmation.remove(); actions.__deleteConfirmation = null;
    }
    if (actions.__deleteConfirmation && actions.__deleteConfirmation.parentNode !== actions.__menu) {
      actions.__menu.appendChild(actions.__deleteConfirmation);
    }
  }

  function actionButton(actions, spec) {
    var command = spec[0], button = S.button(spec[1], null, {}, null, spec[2], false);
    if (command === "deleteSession") {
      actions.__deleteConfirmation = deleteConfirmation(actions, button);
    } else {
      button.addEventListener("click", function () {
        if (button.disabled) return;
        var detail = actions.__detail, details = global.CodexBridgeDesktopWorkbenchDetails;
        if (command === "showDetails") {
          if (details) details.open(detail, actions.__more.firstChild);
        } else if (command === "copyResult") {
          var text = detail.resultSummary;
          if (details) details.copyResult(text).then(function () {
            if (button.__copyText === text) button.textContent = "已复制";
          }, function () { if (button.__copyText === text) button.textContent = "复制失败，请重试"; });
        } else {
          if (command === "interruptTask") {
            button.__pendingTaskID = detail.taskID;
            button.disabled = true; button.textContent = "中断请求中…";
            button.setAttribute("aria-busy", "true");
          }
          actions.__emit(command, { taskID: detail.taskID });
        }
        if (command !== "copyResult") actions.__more.open = false;
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
