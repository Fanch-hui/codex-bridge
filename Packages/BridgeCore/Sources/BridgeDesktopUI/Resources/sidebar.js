(function () {
  "use strict";

  var shell = document.getElementById("app-shell");
  var button = document.querySelector(".sidebar-toggle");
  var compactWindow = window.matchMedia("(max-width: 1100px)");
  var preferenceKey = "codex-bridge.sidebar-collapsed";
  var selectedCollapsed = readPreference();

  function readPreference() {
    try {
      var value = window.localStorage.getItem(preferenceKey);
      if (value === "true") return true;
      if (value === "false") return false;
      return null;
    } catch (_) { return null; }
  }

  function isCollapsed() {
    return selectedCollapsed === null ? compactWindow.matches : selectedCollapsed;
  }

  function apply() {
    var collapsed = isCollapsed();
    shell.classList.toggle("sidebar-collapsed", collapsed);
    button.setAttribute("aria-expanded", String(!collapsed));
    button.setAttribute("aria-label", collapsed ? "展开侧边栏" : "收起侧边栏");
    button.title = collapsed ? "展开侧边栏" : "收起侧边栏";
    window.requestAnimationFrame(function () {
      if (window.CodexBridgeDesktopPages && window.CodexBridgeDesktopUI) {
        window.CodexBridgeDesktopPages.measureBrowserViewport(window.CodexBridgeDesktopUI.sendCommand);
      }
    });
  }

  button.addEventListener("click", function () {
    selectedCollapsed = !isCollapsed();
    try { window.localStorage.setItem(preferenceKey, String(selectedCollapsed)); } catch (_) {}
    apply();
  });
  compactWindow.addEventListener("change", apply);
  apply();
}());
