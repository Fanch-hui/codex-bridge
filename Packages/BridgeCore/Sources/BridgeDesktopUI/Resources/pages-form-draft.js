(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;

  function read(control) { return control.type === "checkbox" ? control.checked : control.value; }
  function write(control, value) {
    if (control.type === "checkbox") control.checked = !!value;
    else control.value = value == null ? "" : value;
  }

  function bind(controls) {
    var fields = {};
    Object.keys(controls).forEach(function (key) {
      var control = controls[key];
      var field = { control: control, baseline: read(control), server: read(control), composing: false };
      fields[key] = field;
      control.addEventListener("compositionstart", function () { field.composing = true; });
      control.addEventListener("compositionend", function () {
        field.composing = false;
        sync(field, field.server);
      });
    });
    function sync(field, value) {
      field.server = value;
      if (field.composing) return;
      if (read(field.control) === field.baseline && read(field.control) !== value) write(field.control, value);
      field.baseline = value;
    }
    return {
      update: function (values) {
        Object.keys(fields).forEach(function (key) { sync(fields[key], values[key]); });
      },
      values: function () {
        var values = {};
        Object.keys(fields).forEach(function (key) { values[key] = read(fields[key].control); });
        return values;
      }
    };
  }

  function selectOptions(control, choices) {
    var value = control.value;
    var options = S.choices(value, choices);
    var signature = JSON.stringify(options);
    if (control.__choiceSignature === signature) return;
    control.__choiceSignature = signature;
    S.clear(control);
    options.forEach(function (choice) {
      var option = S.node("option", null, choice.title);
      option.value = choice.id;
      option.disabled = choice.enabled === false;
      option.title = choice.detail || "";
      control.appendChild(option);
    });
    control.value = value;
  }

  global.CodexBridgeDesktopFormDraft = { bind: bind, selectOptions: selectOptions };
}(window));
