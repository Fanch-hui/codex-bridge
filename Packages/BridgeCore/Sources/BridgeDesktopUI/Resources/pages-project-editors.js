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

  global.CodexBridgeDesktopProjectEditors = { policy: policy };
}(window));
