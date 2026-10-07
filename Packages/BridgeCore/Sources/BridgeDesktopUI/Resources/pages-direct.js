(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  function create() {
    var root = S.node("section", "page-card settings-card direct-settings-card");
    root.appendChild(S.node("h3", null, "Direct 工作区"));
    root.appendChild(S.node("p", "hint", "所有项目共用。黑名单优先于白名单，再检查安全模式规则；命令按参数前缀匹配。项目目录边界和本机审批仍生效。"));
    var context = { value: null, emit: null };
    var pending = Object.create(null);
    var mode = S.selectField("命令模式", "safe", [
      { id: "denied", title: "关闭命令执行" }, { id: "safe", title: "安全模式" }, { id: "full", title: "完整模式" }
    ], function (value) { save({ commandMode: value }); }, "");
    root.appendChild(mode.wrapper);
    var allowed = list("白名单", "allowedCommands", "例如：git status"), denied = list("黑名单", "deniedCommands", "例如：git push");
    root.appendChild(allowed.root); root.appendChild(denied.root);
    root.appendChild(S.node("p", "hint", "带空格的参数使用引号，不支持管道和重定向。"));
    var checker = commandChecker();
    root.appendChild(checker.root);
    function save(change) {
      if (!context.value || !context.value.canSave) return;
      Object.keys(change).forEach(function (key) { pending[key] = change[key]; });
      var value = effectiveValue(context.value);
      context.emit("saveDirectConfiguration", { value: JSON.stringify(Object.assign({
        commandMode: value.commandMode, allowedCommands: value.allowedCommands, deniedCommands: value.deniedCommands
      }, change)) });
    }

    function equalValue(left, right) {
      return JSON.stringify(left == null ? null : left) === JSON.stringify(right == null ? null : right);
    }

    function effectiveValue(value) {
      var result = Object.assign({}, value);
      Object.keys(pending).forEach(function (key) {
        result[key] = Array.isArray(pending[key]) ? pending[key].slice() : pending[key];
      });
      result.allowedCommands = S.safeArray(result.allowedCommands).slice();
      result.deniedCommands = S.safeArray(result.deniedCommands).slice();
      return result;
    }

    function acknowledge(value) {
      Object.keys(pending).forEach(function (key) {
        if (equalValue(value[key], pending[key])) delete pending[key];
      });
    }
    function list(title, key, placeholder) {
      var section = S.node("section"), rows = S.node("div", "list-body");
      section.appendChild(S.node("h4", null, title)); section.appendChild(rows);
      var field = S.textField("命令行", "", placeholder);
      var add = S.button("添加", null, {}, null, "small primary", true);
      var inputRow = S.node("div", "direct-command-input");
      inputRow.appendChild(field.wrapper); inputRow.appendChild(add); section.appendChild(inputRow);
      var submitted = new Set(), previous = null;
      add.addEventListener("click", function () {
        var line = field.control.value.trim();
        if (!line || add.disabled) return;
        var values = effectiveValue(context.value)[key].slice();
        if (!values.includes(line)) values.push(line);
        submitted.add(line);
        var change = {}; change[key] = values; save(change);
      });
      field.control.addEventListener("input", function () {
        add.disabled = !context.value || !context.value.canSave || !field.control.value.trim();
      });
      return { root: section, update: function (value) {
        acknowledge(value);
        var effective = effectiveValue(value);
        var commands = S.safeArray(effective[key]);
        submitted.forEach(function (line) {
          if (S.safeArray(value[key]).includes(line)) {
            submitted.delete(line);
            if (!field.control.value.trim() || field.control.value.trim() === line) field.control.value = "";
          }
        });
        add.disabled = !effective.canSave || !field.control.value.trim();
        var signature = JSON.stringify([commands, value.canSave]);
        if (signature === previous) return;
        previous = signature; S.clear(rows);
        commands.forEach(function (line) {
          var row = S.node("div", "list-row"), text = S.node("div", "row-main mono", line);
          text.style.overflowWrap = "anywhere"; text.style.minWidth = "0"; row.appendChild(text);
          var remove = S.button("移除", null, {}, null, "small", !value.canSave);
          remove.addEventListener("click", function () {
            var change = {}; change[key] = effectiveValue(context.value)[key].filter(function (item) { return item !== line; }); save(change);
          });
          row.appendChild(remove); rows.appendChild(row);
        });
        rows.hidden = commands.length === 0;
      }};
    }
    function commandChecker() {
      var section = S.node("section"), previousProjects = null;
      section.appendChild(S.node("h4", null, "命令校验"));
      var help = S.node("p", "hint", "选择项目并输入命令，查看当前规则是否允许。校验不会执行命令；实际运行仍检查审批、目录和程序状态。");
      help.id = "direct-command-check-help";
      section.appendChild(help);
      var project = S.selectField("项目", "", [], renderResult, "");
      var command = S.textField("待校验命令", "", "例如：git status --short");
      var directory = S.textField("工作目录", "", "项目内相对路径，留空使用项目根目录");
      [project.control, command.control, directory.control].forEach(function (control, index) {
        control.setAttribute("aria-label", ["命令校验项目", "待校验命令", "命令校验工作目录"][index]);
        control.setAttribute("aria-describedby", help.id);
      });
      command.control.required = true;
      command.control.maxLength = 4096;
      directory.control.maxLength = 1024;
      section.appendChild(project.wrapper);
      section.appendChild(command.wrapper);
      section.appendChild(directory.wrapper);
      var checkButton = S.button("校验命令", null, {}, null, "small primary", true);
      var result = S.node("div", "page-message");
      result.setAttribute("role", "status");
      result.setAttribute("aria-live", "polite");
      result.style.whiteSpace = "pre-wrap";
      result.hidden = true;
      checkButton.addEventListener("click", function () {
        if (checkButton.disabled || !context.emit) return;
        result.hidden = false;
        result.textContent = "正在校验命令…";
        checkButton.disabled = true;
        context.emit("checkDirectCommand", {
          projectID: project.control.value,
          input: command.control.value.trim(),
          workingDirectory: directory.control.value.trim()
        });
      });
      command.control.addEventListener("input", renderResult);
      directory.control.addEventListener("input", renderResult);
      section.appendChild(checkButton);
      section.appendChild(result);
      function renderResult() {
        var state = context.value && context.value.check;
        var available = state && state.canCheck && S.safeArray(state.projects).length > 0;
        project.control.disabled = !available;
        checkButton.disabled = !available || state.isChecking || !command.control.value.trim();
        section.setAttribute("aria-busy", state && state.isChecking ? "true" : "false");
        result.hidden = false;
        result.className = "page-message";
        if (!available) {
          result.textContent = S.safeArray(state && state.projects).length === 0
            ? "登记项目并连接后台服务后即可校验命令。" : "等待后台服务连接或当前设置保存完成后再校验。";
          return;
        }
        var matches = state.projectID === project.control.value
          && state.commandLine === command.control.value.trim()
          && state.workingDirectory === directory.control.value.trim();
        if (!matches) { result.hidden = true; return; }
        if (state.isChecking) { result.textContent = "正在校验命令…"; return; }
        if (state.errorMessage) {
          result.className = "page-message warning";
          result.textContent = state.errorMessage;
          return;
        }
        var outcome = state.result;
        if (!outcome) { result.hidden = true; return; }
        var lines = [outcome.message];
        if (outcome.matchedRule) lines.push("命中规则：" + outcome.matchedRule);
        if (outcome.executable) lines.push("执行文件：" + outcome.executable);
        if (outcome.workingDirectory) lines.push("工作目录：" + outcome.workingDirectory);
        if (outcome.allowed) lines.push(outcome.requiresApproval ? "实际执行需要本机批准。" : "当前 Direct 审批设置为自动批准。");
        if (outcome.nextAction) lines.push(outcome.nextAction);
        result.className = "page-message " + (outcome.allowed ? "success" : "warning");
        result.textContent = lines.join("\n");
      }
      return { root: section, update: function (state) {
        section.hidden = !state;
        if (!state) return;
        var choices = S.safeArray(state.projects), signature = JSON.stringify(choices);
        if (signature !== previousProjects) {
          previousProjects = signature;
          var selected = project.control.value;
          S.clear(project.control);
          choices.forEach(function (choice) {
            var option = S.node("option", null, choice.title);
            option.value = choice.id;
            project.control.appendChild(option);
          });
          project.control.value = choices.some(function (choice) { return choice.id === selected; })
            ? selected : (choices[0] ? choices[0].id : "");
        }
        renderResult();
      }};
    }
    return { root: root, update: function (value, emit) {
      if (context.value && value) acknowledge(value);
      context = { value: value, emit: emit };
      root.hidden = !value;
      if (!value) return;
      var effective = effectiveValue(value);
      mode.control.value = effective.commandMode; mode.control.disabled = !effective.canSave;
      allowed.update(value); denied.update(value);
      checker.update(value.check);
    }};
  }
  global.CodexBridgeDesktopDirect = { create: create };
}(window));
