(function () {
  "use strict";

  var shell = document.getElementById("app-shell");
  var button = document.querySelector(".sidebar-toggle");
  var divider = document.querySelector(".sidebar-divider");
  var compactWindow = window.matchMedia("(max-width: 900px)");
  var preferenceKey = "codex-bridge.sidebar-collapsed";
  var widthKey = "codex-bridge.sidebar-width";
  var minWidth = 220, maxWidth = 340, defaultWidth = 252;
  var selectedCollapsed = readPreference();
  var preferredWidth = readWidth();
  var drag = null, measurementPending = false;

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

  function readWidth() {
    try {
      var stored = window.localStorage.getItem(widthKey);
      var value = Number(stored);
      if (stored !== null && Number.isFinite(value) && value > 0) {
        return Math.max(minWidth, Math.min(maxWidth, value));
      }
    } catch (_) {}
    return defaultWidth;
  }

  function availableWidth() {
    return Math.max(minWidth, Math.min(maxWidth, window.innerWidth - 520));
  }

  function effectiveWidth() {
    return Math.min(preferredWidth, availableWidth());
  }

  function measureBrowserViewport() {
    if (measurementPending) return;
    measurementPending = true;
    window.requestAnimationFrame(function () {
      measurementPending = false;
      if (window.CodexBridgeDesktopPages && window.CodexBridgeDesktopUI) {
        window.CodexBridgeDesktopPages.measureBrowserViewport(window.CodexBridgeDesktopUI.sendCommand);
      }
    });
  }

  function applyWidth() {
    var width = effectiveWidth();
    shell.style.setProperty("--sidebar-width", width + "px");
    divider.setAttribute("aria-valuenow", String(width));
    divider.setAttribute("aria-valuemax", String(availableWidth()));
    measureBrowserViewport();
  }

  function resizeTo(width) {
    preferredWidth = Math.max(minWidth, Math.min(availableWidth(), Math.round(width)));
    applyWidth();
  }

  function saveWidth() {
    try { window.localStorage.setItem(widthKey, String(preferredWidth)); } catch (_) {}
  }

  function apply() {
    var collapsed = isCollapsed();
    shell.classList.toggle("sidebar-collapsed", collapsed);
    divider.hidden = collapsed;
    button.setAttribute("aria-expanded", String(!collapsed));
    button.setAttribute("aria-label", collapsed ? "展开侧边栏" : "收起侧边栏");
    button.title = collapsed ? "展开侧边栏" : "收起侧边栏";
    applyWidth();
  }

  button.addEventListener("click", function () {
    selectedCollapsed = !isCollapsed();
    try { window.localStorage.setItem(preferenceKey, String(selectedCollapsed)); } catch (_) {}
    apply();
  });

  divider.addEventListener("pointerdown", function (event) {
    if (event.button !== 0) return;
    event.preventDefault();
    drag = { pointerID: event.pointerId, x: event.clientX, width: effectiveWidth(), previous: preferredWidth };
    divider.setPointerCapture(event.pointerId);
    document.body.classList.add("sidebar-is-resizing");
  });
  divider.addEventListener("pointermove", function (event) {
    if (drag && event.pointerId === drag.pointerID) resizeTo(drag.width + event.clientX - drag.x);
  });
  function finishDrag(event, cancelled) {
    if (!drag || event.pointerId !== drag.pointerID) return;
    if (cancelled) {
      preferredWidth = drag.previous;
      applyWidth();
    } else saveWidth();
    drag = null;
    document.body.classList.remove("sidebar-is-resizing");
  }
  divider.addEventListener("pointerup", function (event) { finishDrag(event, false); });
  divider.addEventListener("pointercancel", function (event) { finishDrag(event, true); });
  divider.addEventListener("lostpointercapture", function (event) { finishDrag(event, true); });
  divider.addEventListener("keydown", function (event) {
    var width = effectiveWidth();
    if (event.key === "ArrowLeft") width -= 8;
    else if (event.key === "ArrowRight") width += 8;
    else if (event.key === "Home") width = minWidth;
    else if (event.key === "End") width = maxWidth;
    else return;
    event.preventDefault();
    resizeTo(width);
    saveWidth();
  });
  compactWindow.addEventListener("change", apply);
  window.addEventListener("resize", applyWidth);
  apply();
}());
