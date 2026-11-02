(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;

  function create(root, callbacks) {
    var pending = new Map();
    function lock(control, entry) {
      entry.controls.push({ control: control, disabled: control.disabled, label: control.textContent });
      control.disabled = true; control.setAttribute("aria-busy", "true");
      if (control === entry.trigger) control.textContent = entry.progress;
    }
    function button(label, onClick, group, disabled) {
      var control = S.button(label, null, {}, null, "small");
      control.disabled = !!disabled;
      if (group) {
        control.dataset.dshActionGroup = group;
        if (pending.has(group)) lock(control, pending.get(group));
      }
      control.addEventListener("click", function (event) {
        if (control.disabled || group && pending.has(group)) return;
        onClick(event);
      });
      return control;
    }
    function run(control, group, progress, success, operation) {
      if (pending.has(group)) return Promise.resolve(false);
      var entry = { trigger: control, progress: progress, controls: [] };
      pending.set(group, entry);
      Array.from(root.querySelectorAll("button")).forEach(function (item) {
        if (item.dataset.dshActionGroup === group) lock(item, entry);
      });
      var result;
      try { result = operation(); }
      catch (failure) { callbacks.error(failure); result = false; }
      var revision = callbacks.revision();
      return Promise.resolve(result).then(function (value) {
        if (value !== false && result && typeof result.then === "function" && success && revision === callbacks.revision()) {
          callbacks.success(success);
        }
        return value;
      }).catch(function (failure) { callbacks.error(failure); return false; }).finally(function () {
        pending.delete(group);
        entry.controls.forEach(function (item) {
          item.control.disabled = item.disabled; item.control.textContent = callbacks.label(item.control, item.label);
          item.control.removeAttribute("aria-busy");
        });
      });
    }
    return { button: button, run: run };
  }
  global.CodexBridgeDesktopEmbeddedDSHActionFeedback = { create: create };
}(window));
