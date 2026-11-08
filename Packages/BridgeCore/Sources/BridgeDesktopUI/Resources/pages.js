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
  var settingsInputs = null;
  var preferencesSurface = !!(global.location && new URLSearchParams(global.location.search).get("surface") === "preferences");
  var slot = document.getElementById("chat-browser-slot");
  // Layout changes, scrolling and dialogs can fire many times per frame; they share one measurement.
  function scheduleViewportMeasure() {
    if (!viewportEmitter || viewportFrame) return;
    viewportFrame = global.requestAnimationFrame(function () {
      viewportFrame = 0;
      measureBrowserViewport(viewportEmitter);
    });
  }
  if (!preferencesSurface && global.ResizeObserver && slot) {
    new ResizeObserver(scheduleViewportMeasure).observe(slot);
  }
  if (!preferencesSurface && global.MutationObserver && document.documentElement) {
    new MutationObserver(scheduleViewportMeasure)
      .observe(document.documentElement, { attributes: true, subtree: true, attributeFilter: ["open"] });
  }
  if (!preferencesSurface && document.addEventListener) {
    document.addEventListener("close", function () {
      if (viewportEmitter) measureBrowserViewport(viewportEmitter);
    }, true);
  }

  function render(state, emit) {
    viewportEmitter = emit;
    currentNavigation = state && state.selectedNavigation;
    if (!preferencesSurface && global.CodexBridgeDesktopDSHWorkbench) {
      global.CodexBridgeDesktopDSHWorkbench.configure(state, emit);
      global.CodexBridgeDesktopDSHWorkbench.setActive(currentNavigation === "workbench", emit);
    }
    pages.connections.setActive(!!state && state.selectedNavigation === "connections", emit);
    var names = ["overview", "workbench", "projects", "logs", "connections", "settings"];
    names.forEach(function (name) {
      var section = document.getElementById(name + "-page");
      if (section) section.hidden = !state || state.selectedNavigation !== name;
    });
    if (!preferencesSurface && (!state || state.selectedNavigation !== "workbench")) {
      emitBrowserViewport(emit, { x: 0, y: 0, width: 0, height: 0, visible: false });
    }
    if (state) updateSettingsPage(state, emit);
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

  // The settings editor and the client list are rebuilt only when their inputs were replaced;
  // every host state is decoded afresh, so a changed value always arrives as a new reference.
  function updateSettingsPage(state, emit) {
    var clients = state.connections && state.connections.clients, previous = settingsInputs;
    settingsInputs = { settings: state.settings, appUpdate: state.appUpdate, clients: clients, emit: emit };
    var settingsChanged = !previous || previous.settings !== state.settings
      || previous.appUpdate !== state.appUpdate || previous.emit !== emit;
    if (settingsChanged && pages.connections.updateSettings) {
      pages.connections.updateSettings(state.settings, emit, state.appUpdate);
    }
    if ((!previous || previous.clients !== clients || previous.emit !== emit)
      && pages.settings && pages.settings.updateClients) {
      pages.settings.updateClients(clients, emit);
    }
  }

  function measureBrowserViewport(emit) {
    if (preferencesSurface) return;
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
    var dialogs = document.querySelectorAll ? Array.from(document.querySelectorAll("dialog")) : [];
    var dialogOpen = dialogs.some(function (node) {
      return !!(node && (node.open === true || node.getAttribute && typeof node.getAttribute("open") === "string"));
    });
    var visible = !dialogOpen && width > 0 && height > 0 && !slot.classList.contains("browser-hidden")
      && !popupOverlaps({ left: left, top: top, right: left + width, bottom: top + height });
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

  // The chat browser is a native view stacked above the page, so an open popup that overlaps it
  // would be hidden underneath; hide the browser while such a popup is open.
  function popupOverlaps(area) {
    if (!document.querySelectorAll) return false;
    var popups = Array.from(document.querySelectorAll("[data-browser-occluder]:not([hidden]), details[data-popup][open]"));
    return popups.some(function (popup) {
      var content = popup.tagName === "DETAILS" ? popup.querySelector(":scope > :not(summary)") : popup;
      if (!content || !content.getBoundingClientRect) return false;
      var box = content.getBoundingClientRect();
      return box.width > 0 && box.height > 0 && box.left < area.right && box.right > area.left
        && box.top < area.bottom && box.bottom > area.top;
    });
  }

  function emitBrowserViewport(emit, viewport) {
    if (preferencesSurface) return;
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
