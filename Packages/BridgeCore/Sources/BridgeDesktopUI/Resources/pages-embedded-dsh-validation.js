(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport, T = global.CodexBridgeDesktopEmbeddedDSHTransport;

  function create(container, onSaved) {
    var root = S.node("section", "dsh-embedded-request dsh-recovery-validation");
    var drafts = new Map(), current = null, revision = 0, loading = false, saving = false, message = "";
    root.setAttribute("aria-label", "合并前验证");
    function button(title, handler, disabled, key) {
      var control = S.button(title, null, {}, null, "small");
      if (key) control.dataset.validationFocus = key;
      control.disabled = !!disabled; control.addEventListener("click", handler); return control;
    }
    function close() { revision++; current = null; loading = false; saving = false; message = ""; root.remove(); }
    function setContext(projectID, active) {
      if (current && (!active || current.projectID !== projectID)) close();
    }
    function open(projectID, item) {
      if (!projectID || !item || !item.recoveryID) return;
      current = { projectID: projectID, recoveryID: item.recoveryID, sessionId: item.sessionId };
      var token = ++revision; message = "";
      if (drafts.has(projectID)) { loading = false; render(); return; }
      loading = true; render();
      T.call("workspace.validation.get", { projectID: projectID }).then(function (result) {
        if (!current || token !== revision) return;
        var commands = S.safeArray(result && result.commands).slice(0, 3).map(function (command) {
          return { executable: command.executable || "", arguments: S.safeArray(command.arguments).join("\n") };
        });
        drafts.set(projectID, { commands: commands.length ? commands : [{ executable: "", arguments: "" }],
          timeoutSeconds: result && result.timeoutSeconds || 120 });
        loading = false; render();
      }).catch(function (error) {
        if (!current || token !== revision) return;
        loading = false; message = error && error.message || "无法读取验证命令。"; render();
      });
    }
    function save() {
      if (!current || loading || saving) return;
      var draft = drafts.get(current.projectID);
      if (!draft) return;
      var commands = draft.commands.map(function (command) {
        return { executable: command.executable.trim(), arguments: command.arguments.split("\n").map(function (value) {
          return value.endsWith("\r") ? value.slice(0, -1) : value;
        }).filter(function (value) { return value.length > 0; }) };
      });
      var seconds = Number(draft.timeoutSeconds);
      if (commands.some(function (command) { return !command.executable; })) {
        message = "请填写每条命令的可执行文件，或删除空命令。"; render(); return;
      }
      if (!Number.isInteger(seconds) || seconds < 5 || seconds > 120) {
        message = "超时时间须为 5 至 120 秒。"; render(); return;
      }
      var operation = current, token = revision;
      saving = true; message = "正在保存验证命令…"; render();
      T.call("workspace.validation.set", { projectID: operation.projectID, commands: commands, timeoutSeconds: seconds })
        .then(function () {
          if (!current || token !== revision) return;
          message = "已保存，正在重试合并…"; render();
          var payload = { projectID: operation.projectID, recoveryID: operation.recoveryID };
          if (operation.sessionId) payload.sessionId = operation.sessionId;
          return T.call("workspace.recovery.resume", payload);
        }).then(function () {
          if (!current || token !== revision) return;
          drafts.delete(operation.projectID); close(); onSaved();
        }).catch(function (error) {
          if (!current || token !== revision) return;
          saving = false;
          message = error && error.code === "embedded_dsh_transport_timeout"
            ? "请求未确认，请检查恢复状态后重试。" : error && error.message || "保存失败，请重试。";
          render();
        });
    }
    function render() {
      var focused = root.contains(document.activeElement) && document.activeElement;
      var focusKey = focused && focused.dataset.validationFocus;
      var start = focused && focused.selectionStart, end = focused && focused.selectionEnd;
      root.replaceChildren();
      root.appendChild(S.node("strong", null, "合并前验证"));
      if (loading) root.appendChild(S.node("p", "hint", "正在读取验证命令…"));
      var draft = current && drafts.get(current.projectID);
      if (draft) {
        root.appendChild(S.node("p", "hint", "命令在候选副本中执行，须符合直接命令规则。每行填写一个独立参数。"));
        draft.commands.forEach(function (command, index) {
          var fields = S.node("div", "dsh-recovery-validation-command");
          var executable = S.textField("可执行文件", command.executable, "例如 swift");
          var args = S.textAreaField("参数，每行一项", command.arguments, "例如 build");
          executable.control.dataset.validationFocus = "executable:" + index;
          args.control.dataset.validationFocus = "arguments:" + index;
          executable.control.disabled = args.control.disabled = saving;
          executable.control.addEventListener("input", function () { command.executable = executable.control.value; });
          args.control.addEventListener("input", function () { command.arguments = args.control.value; });
          fields.appendChild(executable.wrapper); fields.appendChild(args.wrapper);
          if (draft.commands.length > 1) fields.appendChild(button("删除命令", function () {
            draft.commands.splice(index, 1); render();
          }, saving, "remove:" + index));
          root.appendChild(fields);
        });
        var timeout = S.textField("每条命令超时（秒）", String(draft.timeoutSeconds), "5–120");
        timeout.control.dataset.validationFocus = "timeout";
        timeout.control.type = "number"; timeout.control.min = "5"; timeout.control.max = "120"; timeout.control.disabled = saving;
        timeout.control.addEventListener("input", function () { draft.timeoutSeconds = timeout.control.value; });
        root.appendChild(timeout.wrapper);
        var actions = S.node("div", "form-actions");
        actions.appendChild(button("添加命令", function () { draft.commands.push({ executable: "", arguments: "" }); render(); }, saving || draft.commands.length >= 3, "add"));
        actions.appendChild(button(saving ? "处理中…" : "保存并重试合并", save, saving, "save"));
        actions.appendChild(button("取消", close, saving, "cancel")); root.appendChild(actions);
      } else if (!loading) {
        root.appendChild(button("重新读取", function () { open(current.projectID, current); }));
        root.appendChild(button("关闭", close));
      }
      if (message) { var status = S.node("p", "hint", message); status.setAttribute("role", "status"); root.appendChild(status); }
      if (!root.parentNode) container.appendChild(root);
      if (focusKey) {
        var replacement = Array.from(root.querySelectorAll("input, textarea, button")).find(function (item) {
          return item.dataset.validationFocus === focusKey && !item.disabled;
        });
        if (replacement) {
          replacement.focus();
          if (typeof start === "number" && typeof end === "number" && replacement.setSelectionRange) {
            replacement.setSelectionRange(start, end);
          }
        }
      }
    }
    return { open: open, setContext: setContext };
  }
  global.CodexBridgeDesktopEmbeddedDSHValidation = { create: create };
}(window));
