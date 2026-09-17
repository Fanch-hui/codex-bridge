const assert = require("node:assert/strict");
const { test } = require("node:test");
const { createHarness } = require("./desktop-ui-test-support.cjs");

for (const platform of ["macos", "windows"]) {
  test(`${platform} terminal process mounts only after expanding`, () => {
    const ui = createHarness([
      "pages-common.js", "pages-workbench-conversation.js", "pages-workbench-process.js",
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
    ui.window.CodexBridgeDesktopPageSupport.clear(container);
    render();
    process = container.querySelector(".conversation-process");
    assert.equal(process.open, true);
    process.open = false; process.dispatch("toggle");
    assert.equal(process.querySelector(".entry-tool_call"), null);
  });
}
