(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport, D = global.CodexBridgeDesktopFormDraft;
  var fieldSequence = 0;

  function field(name, label, kind, placeholder) {
    var wrapper = S.node("div", "field" + (kind === "textarea" ? " full" : ""));
    var caption = S.node("label", null, label), control = S.node(kind === "select" || kind === "textarea" ? kind : "input");
    control.id = "project-field-" + (++fieldSequence); caption.htmlFor = control.id;
    control.dataset.field = name;
    if (kind === "checkbox") control.type = "checkbox";
    else if (kind !== "select" && kind !== "textarea") control.type = "text";
    control.placeholder = placeholder || "";
    wrapper.appendChild(caption); wrapper.appendChild(control);
    return { wrapper: wrapper, control: control };
  }

  function form(title, specs) {
    var root = S.node("div", "page-card"), grid = S.node("div", "form-grid");
    if (title) root.appendChild(S.node("h3", null, title));
    var fields = {};
    specs.forEach(function (spec) {
      var item = field(spec[0], spec[1], spec[2], spec[3]);
      grid.appendChild(item.wrapper); fields[spec[0]] = item.control;
    });
    root.appendChild(grid);
    var actions = S.node("div", "form-actions"); root.appendChild(actions);
    return { root: root, fields: fields, draft: D.bind(fields), actions: actions };
  }

  function policy(projectID) {
    var editor = form("访问与执行权限", [
      ["readPermission", "读取", "select"], ["writePermission", "写入", "select"], ["networkPermission", "网络", "select"]
    ]);
    var emit = null, save = S.button("保存权限", null, {}, null, "small primary", true);
    save.addEventListener("click", function () {
      if (!save.disabled) emit("saveProjectPolicy", Object.assign({ projectID: projectID }, editor.draft.values()));
    });
    editor.actions.appendChild(save);
    return {
      root: editor.root,
      setAvailable: function (available) { save.disabled = !available; },
      update: function (page, project, commandEmitter) {
        emit = commandEmitter;
        ["read", "write", "network"].forEach(function (name) {
          var options = S.safeArray(page[name + "Options"]);
          D.selectOptions(editor.fields[name + "Permission"], options.length ? options : page.policyOptions);
        });
        editor.draft.update({ readPermission: project.readPermission, writePermission: project.writePermission, networkPermission: project.networkPermission });
        save.disabled = !page.canSavePolicy;
      }
    };
  }

  function mode(projectID) {
    var editor = form(null, [["mode", "命令模式", "select"]]);
    editor.root.className = "workspace-mode-editor";
    var emit = null, save = S.button("保存命令模式", null, {}, null, "small", true);
    save.addEventListener("click", function () {
      if (!save.disabled) emit("setProjectCommandMode", { projectID: projectID, mode: editor.draft.values().mode });
    });
    editor.actions.appendChild(save);
    return {
      root: editor.root,
      setAvailable: function (available) { save.disabled = !available; },
      update: function (workspace, commandEmitter) {
        emit = commandEmitter;
        D.selectOptions(editor.fields.mode, workspace.commandModeOptions);
        editor.draft.update({ mode: workspace.commandMode }); save.disabled = !workspace.canSaveMode;
      }
    };
  }

  function commandValues(record) {
    return { name: record ? record.name : "", executable: record ? record.executable : "",
      arguments: record ? S.safeArray(record.arguments).join("\n") : "", workingDirectory: record && record.workingDirectory || "",
      requiresNetwork: !!(record && record.requiresNetwork), risk: record && record.risk || "normal" };
  }

  function blacklistValues(record) {
    return { executable: record && record.executable || "", pattern: record && record.pattern || "" };
  }

  function commandPayload(values) {
    return { name: values.name, executable: values.executable,
      arguments: values.arguments.split(/\r?\n/).map(function (line) { return line.trim(); }).filter(Boolean),
      workingDirectory: values.workingDirectory || null, requiresNetwork: values.requiresNetwork, risk: values.risk || "normal" };
  }

  function command(projectID) {
    var editor = form(null, [
      ["name", "名称", "text", "例如：测试"], ["executable", "可执行文件", "text", "例如：swift"],
      ["arguments", "参数（每行一个参数）", "textarea", "例如：--configuration\npath with spaces"],
      ["workingDirectory", "工作目录", "text", "可选"], ["risk", "风险等级", "select"], ["requiresNetwork", "需要网络", "checkbox"]
    ]);
    editor.root.className = "command-editor page-message";
    D.selectOptions(editor.fields.risk, [{ id: "normal", title: "普通" }, { id: "elevated", title: "高风险" }]);
    return recordEditor(editor, projectID, {
      id: "commandID", save: "saveProjectCommand", remove: "removeProjectCommand", saveTitle: "保存命令", removeTitle: "删除命令",
      normalize: commandValues, payload: commandPayload, saveCapability: "canSaveCommand", removeCapability: "canRemoveCommand",
      confirmation: function (record) { return "删除 Direct 命令“" + record.name + "”？"; }
    });
  }

  function blacklist(projectID) {
    var editor = form(null, [["executable", "可执行文件", "text", "可选"], ["pattern", "匹配模式", "text", "可选"]]);
    editor.root.className = "blacklist-editor page-message";
    return recordEditor(editor, projectID, {
      id: "ruleID", save: "saveProjectBlacklist", remove: "removeProjectBlacklist", saveTitle: "保存规则", removeTitle: "删除规则",
      normalize: blacklistValues,
      payload: function (value) { return { executable: value.executable || null, pattern: value.pattern || null }; },
      saveCapability: "canSaveBlacklist", removeCapability: "canRemoveBlacklist",
      confirmation: function () { return "删除这条 Direct 命令黑名单规则？"; }
    });
  }

  function recordEditor(editor, projectID, config) {
    var record = null, emit = null, submitted = null;
    var save = S.button(config.saveTitle, null, {}, null, "small primary", true);
    var remove = S.button(config.removeTitle, null, {}, null, "small danger", true);
    save.addEventListener("click", function () {
      if (save.disabled) return;
      var payload = config.payload(editor.draft.values());
      submitted = payload;
      var identity = { projectID: projectID }; identity[config.id] = record ? record[config.id] : null;
      emit(config.save, Object.assign(identity, payload));
    });
    remove.addEventListener("click", function () {
      if (remove.disabled || !record || !global.confirm(config.confirmation(record))) return;
      var payload = { projectID: projectID }; payload[config.id] = record[config.id]; emit(config.remove, payload);
    });
    editor.actions.appendChild(save); editor.actions.appendChild(remove);
    return {
      root: editor.root,
      setAvailable: function (available) { save.disabled = !available; remove.disabled = !available; },
      matchesSubmission: function (candidate) {
        return submitted && JSON.stringify(config.payload(config.normalize(candidate))) === JSON.stringify(submitted);
      },
      update: function (workspace, incoming, commandEmitter) {
        record = incoming || null; emit = commandEmitter;
        editor.draft.update(config.normalize(record));
        save.disabled = !workspace[config.saveCapability];
        remove.hidden = !record; remove.disabled = !record || !workspace[config.removeCapability];
      }
    };
  }

  global.CodexBridgeDesktopProjectEditors = { policy: policy, mode: mode, command: command, blacklist: blacklist };
}(window));
