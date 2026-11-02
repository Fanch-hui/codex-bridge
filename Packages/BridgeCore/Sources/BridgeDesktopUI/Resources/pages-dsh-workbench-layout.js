(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;

  function create(view, toolbar, panels, onChange) {
    var button = S.button("", null, {}, null, "dsh-pane-toggle");
    button.appendChild(S.icon("sidebar.right"));
    button.setAttribute("aria-controls", "dsh-workspace-pane");
    button.addEventListener("click", function () {
      panels.workspaceCollapsed = panels.workspaceCollapsed !== true; onChange();
    });
    toolbar.appendChild(button);
    function update(development) {
      var expanded = development && !!view.workspace && panels.workspaceCollapsed !== true;
      view.root.dataset.workspaceCollapsed = String(!expanded);
      button.hidden = !development;
      button.disabled = !view.workspace;
      button.setAttribute("aria-expanded", String(expanded));
      button.title = (expanded ? "收起" : "展开") + "文件与变更";
      button.setAttribute("aria-label", button.title);
      return expanded;
    }
    return { update: update };
  }
  global.CodexBridgeDesktopDSHWorkbenchLayout = { create: create };
})(window);
