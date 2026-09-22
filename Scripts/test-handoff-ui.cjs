const assert = require("node:assert/strict");
const { test } = require("node:test");
const { createHarness } = require("./desktop-ui-test-support.cjs");

function setup(storage = new Map()) {
  const ui = createHarness(["pages-common.js", "pages-workbench-handoff.js"], ["workbench-inspector-footer"]);
  const commands = [];
  if (storage) ui.window.localStorage = {
    getItem: key => storage.get(key) || null,
    setItem: (key, value) => storage.set(key, value)
  };
  const detail = { taskID: "handoff-source", updatedAt: "revision-1", handoffPrompt: "Prepare on server",
    handoffProviders: [{ id: "opencode", title: "OpenCode" }, { id: "antigravity", title: "Antigravity" }] };
  const emit = (command, payload, requestID) => commands.push({ command, payload, requestID });
  const render = (receipt = null, selected = detail) => ui.window.CodexBridgeDesktopWorkbenchHandoff.render(selected, emit, receipt);
  const button = name => ui.roots[0].querySelectorAll("button").find(value => value.textContent === name);
  const input = () => ui.roots[0].querySelector("textarea");
  const setInput = value => { input().value = value; input().dispatch("input"); };
  const receipt = (command, overrides = {}) => ({
    requestID: command.requestID, receiptID: command.requestID + "-receipt", command: "handoffTask",
    taskID: command.payload.taskID, input: command.payload.input, accepted: true,
    handoff: { handoffID: command.payload.value, sourceTaskID: command.payload.taskID,
      providerID: command.payload.providerID, prompt: "Authoritative server packet",
      additionalInstructions: command.payload.action === "prepare" ? command.payload.input : "",
      revision: "packet-hash", ready: true, phase: "prepared", model: "selected-model",
      permissionMode: "read-only", networkAllowed: false, warnings: [], ...overrides }
  });
  render();
  return { ui, detail, storage, commands, render, button, input, setInput, receipt };
}

test("prepare is non-executing and confirm references the exact immutable revision", () => {
  const h = setup();
  h.setInput("Do not change the Mac API.");
  assert.equal(h.button("确认交接").disabled, true);
  h.button("生成交接预览").dispatch("click");
  const prepared = h.commands.at(-1);
  assert.equal(prepared.payload.action, "prepare");
  h.render(h.receipt(prepared));
  h.button("确认交接").dispatch("click");
  const submitted = h.commands.at(-1);
  assert.equal(submitted.payload.action, "submit");
  assert.equal(submitted.payload.value, prepared.payload.value);
  assert.equal(submitted.payload.messageKey, "packet-hash");
  assert.equal(submitted.payload.input, "");
  assert.notEqual(submitted.requestID, prepared.requestID);
  assert.equal(h.button("确认交接").disabled, true);
  h.render(h.receipt(submitted, { ready: false, phase: "running", targetTaskID: "target-one" }));
});

test("an ambiguous submit failure requires status recovery, not a fresh submission", () => {
  const h = setup();
  h.button("生成交接预览").dispatch("click");
  h.render(h.receipt(h.commands.at(-1)));
  h.button("确认交接").dispatch("click");
  const submitted = h.commands.at(-1);
  h.render({ ...h.receipt(submitted), accepted: false, handoff: null, message: "IPC timeout" });
  assert.equal(h.button("确认交接").disabled, true);
  assert.equal(h.button("生成交接预览").disabled, true);
  assert.equal(h.button("查询交接状态").disabled, false);
  h.button("查询交接状态").dispatch("click");
  const queried = h.commands.at(-1);
  assert.equal(queried.payload.action, "status");
  assert.equal(queried.payload.value, submitted.payload.value);
  h.render(h.receipt(queried, { phase: "running", ready: false, targetTaskID: "target-one" }));
  assert.equal(h.button("打开接手任务").disabled, false);
  assert.equal(h.button("确认交接").disabled, true);
});

test("reload restores only an ID and queries rather than replaying the task", () => {
  const storage = new Map(), first = setup(storage);
  first.setInput("private draft not stored in browser");
  first.button("生成交接预览").dispatch("click");
  first.render(first.receipt(first.commands.at(-1)));
  first.button("确认交接").dispatch("click");
  const submitted = first.commands.at(-1);
  first.render({ ...first.receipt(submitted), accepted: false, handoff: null });
  assert.equal(Array.from(storage.values()).some(value => value.includes("private draft")), false);
  const restored = setup(storage);
  assert.equal(restored.commands.length, 0);
  assert.equal(restored.button("确认交接").disabled, true);
  assert.equal(restored.button("生成交接预览").disabled, true);
  restored.button("查询交接状态").dispatch("click");
  const queried = restored.commands.at(-1);
  assert.equal(queried.payload.value, submitted.payload.value);
  restored.render(restored.receipt(queried, { phase: "failed", ready: false, targetTaskID: "target-one" }));
});

test("updated source or edited supplement invalidates preview without clearing user text", () => {
  const h = setup();
  h.setInput("original supplement");
  h.button("生成交接预览").dispatch("click");
  h.render(h.receipt(h.commands.at(-1)));
  h.setInput("new supplement");
  assert.equal(h.button("确认交接").disabled, true);
  h.render(null, { ...h.detail, updatedAt: "revision-2" });
  assert.equal(h.input().value, "new supplement");
  assert.equal(h.button("确认交接").disabled, true);
  assert.equal(h.button("生成交接预览").disabled, false);
});

test("late receipts for another task cannot erase the visible task's draft", () => {
  const h = setup();
  h.setInput("first task");
  h.button("生成交接预览").dispatch("click");
  const first = h.commands.at(-1), second = { ...h.detail, taskID: "second-source" };
  h.render(null, second);
  h.setInput("second task edits");
  h.render(h.receipt(first), second);
  assert.equal(h.input().value, "second task edits");
  assert.equal(h.button("确认交接").disabled, true);
});

test("NUL, oversized UTF8 additions and unavailable durable storage fail closed", () => {
  const h = setup();
  h.setInput("x\u0000y");
  assert.equal(h.button("生成交接预览").disabled, true);
  h.setInput("中".repeat(1366));
  assert.equal(h.button("生成交接预览").disabled, true);
  const unavailable = setup(null);
  unavailable.button("生成交接预览").dispatch("click");
  assert.equal(unavailable.commands.length, 0);
});

test("foreign handoff receipt is not accepted as this task's preview", () => {
  const h = setup();
  h.button("生成交接预览").dispatch("click");
  const prepared = h.commands.at(-1);
  h.render(h.receipt(prepared, { handoffID: "other-handoff" }));
  assert.equal(h.button("确认交接").disabled, true);
});
