const assert = require("node:assert/strict");
const { test } = require("node:test");
const { createHarness } = require("./desktop-ui-test-support.cjs");

function sidebar(compact) {
  const ui = createHarness([], ["app-shell"]);
  const shell = ui.roots[0];
  const button = ui.document.createElement("button");
  let collapsed;
  let resize;
  let measurements = 0;
  shell.classList.toggle = (name, value) => { collapsed = value; };
  ui.document.querySelector = () => button;
  const media = { matches: compact, addEventListener: (_, listener) => { resize = listener; } };
  ui.window.matchMedia = () => media;
  ui.window.requestAnimationFrame = callback => callback();
  ui.window.CodexBridgeDesktopUI = { sendCommand() {} };
  ui.window.CodexBridgeDesktopPages = { measureBrowserViewport() { measurements += 1; } };
  ui.load("sidebar.js");
  return {
    button,
    get collapsed() { return collapsed; },
    get measurements() { return measurements; },
    setCompact(value) { media.matches = value; resize(); }
  };
}

test("compact windows can expand the sidebar and retain the choice after resizing", () => {
  const ui = sidebar(true);
  assert.equal(ui.collapsed, true);
  assert.equal(ui.button.getAttribute("aria-expanded"), "false");
  ui.button.dispatch("click");
  assert.equal(ui.collapsed, false);
  assert.equal(ui.button.getAttribute("aria-label"), "收起侧边栏");
  assert.equal(ui.measurements, 2);
  ui.setCompact(false);
  ui.setCompact(true);
  assert.equal(ui.collapsed, false);
  ui.button.dispatch("click");
  assert.equal(ui.collapsed, true);
});

test("sidebar follows window size until the user chooses its state", () => {
  const ui = sidebar(false);
  assert.equal(ui.collapsed, false);
  ui.setCompact(true);
  assert.equal(ui.collapsed, true);
  ui.setCompact(false);
  assert.equal(ui.collapsed, false);
});
