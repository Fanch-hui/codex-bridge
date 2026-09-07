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

test("approval and service cards preserve DOM and honor save controls", () => {
  const ui = runtime();
  const options = [{ id: "require", title: "每次询问" }, { id: "auto", title: "自动" }];
  const state = page({
    directApprovalMode: "require", directApprovalOptions: options,
    taskStartApprovalMode: "require", taskStartApprovalOptions: options,
    canSaveApprovalModes: true, canChangeService: true, serviceRegistered: false,
    keepServiceRunningAfterExit: false
  });
  ui.render(state);
  const approvals = ui.section("安全审批策略");
  const direct = approvals.querySelector("select");
  direct.focus();
  const service = ui.section("后台服务");
  const keep = service.querySelector("input");
  keep.checked = true;
  ui.render({ ...state, canSaveApprovalModes: false, serviceRegistered: true });
  assert.equal(ui.section("安全审批策略"), approvals);
  assert.equal(approvals.querySelector("select"), direct);
  assert.equal(direct.disabled, true);
  assert.equal(ui.section("后台服务"), service);
  assert.equal(keep.checked, true);
  ui.button("注销后台服务", service).dispatch("click");
  assert.equal(ui.commands.at(-1).command, "unregisterService");
});

test("agent permission defaults remain editable without an installation", () => {
  const ui = runtime();
  const agent = {
    providerID: "antigravity", installationID: null, providerName: "Antigravity",
    model: null, effort: null, permissionMode: "workspace-write", modelOptions: [],
    effortOptions: [{ id: "", title: "Provider 默认" }],
    permissionOptions: [{ id: "workspace-write", title: "工作区可写" }],
    canSave: true, canRefreshModels: false
  };
  ui.render(page({ agentDefaults: [agent] }));
  const card = ui.section("外部 Agent 默认偏好");
  assert.equal(card.querySelector(".hint").textContent.includes("尚未登记可用安装"), true);
  assert.equal(ui.button("保存 Agent 默认", card).disabled, false);
  ui.button("保存 Agent 默认", card).dispatch("click");
  assert.equal(ui.commands.at(-1).payload.installationID, null);
});

test("agent permission selector follows installation capabilities", () => {
  const ui = runtime();
  const agent = {
    providerID: "antigravity", installationID: "install-a", installationName: "AGY",
    providerName: "Antigravity", model: null, effort: null, permissionMode: "plan",
    modelOptions: [], effortOptions: [{ id: "", title: "Provider 默认" }],
    permissionOptions: [{ id: "workspace-write", title: "工作区可写" }, { id: "plan", title: "只读" }],
    supportsWorkspaceWrite: false, canSave: true, canRefreshModels: false
  };
  ui.render(page({ agentDefaults: [agent] }));
  const card = ui.section("外部 Agent 默认偏好");
  assert.equal(card.querySelectorAll("select")[2].disabled, true);
  assert.equal(card.querySelectorAll(".hint").some(item => item.textContent.includes("有效能力")), true);
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
