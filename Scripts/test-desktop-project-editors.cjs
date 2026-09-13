const assert = require("node:assert/strict");
const { test } = require("node:test");
const { createHarness } = require("./desktop-ui-test-support.cjs");

function runtime() {
  const ui = createHarness([
    "pages-common.js", "pages-form-draft.js", "pages-project-editors.js",
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

function page(projectID = "a") {
  return {
    header: { title: "项目", subtitle: "本地项目", symbol: "folder.fill" },
    selectedProjectID: projectID, selectedProjectDetail: "已连接", canRegister: true, canRemove: true, canSavePolicy: true,
    rows: ["a", "b"].map(id => ({ projectID: id, name: "项目" + id, selected: id === projectID,
      readPermission: "allowed", writePermission: "allowed", networkPermission: "denied" })),
    policyOptions: [{ id: "allowed", title: "允许" }, { id: "denied", title: "拒绝" }],

  };
}

function type(input, value) { input.value = value; input.dispatch("input"); }

test("project policy drafts survive refreshes while save permissions change", () => {
  const ui = runtime(), state = page(); ui.render(state);
  const policy = ui.field("writePermission"); policy.value = "denied"; policy.dispatch("change");
  state.canSavePolicy = false; ui.render(state);
  assert.equal(ui.field("writePermission"), policy);
  assert.equal(policy.value, "denied");
  assert.equal(ui.button("保存权限").disabled, true);
  state.canSavePolicy = true; ui.render(state);
  ui.button("保存权限").dispatch("click");
  assert.equal(ui.commands[0].payload.writePermission, "denied");
});
