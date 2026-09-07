const assert = require("node:assert/strict");
const { test } = require("node:test");
const { createHarness } = require("./desktop-ui-test-support.cjs");

test("native browser bounds follow the visible viewport and stop when disabled", () => {
  const ui = createHarness([], ["chat-browser-slot"]);
  const slot = ui.roots[0];
  let disabled = false;
  slot.classList.contains = () => disabled;
  slot.getBoundingClientRect = () => ({ left: 68, top: 100, right: 900, bottom: 800 });
  ui.window.innerWidth = 700;
  ui.window.innerHeight = 600;
  ui.load("pages.js");
  const commands = [];
  const emit = (command, payload) => commands.push({ command, ...JSON.parse(JSON.stringify(payload)) });
  const measure = ui.window.CodexBridgeDesktopPages.measureBrowserViewport;
  measure(emit);
  assert.deepEqual(commands[0], {
    command: "updateBrowserViewport",
    viewport: { x: 68, y: 100, width: 632, height: 500, visible: true }
  });
  measure(emit);
  assert.equal(commands.length, 1);
  disabled = true;
  measure(emit);
  assert.equal(commands[1].viewport.visible, false);
});

test("workbench icon roles retain the shared sizing and stroke class", () => {
  const ui = createHarness(["pages-common.js"]);
  const icon = ui.window.CodexBridgeDesktopPageSupport.icon("chevron.down", "dropdown-arrow");
  assert.equal(icon.className, "icon dropdown-arrow");
  assert.equal(icon.dataset.symbol, "chevron.down");
});
