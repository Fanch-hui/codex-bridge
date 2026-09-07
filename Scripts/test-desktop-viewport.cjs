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

test("stream updates preserve workbench selectors while control state changes refresh them", () => {
  const ui = createHarness(["pages-common.js", "pages-workbench-header.js"], [
    "workbench-browser-toolbar", "chat-browser-slot", "browser-slot-note", "workbench-inspector-header"
  ]);
  const header = ui.roots[3];
  const page = {
    projects: [{ id: "project", title: "项目" }], selectedProjectID: "project",
    tasks: [{ taskID: "task", title: "任务", provider: "codex", status: "running", selected: true }],
    selectedTaskID: "task", permissionMode: "read-only", browser: { enabled: false }
  };
  const render = ui.window.CodexBridgeDesktopWorkbenchHeader.render;
  render(page, () => {});
  const picker = header.querySelector(".task-native-select");
  picker.focus();
  render({ ...page, tasks: page.tasks.map(t => ({ ...t, updatedAt: "later" })) }, () => {});
  assert.equal(header.querySelector(".task-native-select"), picker);
  assert.equal(ui.document.activeElement, picker);
  render({ ...page, tasks: page.tasks.map(t => ({ ...t, canInterrupt: true })) }, () => {});
  assert.ok(ui.find(header, node => node.tagName === "button" && node.textContent === "中断"));
});
