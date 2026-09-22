const assert = require("node:assert/strict");
const { test } = require("node:test");
const { createHarness } = require("./desktop-ui-test-support.cjs");

function directPage(overrides = {}) {
  return {
    canSave: true,
    commandMode: "safe",
    allowedCommands: ["git status"],
    deniedCommands: [],
    ...overrides
  };
}

test("Direct edits compose on top of stale snapshots", () => {
  const ui = createHarness(["pages-common.js", "pages-direct.js"]);
  const editor = ui.window.CodexBridgeDesktopDirect.create();
  const commands = [];
  const emit = (command, payload) => commands.push({ command, payload: JSON.parse(JSON.stringify(payload)) });
  editor.update(directPage(), emit);

  const mode = editor.root.querySelector("select");
  mode.value = "full";
  mode.dispatch("change");
  const inputs = editor.root.querySelectorAll("input");
  inputs[0].value = "npm test";
  inputs[0].dispatch("input");
  editor.root.querySelectorAll("button").find(button => button.textContent === "添加").dispatch("click");

  editor.update(directPage(), emit);
  const payload = JSON.parse(commands.at(-1).payload.value);
  assert.equal(payload.commandMode, "full");
  assert.deepEqual(payload.allowedCommands, ["git status", "npm test"]);
  assert.equal(mode.value, "full");
});

test("workbench controls use a multiline draft and persist it by task", () => {
  const ui = createHarness([
    "pages-common.js", "pages-form-draft.js", "pages-workbench-controls.js"
  ], ["workbench-inspector-footer"]);
  const storage = new Map();
  ui.window.localStorage = {
    getItem: key => storage.get(key) || null,
    setItem: (key, value) => storage.set(key, value)
  };
  const footer = ui.roots[0], commands = [];
  const page = {
    selectedTaskID: "task-a",
    selectedTask: { taskID: "task-a", canSteer: true },
    steerModes: [{ id: "queued", title: "排队" }],
    engineStatus: "运行中"
  };
  const render = value => ui.window.CodexBridgeDesktopWorkbenchControls.render(
    value, (command, payload) => commands.push({ command, payload })
  );
  render(page);
  const input = ui.document.getElementById("workbench-task-input");
  assert.equal(input.tagName, "textarea");
  input.value = "第一行";
  input.dispatch("input");
  input.value += "\n第二行";
  input.dispatch("input");
  render({ ...page, engineStatus: "仍在运行" });
  assert.equal(ui.document.getElementById("workbench-task-input"), input);
  assert.equal(input.value, "第一行\n第二行");

  const second = createHarness([
    "pages-common.js", "pages-form-draft.js", "pages-workbench-controls.js"
  ], ["workbench-inspector-footer"]);
  second.window.localStorage = ui.window.localStorage;
  second.window.CodexBridgeDesktopWorkbenchControls.render(page, () => {});
  assert.equal(second.document.getElementById("workbench-task-input").value, "第一行\n第二行");
  const send = footer.querySelector("button");
  send.dispatch("click");
  assert.equal(commands[0].command, "steerTask");
});

test("project delete confirmation survives collection refresh", () => {
  const ui = createHarness(["pages-common.js", "pages-project-collections.js"], ["collections"]);
  const container = ui.roots[0], page = {
    selectedProjectID: "project-a",
    sessions: [{
      projectID: "project-a", sessionID: "session-a", taskID: "task-a", providerID: "codex",
      provider: "Codex", title: "检查项目", turnCount: 1, status: "运行中", isRunning: true,
      selected: false, canDelete: true
    }],
    skills: [], verificationCommands: []
  };
  ui.window.CodexBridgeDesktopProjectCollections.render(container, page, () => {});
  const remove = ui.find(container, node => node.tagName === "button" && node.textContent === "删除");
  remove.dispatch("click");
  assert.equal(remove.hidden, true);
  ui.window.CodexBridgeDesktopProjectCollections.render(container, page, () => {});
  const confirmation = container.querySelector(".session-confirmation");
  assert.equal(confirmation.hidden, false);
});

test("stable rendering defers an active control until focus leaves", () => {
  const ui = createHarness([], ["stable"]);
  ui.window.addEventListener = () => {};
  ui.window.setTimeout = callback => callback();
  ui.load("pages-workbench.js");
  const container = ui.roots[0], button = ui.document.createElement("button");
  container.appendChild(button);
  const stable = ui.window.CodexBridgeDesktopStableRender;
  let renders = 0;
  stable(container, "first", () => { renders += 1; });
  button.focus();
  stable(container, "second", () => { renders += 1; });
  assert.equal(renders, 1);
  ui.document.activeElement = null;
  container.dispatch("focusout");
  assert.equal(renders, 2);
});

test("state patches apply the Swift wire and resync on a revision gap", () => {
  const ui = createHarness(["app.js"], [
    "app-shell", "loading-state", "navigation", "page-title", "connection-indicator",
    "connection-label", "refresh-indicator", "refresh-button"
  ]);
  ui.document.getElementById("refresh-button").className = "refresh-button";
  const commands = [];
  ui.window.addEventListener("codex-bridge-command", event => commands.push(event.detail));
  const task = {
    taskID: "task-a", sessionID: "session-a", title: "检查项目", projectName: "Bridge",
    status: "运行中", provider: "Codex", providerID: "codex", conversation: [
      { id: "entry-a", role: "user", kind: "message", text: "开始", isFinal: true }
    ], conversationState: {}
  };
  const state = {
    hostContext: null, navigation: [], selectedNavigation: "workbench", connectionLabel: "就绪",
    connectionTone: "neutral", isRefreshing: false, feedback: null, overview: null,
    workbench: {
      header: { title: "工作台" }, projects: [], selectedProjectID: null, permissionMode: "workspace-write",
      permissionOptions: [], tasks: [{ taskID: "task-a", title: "检查项目" }], selectedTaskID: "task-a",
      selectedTask: task, history: {}, approvals: [], steerModes: [], browser: {}
    }
  };
  ui.window.CodexBridgeDesktopUI.applyStatePatch({
    type: "statePatch", nextRevision: 10, state, changes: []
  });
  assert.equal(ui.window.CodexBridgeDesktopUI.getStateRevision(), 10);

  ui.window.CodexBridgeDesktopUI.applyStatePatch({
    type: "statePatch", baseRevision: 10, nextRevision: 11, state: null,
    changes: [
      {
        kind: "conversation", taskID: "task-a", conversationMode: "upsert",
        entries: [{ id: "entry-b", role: "assistant", kind: "message", text: "完成", isFinal: true }],
        removedIDs: [], conversationState: {}
      },
      {
        kind: "taskRows", collectionMode: "upsert", taskRows: [{ taskID: "task-a", title: "已完成" }],
        removedIDs: []
      }
    ]
  });
  assert.equal(ui.window.CodexBridgeDesktopUI.getStateRevision(), 11);
  assert.equal(ui.window.CodexBridgeDesktopUI.getState().workbench.tasks[0].title, "已完成");
  assert.deepEqual(
    ui.window.CodexBridgeDesktopUI.getState().workbench.selectedTask.conversation.map(entry => entry.id),
    ["entry-a", "entry-b"]
  );

  ui.window.CodexBridgeDesktopUI.setState({
    type: "statePatch", baseRevision: 12, nextRevision: 13, state: null, changes: []
  });
  assert.equal(ui.window.CodexBridgeDesktopUI.getStateRevision(), 11);
  assert.equal(commands.at(-1).command, "requestStateResync");
});

test("tool cards keep real name, status, input and output while streaming", () => {
  const ui = createHarness([
    "pages-common.js", "pages-workbench-conversation.js", "pages-workbench-conversation-incremental.js"
  ], ["conversation"]);
  const container = ui.roots[0], page = {
    selectedProjectID: "project-a", selectedTaskID: "task-a",
    selectedTask: { taskID: "task-a", providerID: "codex", conversationState: {} }
  };
  const render = entry => ui.window.CodexBridgeDesktopWorkbenchConversation.render(
    container, [entry], page, () => {}, { owner: container }
  );
  render({
    id: "tool-a", role: "助手", kind: "tool_call", toolName: "delegate_subagent",
    toolStatus: "in_progress", toolArguments: '{"task":"检查 Swift"}', text: "等待子代理输出…", isFinal: false,
    childRuns: [{ id: "child-a", name: "Swift 检查代理", status: "in_progress", summary: "读取相关文件" }]
  });
  const card = container.querySelector(".conversation-entry");
  assert.equal(card.querySelector(".entry-tool-name").textContent, "工具：delegate_subagent");
  assert.match(card.querySelector(".entry-arguments").textContent, /检查 Swift/);
  assert.equal(card.querySelector(".entry-output").textContent, "等待子代理输出…");
  assert.equal(card.querySelector(".entry-child-run-name").textContent, "Swift 检查代理");
  assert.equal(card.querySelector(".entry-child-run-status").textContent, "in_progress");
  const output = card.querySelector(".entry-output");
  render({
    id: "tool-a", role: "助手", kind: "tool_call", toolName: "delegate_subagent",
    toolStatus: "in_progress", toolArguments: '{"task":"检查 Swift"}', text: "等待子代理输出…", isFinal: false,
    childRuns: [{ id: "child-a", name: "Swift 检查代理", status: "completed", summary: "已完成" }]
  });
  assert.equal(container.querySelector(".conversation-entry").querySelector(".entry-output"), output);
  assert.equal(card.querySelector(".entry-child-run-status").textContent, "completed");
  render({
    id: "tool-a", role: "助手", kind: "tool_call", toolName: "delegate_subagent",
    toolStatus: "completed", toolArguments: '{"task":"检查 Swift"}', text: "完成\n[REDACTED]", isFinal: true,
    childRuns: [{ id: "child-a", name: "Swift 检查代理", status: "completed", summary: "已完成" }]
  });
  assert.equal(container.querySelector(".conversation-entry").querySelector(".entry-output"), output);
  assert.equal(output.textContent, "完成\n[REDACTED]");
});

test("terminal handoff requires a server preview before submission", () => {
  const ui = createHarness([
    "pages-common.js", "pages-form-draft.js", "pages-workbench-handoff.js"
  ], ["workbench-inspector-footer"]);
  const footer = ui.roots[0], status = ui.document.createElement("div");
  footer.appendChild(status);
  const commands = [], handoff = ui.window.CodexBridgeDesktopWorkbenchHandoff;
  const storage = new Map();
  ui.window.localStorage = {
    getItem: key => storage.get(key) || null,
    setItem: (key, value) => storage.set(key, value)
  };
  const detail = {
    taskID: "task-terminal", handoffPrompt: "请接续检查失败日志", handoffProviders: [
      { id: "opencode", title: "OpenCode" }, { id: "agy", title: "Antigravity" }
    ]
  };
  handoff.render(detail, (command, payload, requestID) => commands.push({ command, payload, requestID }), null);
  const disclosure = footer.querySelector("details");
  disclosure.open = true;
  disclosure.dispatch("toggle");
  const input = footer.querySelector("textarea");
  input.value = "请接续检查失败日志\n先确认测试失败原因";
  input.dispatch("input");
  footer.querySelector("button").dispatch("click");
  assert.equal(commands[0].command, "handoffTask");
  assert.equal(commands[0].payload.action, "prepare");
  assert.equal(commands[0].payload.providerID, "opencode");
  assert.equal(commands[0].payload.input, input.value);
  const failed = {
    receiptID: "handoff-failed", requestID: commands[0].requestID, command: "handoffTask",
    taskID: detail.taskID, input: commands[0].payload.input, accepted: false
  };
  handoff.render(detail, () => {}, failed);
  assert.equal(input.value, commands[0].payload.input);
  assert.equal(footer.querySelector("button").disabled, false);
  footer.querySelector("button").dispatch("click");
  const accepted = {
    ...failed, receiptID: "handoff-ok", requestID: commands[1].requestID,
    input: commands[1].payload.input, accepted: true,
    handoff: {
      handoffID: commands[1].payload.value, sourceTaskID: detail.taskID,
      providerID: "opencode", revision: "preview-revision", model: "model",
      permissionMode: "read-only", networkAllowed: false, phase: "prepared",
      prompt: "服务端完整交接正文", additionalInstructions: commands[1].payload.input,
      ready: true, warnings: []
    }
  };
  handoff.render(detail, () => {}, accepted);
  assert.equal(input.value, commands[1].payload.input);
  const confirm = footer.querySelectorAll("button").find(button => button.textContent === "确认交接");
  assert.equal(confirm.disabled, false);
  confirm.dispatch("click");
  assert.equal(commands[2].payload.action, "submit");
  assert.equal(commands[2].payload.value, commands[1].payload.value);
  assert.equal(commands[2].payload.messageKey, "preview-revision");
});
