(function (global) {
  "use strict";

  var pages = {
    workbench: global.CodexBridgeDesktopWorkbenchPage,
    projects: global.CodexBridgeDesktopProjectsPage,
    logs: global.CodexBridgeDesktopLogsPage,
    connections: global.CodexBridgeDesktopConnectionsPage,
    settings: global.CodexBridgeDesktopSettingsPage
  };
  var lastViewport = "";

  function render(state, emit) {
    var names = ["overview", "workbench", "projects", "logs", "connections", "settings"];
    names.forEach(function (name) {
      var section = document.getElementById(name + "-page");
      if (section) section.hidden = !state || state.selectedNavigation !== name;
    });
    if (!state || state.selectedNavigation === "overview") {
      lastViewport = "";
      return;
    }
    if (state.selectedNavigation !== "workbench") lastViewport = "";
    var page = pages[state.selectedNavigation];
    if (page) page.render(state[state.selectedNavigation], emit);
    if (state.selectedNavigation === "workbench") {
      global.requestAnimationFrame(function () { measureBrowserViewport(emit); });
    }
  }

  function measureBrowserViewport(emit) {
    var slot = document.getElementById("chat-browser-slot");
    if (!slot) return;
    var rect = slot.getBoundingClientRect();
    var visible = rect.width > 0 && rect.height > 0 && !slot.classList.contains("browser-hidden");
    var viewport = {
      x: rect.left,
      y: rect.top,
      width: rect.width,
      height: rect.height,
      visible: visible
    };
    var signature = [viewport.x, viewport.y, viewport.width, viewport.height, viewport.visible].join(":");
    if (signature === lastViewport) return;
    lastViewport = signature;
    emit("updateBrowserViewport", { viewport: viewport });
  }

  global.CodexBridgeDesktopPages = {
    render: render,
    measureBrowserViewport: measureBrowserViewport
  };
}(window));
