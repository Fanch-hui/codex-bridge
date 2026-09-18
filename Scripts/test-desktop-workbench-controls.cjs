const assert = require("node:assert/strict");
const { test } = require("node:test");
const { createHarness } = require("./desktop-ui-test-support.cjs");

function runtime() {
  const ui = createHarness([
    "pages-common.js",
    "pages-form-draft.js",
    "pages-settings-models.js",
    "pages-workbench-controls.js",
    "pages-workbench-conversation.js",
    "pages-workbench-conversation-incremental.js"
  ], ["workbench-inspector-footer"]);
  const footer = ui.roots[0], commands = [], requests = [];
  return {
    window: ui.window, document: ui.document, footer, commands, requests, conversation: ui.window.CodexBridgeDesktopWorkbenchConversation,
    settingsModels: ui.window.CodexBridgeDesktopSettingsModels,
    render: page => ui.window.CodexBridgeDesktopWorkbenchControls.render(page, (command, payload, requestID) => {
      commands.push({ command, payload: JSON.parse(JSON.stringify(payload)) });
      requests.push(requestID);
    }),
    input: () => ui.document.getElementById("workbench-task-input"),
    button: title => ui.find(footer, node => node.tagName === "button" && node.textContent === title),
    buttonIn: (root, title) => ui.find(root, node => node.tagName === "button" && node.textContent === title)
  };
}

function page(taskID, extra = {}) {
  return {
    selectedTaskID: taskID,
    selectedTask: { taskID, sessionID: taskID, canSteer: !extra.canResume, ...extra },
    tasks: [{ taskID, sessionID: taskID, canSteer: !extra.canResume }],
    steerModes: [{ id: "queued", title: "当前轮结束后继续" }],
    engineStatus: "运行中"
  };
}

function type(input, text) { input.value = text; input.dispatch("input"); }

function settingsPage(extra = {}) {
  return {
    models: [{ modelID: "gpt-5.6", displayName: "GPT", reasoningEfforts: [{ id: "medium", title: "中" }] }],
    executionModel: "gpt-5.6", executionEffort: "medium",
    supervisorModel: "gpt-5.6", supervisorEffort: "medium",
    effortOptions: [{ id: "medium", title: "中" }],
    supervisorEffortOptions: [{ id: "medium", title: "中" }],
    accessMode: "request-approval", accessOptions: [{ id: "request-approval", title: "请求批准" }],
    fastModeEnabled: false, canSavePreferences: true, canRefreshModels: true,
    ...extra
  };
}

test("stream snapshots preserve input identity, focus and selection", () => {
  const ui = runtime();
  ui.render(page("task-a"));
  const input = ui.input();
  type(input, "继续检查共享模块");
  input.focus();
  input.setSelectionRange(2, 5, "forward");
  ui.render({ ...page("task-a"), engineStatus: "正在读取文件" });
  assert.equal(ui.input(), input);
  assert.equal(ui.document.activeElement, input);
  assert.equal(input.value, "继续检查共享模块");
  assert.equal(input.selectionStart, 2);
  assert.equal(input.selectionEnd, 5);
});

test("workbench footer refreshes only the current conversation", () => {
  const ui = runtime();
  const state = { ...page("task-a"), modelCount: 4, canRefreshModels: true };
  ui.render(state);
  assert.equal(ui.button("获取模型"), null);
  assert.equal(ui.button("刷新模型"), null);
  assert.equal(ui.button("获取中…"), null);
  assert.equal(ui.footer.querySelector(".footer-status-text").textContent, "运行中");
  ui.button("刷新").dispatch("click");
  assert.deepEqual(ui.commands, [
    { command: "refreshConversation", payload: { taskID: "task-a" } }
  ]);
  assert.equal(ui.commands.some(command => command.command === "refreshModels"), false);
});

test("workbench footer disables refresh without a selected task", () => {
  const ui = runtime();
  ui.render(null);
  assert.equal(ui.button("刷新").disabled, true);
});

test("settings model card refreshes the shared catalog", () => {
  const ui = runtime(), commands = [];
  const editor = ui.settingsModels.preferences(settingsPage(), (command, payload) => {
    commands.push({ command, payload: JSON.parse(JSON.stringify(payload)) });
  });
  assert.ok(ui.buttonIn(editor.root, "刷新模型"));
  ui.buttonIn(editor.root, "刷新模型").dispatch("click");
  assert.deepEqual(commands, [{ command: "refreshModels", payload: {} }]);
  editor.update(settingsPage({ modelCount: 0, models: [], isRefreshingModels: true }), () => {});
  assert.ok(ui.buttonIn(editor.root, "获取中…").disabled);
  assert.match(editor.root.querySelector(".model-refresh-status").textContent, /正在获取/);
});

test("task drafts remain isolated and survive returning to a task", () => {
  const ui = runtime();
  ui.render(page("task-a"));
  type(ui.input(), "任务 A 指令");
  ui.render(page("task-b"));
  assert.equal(ui.input().value, "");
  type(ui.input(), "任务 B 指令");
  ui.render(page("task-a"));
  assert.equal(ui.input().value, "任务 A 指令");
});

test("capability changes retain the current task input and selection", () => {
  const ui = runtime();
  ui.render(page("task-a"));
  type(ui.input(), "纠偏指令");
  ui.input().focus();
  ui.input().setSelectionRange(1, 3, "backward");
  const next = page("task-a");
  next.steerModes.push({ id: "interrupt-current-then-continue", title: "立即纠偏当前轮" });
  ui.render(next);
  assert.equal(ui.input().value, "纠偏指令");
  assert.equal(ui.document.activeElement, ui.input());
  assert.equal(ui.input().selectionStart, 1);
  assert.equal(ui.input().selectionEnd, 3);
});

test("steer keeps the draft until the task acknowledges it", () => {
  const ui = runtime();
  const state = page("task-a");
  state.steerModes.push({ id: "interrupt-current-then-continue", title: "立即纠偏当前轮" });
  ui.render(state);
  type(ui.input(), "新的方向");
  const mode = ui.document.getElementById("workbench-steer-mode");
  mode.value = "interrupt-current-then-continue"; mode.dispatch("change");
  ui.button("发送指令").dispatch("click");
  assert.deepEqual(ui.commands, [{ command: "steerTask", payload: {
    taskID: "task-a", input: "新的方向", mode: "interrupt-current-then-continue"
  } }]);
  assert.equal(ui.input().value, "新的方向");
  ui.render({ ...state, selectedTask: { ...state.selectedTask, status: "running", updatedAt: "2" } });
  assert.equal(ui.input().value, "新的方向");
  assert.equal(ui.button("发送指令").disabled, true);
  ui.render({ ...state, commandReceipt: {
    receiptID: "receipt-steer-1", requestID: ui.requests[0], command: "steerTask",
    taskID: "task-a", input: "新的方向", accepted: true
  } });
  ui.render(page("task-b")); ui.render(state);
  assert.equal(ui.input().value, "");
});

test("retry preserves its draft across snapshots and resumes the selected task", () => {
  const ui = runtime();
  const state = page("task-a", { canResume: true, canRestart: true });
  ui.render(state);
  const input = ui.input();
  type(input, "请继续上次检查");
  ui.render(state);
  assert.equal(ui.input(), input);
  ui.button("发送").dispatch("click");
  assert.deepEqual(ui.commands, [{ command: "resumeTask", payload: { taskID: "task-a", input: "请继续上次检查" } }]);
  assert.equal(input.value, "请继续上次检查");
  assert.equal(ui.button("发送").disabled, true);
  ui.render({ ...state, commandReceipt: {
    receiptID: "receipt-resume-fail", requestID: ui.requests[0], command: "resumeTask",
    taskID: "task-a", input: "请继续上次检查", accepted: false
  } });
  assert.equal(ui.input().value, "请继续上次检查");
  assert.equal(ui.button("发送").disabled, false);
  ui.render({ ...state, selectedTask: { ...state.selectedTask, canResume: false, canRestart: false, canSteer: false, status: "running", turnCount: 2 }, steerModes: [] });
  ui.render({ history: { selectedThreadID: "history-a" }, tasks: [] });
  assert.equal(ui.input(), null);
});

test("a stale receipt cannot acknowledge a later identical submission", () => {
  const ui = runtime();
  const state = page("task-a");
  ui.render(state);
  type(ui.input(), "重复方向");
  ui.button("发送指令").dispatch("click");
  const firstRequestID = ui.requests[0];
  ui.render({ ...state, commandReceipt: {
    receiptID: "receipt-first-failure", requestID: firstRequestID, command: "steerTask",
    taskID: "task-a", input: "重复方向", accepted: false
  } });
  ui.button("发送指令").dispatch("click");
  const secondRequestID = ui.requests[1];
  assert.notEqual(firstRequestID, secondRequestID);
  ui.render({ ...state, commandReceipt: {
    receiptID: "receipt-old-success", requestID: firstRequestID, command: "steerTask",
    taskID: "task-a", input: "重复方向", accepted: true
  } });
  assert.equal(ui.input().value, "重复方向");
  assert.equal(ui.button("发送指令").disabled, true);
  ui.render({ ...state, commandReceipt: {
    receiptID: "receipt-second-success", requestID: secondRequestID, command: "steerTask",
    taskID: "task-a", input: "重复方向", accepted: true
  } });
  assert.equal(ui.input().value, "");
});

test("session fallback keeps provider scope when session IDs collide", () => {
  const ui = runtime();
  const state = {
    selectedProjectID: "project-a",
    selectedTask: {
      taskID: "task-opencode",
      sessionID: "shared-session",
      providerID: "opencode",
      canResume: true,
      canRestart: true
    },
    tasks: [
      {
        taskID: "task-antigravity",
        sessionID: "shared-session",
        projectID: "project-a",
        providerID: "antigravity",
        canSteer: true
      },
      {
        taskID: "task-opencode",
        sessionID: "shared-session",
        projectID: "project-a",
        providerID: "opencode",
        canSteer: false
      }
    ],
    steerModes: [{ id: "queued", title: "当前轮结束后继续" }],
    engineStatus: "已结束"
  };
  ui.render(state);
  assert.ok(ui.button("发送"));
  assert.equal(ui.button("发送指令"), null);
});

test("conversation refresh preserves reading position and follows the bottom only when requested", () => {
  const ui = runtime(), content = { scrollTop: 0, scrollHeight: 900, clientHeight: 300 };
  ui.conversation.captureViewport(content, page("a"))();
  content.scrollTop = 100;
  let restore = ui.conversation.captureViewport(content, page("a"));
  content.scrollTop = 0; content.scrollHeight = 1100;
  restore();
  assert.equal(content.scrollTop, 100);
  content.scrollTop = 800;
  restore = ui.conversation.captureViewport(content, page("a"));
  content.scrollHeight = 1400; restore();
  assert.equal(content.scrollTop, 1400);
});

test("conversation follows delayed content growth until the reader scrolls up", () => {
  const ui = runtime();
  let resized;
  ui.window.ResizeObserver = class {
    constructor(callback) { resized = callback; }
    observe() {}
    disconnect() {}
  };
  const content = ui.document.createElement("section");
  content.scrollTop = 0; content.scrollHeight = 900; content.clientHeight = 300;
  content.appendChild(ui.document.createElement("article"));
  ui.conversation.captureViewport(content, page("a"))();
  content.scrollTop = 600; content.dispatch("scroll");
  content.scrollHeight = 1200; resized();
  assert.equal(content.scrollTop, 1200);
  content.scrollTop = 200; content.dispatch("scroll");
  content.scrollHeight = 1500; resized();
  assert.equal(content.scrollTop, 200);
  content.scrollTop = 1200; content.dispatch("scroll");
  content.scrollHeight = 1800; resized();
  assert.equal(content.scrollTop, 1800);
});

test("Windows conversation rendering reuses keyed entries across snapshots", () => {
  const ui = runtime();
  ui.document.documentElement = { dataset: { platform: "windows" } };
  const owner = ui.document.createElement("section");
  const state = page("task-a");
  const firstEntry = { id: "entry-1", role: "用户", text: "第一条", isFinal: true };
  const secondEntry = { id: "entry-2", role: "助手", text: "第二条", isFinal: true };
  const firstCard = ui.document.createElement("div");
  ui.conversation.render(firstCard, [firstEntry], state, () => {}, { owner });
  const firstNode = firstCard.querySelector(".conversation-entry");
  const firstText = firstNode.querySelector(".entry-text");

  const secondCard = ui.document.createElement("div");
  ui.conversation.render(secondCard, [firstEntry, secondEntry], state, () => {}, { owner });
  const entries = secondCard.querySelectorAll(".conversation-entry");
  assert.equal(entries.length, 2);
  assert.equal(entries[0], firstNode);
  assert.equal(entries[0].querySelector(".entry-text"), firstText);

  const thirdCard = ui.document.createElement("div");
  ui.conversation.render(thirdCard, [{ ...firstEntry, text: "更新后的第一条" }, secondEntry], state, () => {}, { owner });
  assert.equal(thirdCard.querySelector(".conversation-entry"), firstNode);
  assert.equal(firstNode.querySelector(".entry-text").textContent, "更新后的第一条");

  const tool = { id: "tool-1", kind: "tool_call", toolName: "读取文件", text: "输出", isFinal: false };
  const toolCard = ui.document.createElement("div");
  ui.conversation.render(toolCard, [tool], state, () => {}, { owner });
  const toolNode = toolCard.querySelector(".conversation-entry");
  toolNode.open = true;
  toolNode.dispatch("toggle");
  const updatedToolCard = ui.document.createElement("div");
  ui.conversation.render(updatedToolCard, [{ ...tool, toolStatus: "completed", isFinal: true }], state, () => {}, { owner });
  assert.equal(updatedToolCard.querySelector(".conversation-entry"), toolNode);
  assert.equal(toolNode.open, true);
});

test("manual disclosure choices survive streaming and stay scoped to their session", () => {
  const ui = runtime(), entry = { id: "reasoning-1", kind: "reasoning", isFinal: false, text: "" };
  function disclosure(state, value) {
    const content = ui.document.createElement("section");
    ui.conversation.render(content, [value], state, () => {});
    return content.querySelector("details");
  }
  const original = disclosure(page("a"), entry);
  assert.equal(original.open, false);
  original.open = false; original.dispatch("toggle");
  assert.equal(disclosure(page("a"), entry).open, false);
  assert.equal(disclosure(page("b"), entry).open, false);
  const completed = disclosure(page("a"), { ...entry, isFinal: true });
  completed.open = true; completed.dispatch("toggle");
  assert.equal(disclosure(page("a"), { ...entry, isFinal: true }).open, true);
});

test("Windows streaming keeps the conversation card attached to its parent", () => {
  const ui = createHarness([
    "pages-common.js", "pages-workbench-conversation.js",
    "pages-workbench-conversation-incremental.js"
  ], ["workbench-inspector-content", "workbench-inspector-approvals"]);
  ui.document.documentElement = { dataset: { platform: "windows" } };
  ui.window.addEventListener = () => {};
  ui.window.CodexBridgeDesktopWorkbenchHeader = { render() {} };
  ui.window.CodexBridgeDesktopWorkbenchControls = { render() {} };
  ui.load("pages-workbench.js");
  const content = ui.roots[0];
  const state = page("task-a", {
    title: "Task", projectName: "Project", provider: "Codex", status: "运行中",
    conversation: [{ id: "entry-1", role: "助手", text: "First", isFinal: false }]
  });
  const render = () => ui.window.CodexBridgeDesktopWorkbenchPage.render(state, () => {});
  render();
  const card = content.querySelector(".task-detail-card");
  const header = card.querySelector(".task-detail-header");
  const conversation = card.querySelector(".task-conversation-container");
  const entry = card.querySelector(".conversation-entry");
  assert.ok(header);
  assert.ok(conversation);
  assert.equal(card.children[0], header);
  assert.equal(card.children[1], conversation);
  assert.equal(header.querySelector(".detail-title").textContent, "Task");
  assert.equal(conversation.querySelector(".conversation-entry"), entry);
  let cardRemovals = 0;
  const removeChild = content.removeChild.bind(content);
  content.removeChild = child => {
    if (child === card) cardRemovals++;
    return removeChild(child);
  };
  state.selectedTask.conversation = [{ ...state.selectedTask.conversation[0], text: "First and second" }];
  render();
  assert.equal(content.querySelector(".task-detail-card"), card);
  assert.equal(card.querySelector(".conversation-entry"), entry);
  assert.equal(card.children[0], header);
  assert.equal(card.children[1], conversation);
  assert.equal(header.querySelector(".detail-title").textContent, "Task");
  assert.equal(conversation.querySelector(".conversation-entry"), entry);
  assert.equal(cardRemovals, 0);
  assert.equal(entry.querySelector(".entry-text").textContent, "First and second");
});
