(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;

  function create(view, bar, panels, onChange) {
    var controls = S.node("div", "dsh-pane-controls");
    controls.setAttribute("role", "group"); controls.setAttribute("aria-label", "DSH 面板");
    bar.insertBefore(controls, view.collaboration.parentNode);
    var settingsOpen = false;

    function toggle(key, symbol, target) {
      var button = S.button("", null, {}, null, "dsh-pane-toggle");
      button.appendChild(S.icon(symbol)); button.setAttribute("aria-controls", target);
      button.addEventListener("click", function () {
        if (key === "workspaceCollapsed" && settingsOpen) return;
        panels[key] = panels[key] !== true; onChange();
      });
      controls.appendChild(button); return button;
    }
    var sessions = toggle("sessionsCollapsed", "sidebar.left", view.sidebar.id);
    var workspace = toggle("workspaceCollapsed", "sidebar.right", "dsh-workspace-pane");

    function updateButton(button, expanded, label) {
      button.setAttribute("aria-expanded", String(expanded));
      button.title = (expanded ? "收起" : "展开") + label;
      button.setAttribute("aria-label", button.title);
    }
    function update(development, showingSettings) {
      settingsOpen = showingSettings;
      var sessionsOpen = panels.sessionsCollapsed !== true;
      var workspaceOpen = !!view.workspace && panels.workspaceCollapsed !== true && !settingsOpen;
      controls.hidden = !development;
      view.root.dataset.sessionsCollapsed = String(!sessionsOpen);
      view.root.dataset.workspaceCollapsed = String(!workspaceOpen);
      view.root.dataset.settingsOpen = String(settingsOpen);
      view.sidebar.hidden = !sessionsOpen;
      view.center.hidden = settingsOpen; view.settings.hidden = !settingsOpen;
      workspace.disabled = settingsOpen || !view.workspace;
      updateButton(sessions, sessionsOpen, "项目与会话");
      updateButton(workspace, workspaceOpen, "文件与变更");
      return development && workspaceOpen;
    }
    return { update: update };
  }
  global.CodexBridgeDesktopDSHWorkbenchLayout = { create: create };
})(window);
