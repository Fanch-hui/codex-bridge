(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  function create() {
    var root = S.node("section", "page-card settings-card direct-settings-card");
    root.appendChild(S.node("h3", null, "Direct 工作区"));
    root.appendChild(S.node("p", "hint", "规则适用于所有项目。优先级：黑名单 → 白名单 → 安全模式内置规则。命令按参数前缀匹配；项目访问权限和操作审批仍生效。"));
    var context = { value: null, emit: null };
    var pending = Object.create(null);
    var mode = S.selectField("命令模式", "safe", [
      { id: "denied", title: "关闭命令执行" }, { id: "safe", title: "安全模式" }, { id: "full", title: "完整模式" }
    ], function (value) { save({ commandMode: value }); }, "");
    root.appendChild(mode.wrapper);
    var allowed = list("白名单", "allowedCommands", "例如：git status"), denied = list("黑名单", "deniedCommands", "例如：git push");
    root.appendChild(allowed.root); root.appendChild(denied.root);
    root.appendChild(S.node("p", "hint", "输入一条命令后点击添加，例如 git status 或 npm test。带空格的参数使用引号，不支持管道和重定向。"));
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
    return { root: root, update: function (value, emit) {
      if (context.value) acknowledge(value);
      context = { value: value, emit: emit };
      root.hidden = !value;
      if (!value) return;
      var effective = effectiveValue(value);
      mode.control.value = effective.commandMode; mode.control.disabled = !effective.canSave;
      allowed.update(value); denied.update(value);
    }};
  }
  global.CodexBridgeDesktopDirect = { create: create };
}(window));
