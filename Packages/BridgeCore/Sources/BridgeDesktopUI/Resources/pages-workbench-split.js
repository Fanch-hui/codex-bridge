(function (global) {
  "use strict";

  var STORAGE_KEY = "codex-bridge.workbench.split.v1";
  var DIVIDER_SIZE = 8;
  var MIN_BROWSER_WIDTH = 320;
  var MIN_INSPECTOR_WIDTH = 280;
  var MIN_BROWSER_HEIGHT = 180;
  var MIN_INSPECTOR_HEIGHT = 180;
  var activeDrag;

  function readSavedSizes() {
    try {
      var value = JSON.parse(global.localStorage.getItem(STORAGE_KEY) || "{}");
      return {
        width: finitePositive(value.width) ? value.width : null,
        height: finitePositive(value.height) ? value.height : null
      };
    } catch (_) {
      return { width: null, height: null };
    }
  }

  function saveSizes(sizes) {
    try { global.localStorage.setItem(STORAGE_KEY, JSON.stringify(sizes)); } catch (_) {}
  }

  function finitePositive(value) {
    return typeof value === "number" && isFinite(value) && value > 0;
  }

  function isStacked() {
    return global.matchMedia && global.matchMedia("(max-width: 700px)").matches;
  }

  function axisValues(layout) {
    var stacked = isStacked();
    var rect = layout.getBoundingClientRect();
    return {
      stacked: stacked,
      available: stacked ? rect.height : rect.width,
      minimum: stacked ? MIN_INSPECTOR_HEIGHT : MIN_INSPECTOR_WIDTH,
      otherMinimum: stacked ? MIN_BROWSER_HEIGHT : MIN_BROWSER_WIDTH,
      property: stacked ? "--workbench-inspector-height" : "--workbench-inspector-width"
    };
  }

  function clampSize(layout, value) {
    var axis = axisValues(layout);
    var maximum = Math.max(axis.minimum, axis.available - axis.otherMinimum - DIVIDER_SIZE);
    return Math.round(Math.max(axis.minimum, Math.min(maximum, value)));
  }

  function currentSize(layout, inspector, axis) {
    var dimension = axis.stacked ? inspector.getBoundingClientRect().height : inspector.getBoundingClientRect().width;
    if (dimension > 0) return dimension;
    var value = parseFloat(global.getComputedStyle(layout).getPropertyValue(axis.property));
    return finitePositive(value) ? value : axis.minimum;
  }

  function setSize(layout, size, persist) {
    var axis = axisValues(layout);
    var value = clampSize(layout, size);
    layout.style.setProperty(axis.property, value + "px");
    updateAccessibility(layout, value);
    if (persist) {
      var saved = readSavedSizes();
      saved[axis.stacked ? "height" : "width"] = value;
      saveSizes(saved);
    }
    return value;
  }

  function updateAccessibility(layout, value) {
    var divider = document.getElementById("workbench-divider");
    if (!divider) return;
    var axis = axisValues(layout);
    var maximum = Math.max(axis.minimum, axis.available - axis.otherMinimum - DIVIDER_SIZE);
    divider.setAttribute("aria-orientation", axis.stacked ? "horizontal" : "vertical");
    divider.setAttribute("aria-valuemin", String(axis.minimum));
    divider.setAttribute("aria-valuemax", String(Math.round(maximum)));
    divider.setAttribute("aria-valuenow", String(Math.round(value || currentSize(layout, document.getElementById("workbench-inspector-pane"), axis))));
  }

  function finishDrag() {
    if (!activeDrag) return;
    var drag = activeDrag;
    activeDrag = null;
    global.removeEventListener("pointermove", drag.move);
    global.removeEventListener("pointerup", drag.end);
    global.removeEventListener("pointercancel", drag.end);
    drag.divider.classList.remove("is-dragging");
    document.body.classList.remove("workbench-is-resizing");
    try { drag.divider.releasePointerCapture(drag.pointerID); } catch (_) {}
    setSize(drag.layout, drag.size, true);
  }

  function beginDrag(event, layout, divider, inspector) {
    if (event.button !== 0 || layout.classList.contains("inspector-hidden")) return;
    event.preventDefault();
    var axis = axisValues(layout);
    var startCoordinate = axis.stacked ? event.clientY : event.clientX;
    var startSize = currentSize(layout, inspector, axis);
    var drag = { layout: layout, divider: divider, inspector: inspector, axis: axis,
      pointerID: event.pointerId, startCoordinate: startCoordinate, size: startSize };
    drag.move = function (moveEvent) {
      if (moveEvent.pointerId !== drag.pointerID) return;
      moveEvent.preventDefault();
      var coordinate = axis.stacked ? moveEvent.clientY : moveEvent.clientX;
      drag.size = setSize(layout, startSize + startCoordinate - coordinate, false);
    };
    drag.end = function (endEvent) {
      if (!endEvent || endEvent.pointerId === drag.pointerID) finishDrag();
    };
    activeDrag = drag;
    divider.classList.add("is-dragging");
    document.body.classList.add("workbench-is-resizing");
    try { divider.setPointerCapture(event.pointerId); } catch (_) {}
    global.addEventListener("pointermove", drag.move, { passive: false });
    global.addEventListener("pointerup", drag.end);
    global.addEventListener("pointercancel", drag.end);
  }

  function keyboardResize(event, layout, divider) {
    if (layout.classList.contains("inspector-hidden")) return;
    var axis = axisValues(layout);
    var step = event.shiftKey ? 48 : 16;
    var delta = 0;
    if (!axis.stacked && event.key === "ArrowLeft") delta = step;
    if (!axis.stacked && event.key === "ArrowRight") delta = -step;
    if (axis.stacked && event.key === "ArrowUp") delta = step;
    if (axis.stacked && event.key === "ArrowDown") delta = -step;
    if (event.key === "Home") delta = axis.minimum - currentSize(layout, document.getElementById("workbench-inspector-pane"), axis);
    if (event.key === "End") delta = axis.available - axis.otherMinimum - DIVIDER_SIZE - currentSize(layout, document.getElementById("workbench-inspector-pane"), axis);
    if (!delta) return;
    event.preventDefault();
    setSize(layout, currentSize(layout, document.getElementById("workbench-inspector-pane"), axis) + delta, true);
    divider.focus({ preventScroll: true });
  }

  function updateLayoutAccessibility(layout) {
    var inspector = document.getElementById("workbench-inspector-pane");
    if (!inspector) return;
    var axis = axisValues(layout);
    if (axis.available <= 0) return;
    var size = currentSize(layout, inspector, axis);
    var maximum = Math.max(axis.minimum, axis.available - axis.otherMinimum - DIVIDER_SIZE);
    if (size > maximum) size = setSize(layout, maximum, false);
    updateAccessibility(layout, size);
  }

  function mount() {
    var layout = document.querySelector(".workbench-layout");
    var divider = document.getElementById("workbench-divider");
    var inspector = document.getElementById("workbench-inspector-pane");
    if (!layout || !divider || !inspector || layout.dataset.splitterReady) return;
    layout.dataset.splitterReady = "true";
    var saved = readSavedSizes();
    if (saved.width) layout.style.setProperty("--workbench-inspector-width", saved.width + "px");
    if (saved.height) layout.style.setProperty("--workbench-inspector-height", saved.height + "px");
    divider.addEventListener("pointerdown", function (event) { beginDrag(event, layout, divider, inspector); });
    divider.addEventListener("keydown", function (event) { keyboardResize(event, layout, divider); });
    global.addEventListener("resize", function () { global.requestAnimationFrame(function () { updateLayoutAccessibility(layout); }); });
    updateLayoutAccessibility(layout);
  }

  mount();
  global.CodexBridgeDesktopWorkbenchSplit = { sync: function () {
    var layout = document.querySelector(".workbench-layout");
    if (layout) updateLayoutAccessibility(layout);
  } };
}(window));
