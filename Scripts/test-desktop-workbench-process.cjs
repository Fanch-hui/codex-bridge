const assert = require("node:assert/strict");
const { test } = require("node:test");
const { createHarness } = require("./desktop-ui-test-support.cjs");

for (const platform of ["macos", "windows"]) {
  test(`${platform} terminal process mounts only after expanding`, () => {
    const ui = createHarness([
      "icons.js", "pages-common.js", "pages-workbench-conversation.js", "pages-workbench-process.js",
      "pages-workbench-conversation-incremental.js"
    ], ["conversation"]);
    ui.document.documentElement = { dataset: { platform } };
    const container = ui.roots[0];
    const entries = [
      { id: "user", role: "用户", kind: "user", text: "Do the work", isFinal: true },
      { id: "thinking", role: "助手", kind: "reasoning", text: "Thinking", isFinal: true },
      { id: "tool", role: "助手", kind: "tool_call", text: "Result", toolName: "shell", isFinal: true },
      { id: "final", role: "助手", kind: "agent", text: "Done", isFinal: true }
    ];
    const page = { selectedTaskID: "t", selectedProjectID: "p", selectedTask: {
      taskID: "t", providerID: "deepseek-harness", isTerminal: false, conversationState: {}
    } };
    const render = () => ui.window.CodexBridgeDesktopWorkbenchConversation.render(container, entries, page, () => {});
    render();
    assert.equal(container.querySelector(".conversation-process"), null);
    assert.ok(container.querySelector(".entry-tool_call"));
    page.selectedTask.isTerminal = true;
    ui.window.CodexBridgeDesktopPageSupport.clear(container);
    render();
    let process = container.querySelector(".conversation-process");
    assert.equal(process.open, false);
    assert.equal(container.querySelector(".entry-tool_call"), null);
    assert.ok(container.querySelector(".entry-user"));
    assert.equal(container.querySelector(".entry-agent .entry-text")?.textContent ||
      container.querySelector(".entry-agent").querySelector(".entry-text").textContent, "Done");
    process.open = true; process.dispatch("toggle");
    assert.ok(process.querySelector(".entry-tool_call"));
    assert.match(process.querySelector(".entry-symbol").innerHTML, /<svg /);
    assert.match(process.querySelector(".entry-disclosure-chevron").innerHTML, /<svg /);
    ui.window.CodexBridgeDesktopPageSupport.clear(container);
    render();
    process = container.querySelector(".conversation-process");
    assert.equal(process.open, true);
    process.open = false; process.dispatch("toggle");
    assert.equal(process.querySelector(".entry-tool_call"), null);
  });
}

const multiTurnEntries = [
  { id: "u1", role: "用户", kind: "user", text: "修复登录失败", isFinal: true },
  { id: "r1", role: "助手", kind: "reasoning", text: "先看日志", isFinal: true },
  { id: "t1", role: "助手", kind: "tool_call", text: "log", toolName: "read_file", isFinal: true },
  { id: "m1", role: "助手", kind: "agent", text: "中间说明：已定位到鉴权模块", isFinal: true },
  { id: "t2", role: "助手", kind: "tool_call", text: "diff", toolName: "apply_patch", isFinal: true },
  { id: "f1", role: "助手", kind: "agent", text: "Turn 1 最终报告", isFinal: true },
  { id: "u2", role: "用户", kind: "user", text: "汇报一下进度", isFinal: true },
  { id: "t3", role: "助手", kind: "tool_call", text: "status", toolName: "shell", isFinal: true },
  { id: "f2", role: "助手", kind: "agent", text: "Turn 2 回复", isFinal: true },
  { id: "u3", role: "用户", kind: "user", text: "继续", isFinal: true },
  { id: "f3", role: "助手", kind: "agent", text: "Turn 3 回复", isFinal: true }
];

function multiTurnHarness(isTerminal) {
  const ui = createHarness([
    "icons.js", "pages-common.js", "pages-workbench-conversation.js", "pages-workbench-process.js",
    "pages-workbench-conversation-incremental.js"
  ], ["conversation"]);
  ui.document.documentElement = { dataset: { platform: "macos" } };
  const page = { selectedTaskID: "t", selectedProjectID: "p", selectedTask: {
    taskID: "t", providerID: "antigravity", isTerminal, conversationState: {}
  } };
  return { ui, page, container: ui.roots[0] };
}

test("terminal turns split into user, collapsed process and one final reply", () => {
  const { ui, page } = multiTurnHarness(true);
  const grouped = ui.window.CodexBridgeDesktopWorkbenchProcess.entries(multiTurnEntries, page);
  assert.deepEqual(
    Array.from(grouped.map(entry => entry.id)),
    ["u1", "process:r1", "f1", "u2", "process:t3", "f2", "u3", "f3"]
  );
  assert.deepEqual(Array.from(grouped[1].processEntries.map(entry => entry.id)), ["r1", "t1", "m1", "t2"]);
  assert.deepEqual(Array.from(grouped[4].processEntries.map(entry => entry.id)), ["t3"]);
});

test("running task keeps every entry expanded in real order", () => {
  const { ui, page } = multiTurnHarness(false);
  assert.deepEqual(
    ui.window.CodexBridgeDesktopWorkbenchProcess.entries(multiTurnEntries, page),
    multiTurnEntries
  );
});

test("intermediate narration stays folded while each turn reply stays visible", () => {
  const { ui, page, container } = multiTurnHarness(true);
  const render = () => ui.window.CodexBridgeDesktopWorkbenchConversation.render(
    container, multiTurnEntries, page, () => {});
  const visibleText = root => root.querySelectorAll(".entry-text").map(node => node.textContent);
  render();
  const blocks = container.querySelectorAll(".conversation-process");
  assert.equal(blocks.length, 2);
  assert.equal(blocks[0].open, false);
  assert.equal(blocks[1].open, false);
  assert.equal(blocks[0].__heading.textContent, "执行过程（4 条）");
  assert.equal(blocks[1].__heading.textContent, "执行过程（1 条）");
  assert.deepEqual(visibleText(container), [
    "修复登录失败", "Turn 1 最终报告", "汇报一下进度", "Turn 2 回复", "继续", "Turn 3 回复"
  ]);
  blocks[0].open = true;
  blocks[0].dispatch("toggle");
  assert.deepEqual(visibleText(blocks[0]), ["先看日志", "中间说明：已定位到鉴权模块"]);
  assert.equal(blocks[0].querySelectorAll(".entry-tool_call").length, 2);
  assert.deepEqual(visibleText(container), [
    "修复登录失败", "先看日志", "中间说明：已定位到鉴权模块",
    "Turn 1 最终报告", "汇报一下进度", "Turn 2 回复", "继续", "Turn 3 回复"
  ]);
});
