const assert = require('node:assert/strict');
const { test } = require('node:test');
const { createHarness } = require('./desktop-ui-test-support.cjs');

test('Qoder permission choices save the selected regional installation through the existing command', () => {
  const ui = createHarness(['pages-common.js', 'pages-settings-qoder-permissions.js'], ['root']);
  const editor = ui.window.CodexBridgeDesktopSettingsQoderPermissions.create();
  ui.roots[0].appendChild(editor.root);
  const commands = [];
  const policy = { providerID: 'qoder', installationID: 'cn', installationName: 'Qoder CN',
    toolPermission: 'default', canEdit: true, installations: [{ id: 'cn', title: 'Qoder CN' }],
    availableModes: ['default', 'auto', 'bypass_permissions'].map(modeID => ({
      modeID, displayName: modeID, requiresConfirmation: modeID !== 'default'
    })) };
  editor.update({ nativePermissionPolicy: policy }, (command, payload) => commands.push({ command, payload }));
  const select = editor.root.querySelector('select');
  assert.equal(select.children.length, 3);
  select.value = 'auto'; select.dispatch('change');
  assert.equal(commands[0].command, 'setAgentNativePermissionMode');
  assert.equal(commands[0].payload.installationID, 'cn');
  assert.equal(commands[0].payload.toolPermission, 'auto');
  assert.equal(commands[0].payload.confirmed, true);
  ui.window.confirm = () => false;
  select.value = 'bypass_permissions'; select.dispatch('change');
  assert.equal(commands.length, 1);
  assert.equal(select.value, 'default');
});
