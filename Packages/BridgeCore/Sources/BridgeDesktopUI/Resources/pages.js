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
  var currentNavigation;
  var viewportEmitter;
  var viewportFrame = 0;
  var slot = document.getElementById("chat-browser-slot");
  if (global.ResizeObserver && slot) {
    new ResizeObserver(function () {
      if (!viewportEmitter || viewportFrame) return;
      viewportFrame = global.requestAnimationFrame(function () {
        viewportFrame = 0;
        measureBrowserViewport(viewportEmitter);
      });
    }).observe(slot);
  }

  function render(state, emit) {
    viewportEmitter = emit;
    currentNavigation = state && state.selectedNavigation;
    if (global.CodexBridgeDesktopDSHWorkbench) {
      global.CodexBridgeDesktopDSHWorkbench.configure(state, emit);
      global.CodexBridgeDesktopDSHWorkbench.setActive(currentNavigation === "workbench", emit);
    }
    pages.connections.setActive(!!state && state.selectedNavigation === "connections", emit);
    var names = ["overview", "workbench", "projects", "logs", "connections", "settings"];
    names.forEach(function (name) {
      var section = document.getElementById(name + "-page");
      if (section) section.hidden = !state || state.selectedNavigation !== name;
    });
    if (!state || state.selectedNavigation !== "workbench") {
      emitBrowserViewport(emit, { x: 0, y: 0, width: 0, height: 0, visible: false });
    }
    if (!state || state.selectedNavigation === "overview") return;
    var page = pages[state.selectedNavigation];
    if (page) page.render(state[state.selectedNavigation], emit, state.appUpdate, state);
    if (state.selectedNavigation === "workbench") {
      var development = global.CodexBridgeDesktopDSHWorkbench
        && global.CodexBridgeDesktopDSHWorkbench.mode() === "dsh";
      if (!development && global.CodexBridgeDesktopNativeSessionDirectory) {
        global.CodexBridgeDesktopNativeSessionDirectory.render(state.workbench, emit);
      }
      if (!development && global.CodexBridgeDesktopWorkbenchSplit) global.CodexBridgeDesktopWorkbenchSplit.sync();
      global.requestAnimationFrame(function () { measureBrowserViewport(emit); });
    }
  }

  function measureBrowserViewport(emit) {
    var development = global.CodexBridgeDesktopDSHWorkbench
      && global.CodexBridgeDesktopDSHWorkbench.mode() === "dsh";
    if ((currentNavigation && currentNavigation !== "workbench") || development) {
      emitBrowserViewport(emit, { x: 0, y: 0, width: 0, height: 0, visible: false });
      return;
    }
    var slot = document.getElementById("chat-browser-slot");
    if (!slot) return;
    var rect = slot.getBoundingClientRect();
    var left = Math.max(0, rect.left), top = Math.max(0, rect.top);
    var width = Math.max(0, Math.min(global.innerWidth, rect.right) - left);
    var height = Math.max(0, Math.min(global.innerHeight, rect.bottom) - top);
    var visible = width > 0 && height > 0 && !slot.classList.contains("browser-hidden");
    var viewport = {
      x: left,
      y: top,
      width: width,
      height: height,
      visible: visible
    };
    if (document.documentElement && document.documentElement.dataset.platform === "windows") {
      var scale = Number(global.devicePixelRatio);
      if (isFinite(scale) && scale > 0) viewport.deviceScaleFactor = scale;
    }
    emitBrowserViewport(emit, viewport);
  }

  function emitBrowserViewport(emit, viewport) {
    var signature = [viewport.x, viewport.y, viewport.width, viewport.height, viewport.visible,
      viewport.deviceScaleFactor || ""].join(":");
    if (signature === lastViewport) return;
    lastViewport = signature;
    emit("updateBrowserViewport", { viewport: viewport });
  }

  global.CodexBridgeDesktopPages = {
    render: render,
    measureBrowserViewport: measureBrowserViewport
  };
}(window));
