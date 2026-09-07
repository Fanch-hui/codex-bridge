const assert = require("node:assert/strict");
const { test } = require("node:test");
const { createHarness } = require("./desktop-ui-test-support.cjs");

function runtime() {
  const ui = createHarness([
    "pages-common.js", "pages-form-draft.js", "pages-project-editors.js", "pages-project-workspace.js",
    "pages-project-collections.js", "pages-projects.js"
  ], ["projects-content"]);
  const root = ui.roots[0], commands = [];
  function visible(node) { return !node.hidden && (!node.parentNode || visible(node.parentNode)); }
  return {
    ...ui, commands,
    render: page => ui.window.CodexBridgeDesktopProjectsPage.render(page, (command, payload) => {
      commands.push({ command, payload: JSON.parse(JSON.stringify(payload)) });
    }),
    field: name => ui.find(root, node => node.dataset.field === name && visible(node)),
    button: title => ui.find(root, node => node.tagName === "button" && node.textContent === title && visible(node)),
    row: title => ui.find(root, node => node.tagName === "button" && visible(node)
      && ui.find(node, child => child.textContent === title))
  };
}

function command(id, name) {
  return { commandID: id, name, executable: "swift", arguments: ["test"], workingDirectory: null, risk: "normal", requiresNetwork: false };
}

function page(projectID = "a") {
  return {
    header: { title: "项目", subtitle: "本地项目", symbol: "folder.fill" },
    selectedProjectID: projectID, selectedProjectDetail: "已连接", canRegister: true, canRemove: true, canSavePolicy: true,
    rows: ["a", "b"].map(id => ({ projectID: id, name: "项目" + id, selected: id === projectID,
      readPermission: "allowed", writePermission: "allowed", networkPermission: "denied" })),
    policyOptions: [{ id: "allowed", title: "允许" }, { id: "denied", title: "拒绝" }],
    workspace: { commandMode: "safe", commandModeOptions: [{ id: "safe", title: "安全" }, { id: "full", title: "完全" }],
      commands: [command("one", "测试命令"), command("two", "构建命令")],
      blacklist: [{ ruleID: "rule-one", executable: "git", pattern: "reset" }],
      canSaveMode: true, canSaveCommand: true, canRemoveCommand: true, canSaveBlacklist: true, canRemoveBlacklist: true }
  };
}

function type(input, value) { input.value = value; input.dispatch("input"); }

test("project command controls retain DOM, focus and IME text while snapshot capabilities update", () => {
  const ui = runtime(), state = page(); ui.render(state);
  const input = ui.field("name"); input.focus(); input.dispatch("compositionstart");
  type(input, "正在输入命令名"); input.setSelectionRange(2, 5, "forward");
  state.workspace.canSaveCommand = false; state.workspace.canRemoveCommand = false;
  state.workspace.commands[0].name = "服务端更新名称";
  ui.render(state);
  assert.equal(ui.field("name"), input); assert.equal(ui.document.activeElement, input);
  assert.equal(input.value, "正在输入命令名"); assert.equal(input.selectionStart, 2);
  assert.equal(ui.button("保存命令").disabled, true); assert.equal(ui.button("删除命令").disabled, true);
  assert.ok(ui.row("服务端更新名称"));
  input.dispatch("compositionend"); assert.equal(input.value, "正在输入命令名");
});

test("failed saves retain drafts and acknowledged saves allow later server updates", () => {
  const ui = runtime(), state = page(); ui.render(state);
  const input = ui.field("name"); type(input, "修改后的名称"); ui.button("保存命令").dispatch("click");
  ui.render(state); assert.equal(input.value, "修改后的名称");
  state.workspace.commands[0].name = "修改后的名称"; ui.render(state);
  state.workspace.commands[0].name = "后续服务端名称"; ui.render(state);
  assert.equal(input.value, "后续服务端名称");
  assert.equal(ui.commands[0].payload.commandID, "one");
});

test("project and command selections isolate drafts and preserve their original controls", () => {
  const ui = runtime(); ui.render(page("a"));
  const first = ui.field("name"); type(first, "项目A第一条");
  ui.row("构建命令").dispatch("click"); const second = ui.field("name"); type(second, "项目A第二条");
  ui.render(page("b")); assert.equal(ui.field("name").value, "测试命令"); type(ui.field("name"), "项目B独立草稿");
  ui.render(page("a")); assert.equal(ui.field("name"), second); assert.equal(second.value, "项目A第二条");
  ui.row("测试命令").dispatch("click"); assert.equal(ui.field("name"), first); assert.equal(first.value, "项目A第一条");
});

test("new command acknowledgement binds the existing editor to its persisted ID", () => {
  const ui = runtime(), state = page(); ui.render(state); ui.button("新建命令").dispatch("click");
  const input = ui.field("name"); type(input, "新命令"); type(ui.field("executable"), "swift"); type(ui.field("arguments"), "build");
  ui.button("保存命令").dispatch("click"); assert.equal(ui.commands[0].payload.commandID, null);
  const persisted = { ...ui.commands[0].payload, commandID: "created" }; state.workspace.commands.push(persisted);
  ui.render(state); assert.equal(ui.field("name"), input);
  type(input, "新命令修改"); ui.button("保存命令").dispatch("click");
  assert.equal(ui.commands[1].payload.commandID, "created");
  ui.button("新建命令").dispatch("click"); assert.equal(ui.field("name").value, "");
});

test("policy and blacklist drafts survive refreshes while their save permissions change", () => {
  const ui = runtime(), state = page(); ui.render(state);
  const policy = ui.field("writePermission"); policy.value = "denied"; policy.dispatch("change");
  ui.row("git").dispatch("click");
  const pattern = ui.field("pattern"); type(pattern, "force");
  state.canSavePolicy = false; state.workspace.canSaveBlacklist = false; ui.render(state);
  assert.equal(ui.field("writePermission"), policy); assert.equal(policy.value, "denied");
  assert.equal(ui.field("pattern"), pattern); assert.equal(pattern.value, "force");
  assert.equal(ui.button("保存权限").disabled, true); assert.equal(ui.button("保存规则").disabled, true);
  state.canSavePolicy = true; state.workspace.canSaveBlacklist = true; ui.render(state);
  ui.button("保存权限").dispatch("click"); ui.button("保存规则").dispatch("click");
  assert.equal(ui.commands[0].payload.writePermission, "denied");
  assert.deepEqual(ui.commands[1].payload, { projectID: "a", ruleID: "rule-one", executable: "git", pattern: "force" });
});
