const assert = require("node:assert/strict");
const { test } = require("node:test");
const { createHarness } = require("./desktop-ui-test-support.cjs");

test("model effort replacement removes the old model value on selection and refresh", () => {
  const ui = createHarness(["pages-common.js", "pages-form-draft.js", "pages-settings-models.js"]);
  const control = ui.document.createElement("select");
  control.value = "xhigh";
  const options = [{ id: "low", title: "Low" }, { id: "medium", title: "Medium" }];
  const model = ui.window.CodexBridgeDesktopSettingsModels;
  model.chooseEffort(control, options, true, "medium");
  assert.equal(control.value, "medium");
  assert.deepEqual(control.children.map(option => option.value), ["low", "medium"]);
  model.chooseEffort(control, options, false, "low");
  assert.equal(control.value, "medium");
  assert.deepEqual(control.children.map(option => option.value), ["low", "medium"]);
});

test("a model without effort options cannot retain another model's effort", () => {
  const ui = createHarness(["pages-common.js", "pages-form-draft.js", "pages-settings-models.js"]);
  const control = ui.document.createElement("select");
  control.value = "high";
  ui.window.CodexBridgeDesktopSettingsModels.chooseEffort(control, [], true, "");
  assert.equal(control.value, "");
  assert.equal(control.children.length, 0);
});
