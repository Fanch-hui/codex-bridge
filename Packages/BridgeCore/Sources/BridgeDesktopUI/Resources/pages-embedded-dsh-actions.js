(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  var T = global.CodexBridgeDesktopEmbeddedDSHTransport;

  function create(options) {
    var context = { sessionID: null, connected: false, running: false, pending: false, title: "" };
    var generation = 0, busy = false, controls = [];
    var menu = S.node("div", "dsh-chat-menu");
    menu.hidden = true;
    var root = S.node("div", "dsh-embedded-action-dialogs");
    var commandRows = [], commandScope = "", commandLoading = false, commandPicker = null;

    function update(next) {
      var previous = context;
      context = { sessionID: next.sessionID || null, connected: !!next.connected, running: !!next.running,
        pending: !!next.pending, title: next.title || "" };
      if (previous.sessionID !== context.sessionID || previous.connected && !context.connected) {
        generation++; commandRows = []; commandScope = ""; commandLoading = false;
        if (commandPicker) commandPicker.hide();
      }
      if (commandPicker && (context.running || context.pending || !context.connected)) commandPicker.hide();
      syncControls();
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
    function loadCommands() {
      var id = context.sessionID, ticket = generation, scope = JSON.stringify([id, ticket]);
      if (!context.connected) return Promise.resolve([]);
      if (commandScope === scope && (commandRows.length || commandLoading)) return Promise.resolve(commandRows);
      commandScope = scope; commandLoading = true;
      return T.call("commands.list", id ? { sessionId: id } : {}).then(function (value) {
        if (ticket !== generation || id !== context.sessionID) return [];
        var rows = value && (Array.isArray(value.items) ? value.items : Array.isArray(value.value) ? value.value : []);
        commandRows = rows.filter(function (row) {
          return row && typeof row.name === "string" && /^[a-z][a-z0-9_-]*$/.test(row.name);
        });
        return commandRows;
      }).catch(function (error) {
        if (ticket === generation && id === context.sessionID) commandScope = "";
        if (options.onError) options.onError(error);
        return [];
      }).finally(function () {
        if (ticket === generation && id === context.sessionID) commandLoading = false;
      });
    }
    function isCommand(text) {
      var match = /^\/([a-z][a-z0-9_-]*)(?:\s+([\s\S]*))?$/.exec((text || "").trim());
      if (!match) return false;
      return !commandRows.length || commandRows.some(function (row) { return row.name === match[1]; });
    }
    function executeCommand(rawLine) {
      var line = (rawLine || "").trim();
      if (!line || busy || !context.connected || context.pending || context.running) return Promise.resolve(false);
      if (!context.sessionID) return executeNewSessionCommand(line);
      var id = context.sessionID, ticket = generation;
      busy = true; syncControls();
      if (options.onCommandStatus) options.onCommandStatus(id, "正在执行命令…");
      return rpc("commands/execute", { agentId: id, line: line, submittedAttachments: [] }).then(function (execution) {
        if (!execution || !execution.result) throw new Error("命令未被识别，请刷新命令列表。");
        var result = execution.result;
        if (ticket === generation && id === context.sessionID && options.onCommandStatus) {
          options.onCommandStatus(id, result.text || (result.kind === "error" ? "命令执行失败。" : "命令已完成。"));
        }
        notify(options.onSessionsChanged);
        return true;
      }).catch(function (error) {
        if (ticket === generation && id === context.sessionID && options.onCommandStatus) {
          options.onCommandStatus(id, error && error.message || "命令执行失败。");
        }
        if (options.onError) options.onError(error);
        return false;
      }).finally(function () { busy = false; syncControls(); });
    }
    function executeNewSessionCommand(line) {
      if (busy || !options.ensureCommandSession || !context.connected || context.pending) return Promise.resolve(false);
      busy = true; syncControls();
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
        return true;
      }).catch(function (error) {
        if (ticket === generation && id && options.onCommandStatus) {
          options.onCommandStatus(id, error && error.message || "命令执行失败。");
        }
        if (options.onError) options.onError(error);
        return false;
      }).finally(function () { busy = false; syncControls(); });
    }
    function bindComposer(input, parent, onChange) {
      var list = S.node("div", "dsh-file-mentions dsh-slash-commands"), filtered = [], selected = 0, current = null;
      list.hidden = true; list.setAttribute("role", "listbox"); list.setAttribute("aria-label", "命令");
      parent.appendChild(list);
      function hide() { current = null; filtered = []; selected = 0; list.hidden = true; S.clear(list); }
      function match() {
        var pos = typeof input.selectionStart === "number" ? input.selectionStart : input.value.length;
        var before = input.value.slice(0, pos), after = input.value.slice(pos);
        var found = /^\/([a-z0-9_-]*)$/i.exec(before);
        if (!found || /^\S/.test(after)) return null;
        return { query: found[1].toLowerCase(), start: 0, end: before.length };
      }
      function choose(row) {
        if (!current || !row) return;
        input.setRangeText("/" + row.name + " ", current.start, current.end, "end");
        hide();
        if (onChange) onChange(row);
        input.focus();
      }
      function renderList() {
        S.clear(list);
        if (!current) { list.hidden = true; return; }
        var q = current.query;
        filtered = commandRows.filter(function (row) { return !q || row.name.indexOf(q) === 0 || row.name.indexOf(q) >= 0; });
        if (selected >= filtered.length) selected = 0;
        filtered.forEach(function (row, index) {
          var button = S.button("", null, {}, null, "small dsh-file-mention dsh-slash-command");
          button.setAttribute("role", "option"); button.setAttribute("aria-selected", String(index === selected));
          button.title = "/" + row.name + (row.description ? " · " + row.description : "");
          button.appendChild(S.node("span", "dsh-slash-command-name", "/" + row.name));
          if (row.description) button.appendChild(S.node("span", "dsh-slash-command-desc hint", row.description));
          button.addEventListener("mousedown", function (event) { event.preventDefault(); });
          button.addEventListener("click", function () { choose(row); });
          list.appendChild(button);
        });
        if (!filtered.length && commandLoading) {
          var status = S.node("div", "dsh-file-mention-status", "正在读取命令…");
          status.setAttribute("role", "status"); list.appendChild(status);
        }
        list.hidden = !filtered.length && !commandLoading;
      }
      function updateList() {
        var next = match();
        if (!next || !context.connected || context.running || context.pending) { hide(); return; }
        current = next; renderList();
        loadCommands().then(function () { if (current) renderList(); });
      }
      function keydown(event) {
        if (list.hidden || global.CodexBridgeDesktopPageSupport.isIMEKeyEvent(event)) return false;
        if (event.key === "Escape") { event.preventDefault(); hide(); return true; }
        if (!filtered.length) return false;
        if (event.key === "ArrowDown" || event.key === "ArrowUp") {
          event.preventDefault();
          selected = (selected + (event.key === "ArrowDown" ? 1 : filtered.length - 1)) % filtered.length;
          renderList(); return true;
        }
        if (event.key === "Tab") {
          event.preventDefault(); choose(filtered[selected]); return true;
        }
        if (event.key === "Enter" && !event.shiftKey) {
          var row = filtered[selected];
          if (row && input.value.trim() === "/" + row.name) { hide(); return false; }
          event.preventDefault(); choose(row); return true;
        }
        return false;
      }
      commandPicker = { root: list, update: updateList, hide: hide, keydown: keydown };
      return commandPicker;
    }
    function dispose() {
      if (commandPicker) commandPicker.hide();
    }
    return { menu: menu, root: root, update: update, dispose: dispose,
      bindComposer: bindComposer, isCommand: isCommand, executeCommand: executeCommand };
  }
  global.CodexBridgeDesktopEmbeddedDSHActions = { create: create };
}(window));
