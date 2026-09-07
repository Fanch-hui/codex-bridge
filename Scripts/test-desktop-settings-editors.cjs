const assert = require("node:assert/strict");
const { test } = require("node:test");
const { createHarness } = require("./desktop-ui-test-support.cjs");

function runtime() {
  const ui = createHarness([
    "pages-common.js", "pages-form-draft.js", "pages-native-permissions.js",
    "pages-settings-models.js", "pages-settings-agents.js", "pages-settings-instructions.js",
    "pages-settings-native.js", "pages-settings.js"
  ], ["settings-content"]);
  const commands = [];
  const emit = (command, payload) => commands.push({ command, payload: JSON.parse(JSON.stringify(payload)) });
  const root = ui.roots[0];
  return { ...ui, root, commands,
    render: (page, nextEmit = emit) => ui.window.CodexBridgeDesktopSettingsPage.render(page, nextEmit),
    section: title => ui.find(root, node => node.className.split(" ").includes("settings-card") && ui.find(node, child => child.tagName === "h3" && child.textContent === title)),
    button: (title, scope = root) => ui.find(scope, node => node.tagName === "button" && node.textContent === title)
  };
}
const effort = [{ id: "medium", title: "中" }, { id: "high", title: "高" }];
function page(extra = {}) {
  return {
    header: { title: "设置", subtitle: "Service", symbol: "gearshape" },
    models: [
      { modelID: "fast", displayName: "Fast", supportsFastMode: true, reasoningEfforts: effort },
      { modelID: "standard", displayName: "Standard", supportsFastMode: false, reasoningEfforts: [effort[0]] }
    ],
    executionModel: "fast", executionEffort: "medium", effortOptions: effort,
    accessMode: "workspace-write", accessOptions: [{ id: "workspace-write", title: "写入" }],
    fastModeEnabled: true, supervisorAvailable: true, supervisorModel: "fast", supervisorEffort: "medium",
    supervisorEffortOptions: effort, supervisorEnabled: false, canSavePreferences: true,
    canSaveInstructions: true, customInstructions: "原始指令", agentDefaults: [],
    directApprovalOptions: [], taskStartApprovalOptions: [],
    servicePlatform: "Windows", serviceDescription: "Service", canChangeService: false,
    ...extra
  };
}
function type(control, value) { control.value = value; control.dispatch("input"); }

test("settings snapshots retain the composing textarea, focus and draft", () => {
  const ui = runtime(); ui.render(page());
  const text = ui.root.querySelector("textarea");
  text.focus(); text.setSelectionRange(2, 4, "forward");
  text.dispatch("compositionstart"); type(text, "正在输入中文");
  ui.render(page({ customInstructions: "外部更新", canSaveInstructions: false }));
  assert.equal(ui.root.querySelector("textarea"), text);
  assert.equal(ui.document.activeElement, text);
  assert.equal(text.value, "正在输入中文");
  assert.equal(text.selectionStart, 2);
  assert.equal(ui.button("保存指令").disabled, true);
  text.dispatch("compositionend");
  ui.render(page({ customInstructions: "外部更新", canSaveInstructions: true }));
  assert.equal(text.value, "正在输入中文");
  ui.button("保存指令").dispatch("click");
  assert.equal(ui.commands[0].payload.value, "正在输入中文");
});

test("failed saves preserve drafts; saved and untouched values follow Service", () => {
  const ui = runtime(); ui.render(page());
  const text = ui.root.querySelector("textarea");
  type(text, "待保存"); ui.button("保存指令").dispatch("click");
  ui.render(page({ statusMessage: "保存失败" }));
  assert.equal(text.value, "待保存");
  ui.render(page({ customInstructions: "待保存" }));
  ui.render(page({ customInstructions: "外部新值" }));
  assert.equal(text.value, "外部新值");
  type(text, "第二次"); ui.button("保存指令").dispatch("click"); type(text, "第三次草稿");
  ui.render(page({ customInstructions: "第二次" }));
  assert.equal(text.value, "第三次草稿");
});

test("model drafts persist and Fast capability follows the chosen model", () => {
  const ui = runtime(); ui.render(page());
  const card = ui.section("模型与执行默认偏好");
  const controls = card.querySelectorAll("select");
  const fast = card.querySelector("input");
  controls[0].value = "standard"; controls[0].dispatch("change");
  assert.equal(fast.checked, false); assert.equal(fast.disabled, true);
  ui.render(page());
  assert.equal(card.querySelectorAll("select")[0], controls[0]);
  assert.equal(controls[0].value, "standard");
  ui.button("保存模型偏好").dispatch("click");
  assert.deepEqual(ui.commands[0].payload, { executionModel: "standard", executionEffort: "medium", accessMode: "workspace-write", fastModeEnabled: false });
  controls[0].value = "fast"; controls[0].dispatch("change");
  assert.equal(fast.disabled, false);
});

test("Supervisor and Agent editors retain drafts while updating capabilities and callbacks", () => {
  const ui = runtime();
  const agent = { providerID: "opencode", installationID: "install-a", providerName: "OpenCode", model: "one", effort: "medium", permissionMode: "build", modelOptions: [{ modelID: "one", displayName: "One", reasoningEfforts: effort }], effortOptions: effort, permissionOptions: [{ id: "build", title: "Build" }, { id: "plan", title: "Plan" }], canSave: true, canRefreshModels: true };
  ui.render(page({ agentDefaults: [agent] }));
  const supervisor = ui.section("Supervisor 监督");
  const toggle = supervisor.querySelector("input"); toggle.checked = true;
  const agents = ui.section("外部 Agent 默认偏好");
  const permission = agents.querySelectorAll("select")[2]; permission.value = "plan";
  const received = [];
  ui.render(page({ canSavePreferences: false, agentDefaults: [{ ...agent, canSave: false }] }));
  assert.equal(toggle.checked, true); assert.equal(ui.button("保存 Supervisor").disabled, true);
  ui.render(page({ agentDefaults: [agent] }), (command, payload) => received.push({ command, payload }));
  ui.button("保存 Agent 默认").dispatch("click");
  assert.equal(permission.value, "plan");
  assert.equal(received[0].payload.permissionMode, "plan");
  assert.equal(received[0].payload.installationID, "install-a");
});

test("native rule text stays composing through loading and saving snapshots", () => {
  const ui = runtime();
  const policy = { installationID: "agy-a", installationName: "AGY", toolPermission: "default", availableModes: [], availableActions: ["command"], canEdit: true, rules: [] };
  ui.render(page({ nativePermissionPolicy: policy }));
  const native = ui.section("AGY CLI Global 工具权限");
  const target = native.querySelector("input");
  target.dispatch("compositionstart"); type(target, "swift test 中文"); target.focus();
  ui.render(page({ nativePermissionPolicy: { ...policy, isSaving: true, canEdit: false } }));
  assert.equal(native.querySelector("input"), target);
  assert.equal(target.value, "swift test 中文");
  assert.equal(ui.document.activeElement, target);
  assert.equal(ui.button("添加规则").disabled, true);
  target.dispatch("compositionend");
  ui.render(page({ nativePermissionPolicy: policy }));
  ui.button("添加规则").dispatch("click");
  assert.equal(ui.commands[0].payload.target, "swift test 中文");
});
