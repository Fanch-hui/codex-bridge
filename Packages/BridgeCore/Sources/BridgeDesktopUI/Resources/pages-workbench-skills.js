(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;

  function create(detail, draft) {
    if (!["pi", "qoder"].includes(detail.providerID)) return null;
    var field = S.textField("Skills", draft.skillNamesText || "", "输入 Skill 名称，多个名称用逗号分隔", "full");
    field.control.id = "workbench-skills";
    field.wrapper.querySelector("label").htmlFor = field.control.id;
    field.control.addEventListener("input", function () {
      draft.skillNamesText = field.control.value;
    });
    var hint = S.node("p", "muted", "名称可在项目的 Skills 列表中查看；留空沿用会话选择。");
    hint.id = "workbench-skills-hint";
    field.control.setAttribute("aria-describedby", hint.id);
    field.wrapper.appendChild(hint);
    return {
      wrapper: field.wrapper,
      payload: function () {
        var names = Array.from(new Set(field.control.value.split(/[,，\n]/)
          .map(function (name) { return name.trim(); }).filter(Boolean)));
        return names.length ? { skillNames: names } : {};
      }
    };
  }

  global.CodexBridgeDesktopWorkbenchSkills = { create: create };
})(window);
