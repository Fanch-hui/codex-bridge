(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  var T = global.CodexBridgeDesktopEmbeddedDSHTransport;

  function create(options) {
    var context = { sessionID: null, connected: false, running: false, pending: false, title: "" };
    var generation = 0, busy = false, panel = "", controls = [];
    var menu = S.node("details", "dsh-chat-menu"), summary = S.node("summary", "dsh-chat-menu-toggle");
    summary.appendChild(S.icon("ellipsis")); summary.setAttribute("aria-label", "会话操作"); summary.title = "会话操作";
    menu.appendChild(summary);
    var actions = S.node("div", "dsh-chat-menu-actions"); menu.appendChild(actions);
    var root = S.node("div", "dsh-embedded-action-dialogs");
    var dialog = S.node("dialog", "component-dialog"); root.appendChild(dialog);
    dialog.setAttribute("aria-labelledby", "dsh-actions-title");
    var header = S.node("div", "dialog-header"), title = S.node("h2", "", "会话操作");
    title.id = "dsh-actions-title"; header.appendChild(title); dialog.appendChild(header);
    var body = S.node("div", "dialog-body settings-stack"); dialog.appendChild(body);
    var notice = S.node("p", "feedback-message"); notice.setAttribute("role", "status");
    notice.style.whiteSpace = "pre-wrap"; body.appendChild(notice);
    var content = S.node("div", "settings-stack"); body.appendChild(content);
    var footer = S.node("div", "dialog-footer"); dialog.appendChild(footer);
    var closeButton = S.button("关闭", null, {}, null, "small"); footer.appendChild(closeButton);
    closeButton.addEventListener("click", close);
    dialog.addEventListener("close", function () { generation++; panel = ""; });
    var schedules = global.CodexBridgeDesktopEmbeddedDSHSchedules.create({
      transport: T, onError: options.onError, getSessionTitle: options.getSessionTitle,
      getContext: function () { return context; }
    });
    root.appendChild(schedules.root);

    function item(label, callback) {
      var button = S.button(label, null, {}, null, "small");
      button.addEventListener("click", function () { menu.open = false; callback(); });
      actions.appendChild(button);
    }
    item("命令", function () { open("commands"); });
    item("会话管理", function () { open("session"); });
    item("插件", function () { options.openSettings("plugins"); });
    item("任务与提醒", function () { schedules.open(); });

    function update(next) {
      var previous = context;
      context = { sessionID: next.sessionID || null, connected: !!next.connected, running: !!next.running,
        pending: !!next.pending, title: next.title || "" };
      if (previous.sessionID !== context.sessionID || previous.connected && !context.connected) {
        generation++;
        if (dialog.open) close();
      } else if (dialog.open && !previous.connected && context.connected) {
        open(panel);
      }
      syncControls(); schedules.update(context);
    }
    function close() { generation++; panel = ""; if (dialog.open) dialog.close(); }
    function open(nextPanel) {
      panel = nextPanel; generation++; controls = []; notice.textContent = ""; S.clear(content);
      title.textContent = panel === "commands" ? "命令" : "会话管理";
      if (!dialog.open) dialog.showModal();
      if (!context.connected) { notice.textContent = "正在连接工作台。"; return; }
      if (!context.sessionID && panel !== "commands") { notice.textContent = "打开会话后可使用此功能。"; return; }
      if (panel === "commands") showCommands(); else showSession();
    }
    function control(element, disabled) {
      controls.push({ element: element, disabled: disabled }); syncControls();
    }
    function syncControls() {
      controls.forEach(function (entry) {
        entry.element.disabled = busy || !context.connected || context.pending || !!(entry.disabled && entry.disabled());
      });
    }
    function rpc(endpoint, args) {
      return T.call("client.rpc", { channel: "/api", endpoint: endpoint, payload: { args: args } }).then(function (result) {
        if (!result || result.ok !== true) throw new Error(result && result.error && result.error.message || "操作失败，请重试。");
        return result.value;
      });
    }
    function notify(callback, value) {
      if (!callback) return;
      Promise.resolve().then(function () { return callback(value); }).catch(function (error) {
        if (options.onError) options.onError(error);
      });
    }
    function operation(label, action, after) {
      if (busy || !context.sessionID || !context.connected || context.pending) return;
      var sessionID = context.sessionID, ticket = generation;
      busy = true; syncControls(); notice.textContent = label;
      var request;
      try { request = action(); } catch (error) { request = Promise.reject(error); }
      return Promise.resolve(request).then(function (value) {
        var active = ticket === generation && sessionID === context.sessionID && context.connected;
        if (active) notice.textContent = "已完成。";
        if (after) after(value, active);
      }).catch(function (error) {
        if (ticket === generation && sessionID === context.sessionID) {
          notice.textContent = error && error.message || "操作失败，请重试。";
        }
        if (options.onError) options.onError(error);
      }).finally(function () { busy = false; syncControls(); });
    }
    function showCommands() {
      var id = context.sessionID, ticket = generation;
      notice.textContent = "正在读取命令…";
      T.call("commands.list", id ? { sessionId: id } : {}).then(function (value) {
        if (ticket !== generation || id !== context.sessionID) return;
        var rows = value && value.items;
        rows = Array.isArray(rows) ? rows.filter(function (row) {
          return row && typeof row.name === "string" && /^[a-z][a-z0-9_-]*$/.test(row.name);
        }) : [];
        if (!rows.length) { notice.textContent = "当前会话没有可用命令。"; return; }
        var selected = null;
        var choices = [{ id: "", title: "选择命令" }].concat(rows.map(function (row) {
          return { id: row.name, title: "/" + row.name, detail: row.description || "" };
        }));
        var selector = S.selectField("命令", "", choices, function (name) {
          selected = rows.find(function (row) { return row.name === name; }) || null;
          notice.textContent = selected && selected.description || "";
          argument.control.placeholder = selected && selected.input && selected.input.hint || "按需填写参数";
          syncControls();
        });
        content.appendChild(selector.wrapper); control(selector.control);
        var argument = S.textAreaField("命令参数", "", "按需填写参数");
        argument.control.rows = 3; content.appendChild(argument.wrapper); control(argument.control);
        var run = S.button("执行命令", null, {}, null, "small"); content.appendChild(run);
        control(run, function () { return !selected || context.running; });
        notice.textContent = "";
        run.addEventListener("click", function () {
          if (!selected || context.running) return;
          var command = selected.name, text = argument.control.value;
          var line = "/" + command + (text.trim() ? " " + text : "");
          if (!id) return executeNewSessionCommand(line);
          return operation("正在执行命令…", function () {
            return rpc("commands/execute", { agentId: id, line: line, submittedAttachments: [] });
          }, function (execution, active) {
            if (!execution || !execution.result) {
              if (active) notice.textContent = "命令未被识别，请刷新命令列表。";
              return;
            }
            if (active) notice.textContent = execution.result.text || (execution.result.kind === "error" ? "命令执行失败。" : "已完成。");
            notify(options.onSessionsChanged);
          });
        });
      }).catch(function (error) {
        if (ticket === generation && id === context.sessionID) notice.textContent = error.message || "读取命令失败。";
      });
    }
    function executeNewSessionCommand(line) {
      if (busy || !options.ensureCommandSession || !context.connected || context.pending) return;
      busy = true; syncControls(); notice.textContent = "正在准备会话…";
      var id = null, ticket = generation;
      return Promise.resolve().then(options.ensureCommandSession).then(function (sessionId) {
        id = sessionId;
        if (options.onCommandStatus) options.onCommandStatus(id, "正在执行命令…");
        return rpc("commands/execute", { agentId: id, line: line, submittedAttachments: [] });
      }).then(function (execution) {
        if (!execution || !execution.result) throw new Error("命令未被识别，请刷新命令列表。");
        var result = execution.result;
        if (options.onCommandStatus) options.onCommandStatus(id, result.text || (result.kind === "error" ? "命令执行失败。" : "命令已完成。"));
        notify(options.onSessionsChanged);
      }).catch(function (error) {
        if (ticket === generation) notice.textContent = error && error.message || "命令执行失败。";
        if (options.onError) options.onError(error);
      }).finally(function () { busy = false; syncControls(); });
    }
    function showSession() {
      var id = context.sessionID;
      var field = S.textField("会话名称", context.title, "会话名称"); content.appendChild(field.wrapper); control(field.control);
      var row = S.node("div", "form-actions"); content.appendChild(row);
      var rename = S.button("重命名", null, {}, null, "small"), fork = S.button("分叉会话", null, {}, null, "small");
      row.appendChild(rename); row.appendChild(fork); control(rename); control(fork, function () { return context.running; });
      rename.addEventListener("click", function () {
        var value = field.control.value.trim();
        if (!value) { notice.textContent = "请填写会话名称。"; return; }
        return operation("正在重命名…", function () { return T.call("session.rename", { sessionId: id, title: value }); }, function () {
          notify(options.onSessionsChanged);
        });
      });
      fork.addEventListener("click", function () {
        if (context.running) return;
        return operation("正在分叉会话…", function () { return T.call("session.fork", { sessionId: id }); }, function (result, active) {
          notify(options.onSessionsChanged);
          if (!active) return;
          if (!result || !result.sessionId) { notice.textContent = "分叉已创建，请刷新会话列表。"; return; }
          close(); notify(options.onOpenSession, result.sessionId);
        });
      });
    }
    function dispose() { close(); schedules.dispose(); }
    return { menu: menu, root: root, update: update, dispose: dispose,
      openCommands: function () { open("commands"); } };
  }
  global.CodexBridgeDesktopEmbeddedDSHActions = { create: create };
}(window));
