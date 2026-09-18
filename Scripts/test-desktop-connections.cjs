const assert = require("node:assert/strict");
const { test } = require("node:test");
const { createHarness } = require("./desktop-ui-test-support.cjs");

function runtime() {
  const ui = createHarness([
    "pages-common.js", "pages-form-draft.js", "pages-agent-connector-details.js",
    "pages-agent-headless-consent.js", "pages-agent-connector-row.js", "pages-agent-connectors.js",
    "pages-codex-connection.js", "pages-connections-editor.js",
    "pages-deepseek-harness-mcp-editor.js", "pages-deepseek-harness-mcp.js", "pages-connections.js"
  ], ["connections-content"]);
  const root = ui.roots[0], commands = [];
  const emit = (command, payload) => commands.push({
    command,
    payload: JSON.parse(JSON.stringify(payload))
  });
  return {
    ...ui,
    root,
    commands,
    render: (state, nextEmit = emit) => ui.window.CodexBridgeDesktopConnectionsPage.render(state, nextEmit),
    button: title => ui.find(root, node => node.tagName === "button" && node.textContent === title),
    input: placeholder => ui.find(root, node => node.tagName === "input" && node.placeholder === placeholder)
  };
}

function page(extra = {}) {
  const tunnel = {
    configured: false,
    enabled: false,
    helperAvailable: true,
    tunnelID: "server-id",
    lifecycle: "stopped",
    acceptsRemoteSubmissions: false,
    actionRequired: false,
    canConfigure: true,
    canConnect: false,
    canDisconnect: false,
    canClear: false,
    ...(extra.tunnel || {})
  };
  return {
    header: { title: "连接", subtitle: "本地连接", symbol: "point.3.connected.trianglepath.dotted" },
    summaryRows: [],
    localMCPURL: "http://127.0.0.1:1234/mcp",
    localMCPState: "ready",
    canCopyLocalMCPURL: true,
    canRotateLocalMCPEndpoint: true,
    tunnel,
    clients: [{
      clientID: "qwen.studio",
      displayName: "Qwen Studio",
      enabled: false,
      exposureMode: "read-only",
      exposureOptions: [{ id: "read-only", title: "只读" }, { id: "full", title: "完整" }],
      activeSessionCount: 0,
      lastConnectedAt: null,
      canToggle: true,
      canCopyConfiguration: true,
      canRotateCredential: true
    }],
    providers: [{ providerID: "opencode", displayName: "OpenCode", requiresConfiguration: false, detail: "" }],
    installations: [],
    deepSeekHarnessMCPServers: [],
    canManageDeepSeekHarnessMCP: false,
    canRegisterAgent: true,
    statusMessage: null,
    ...extra,
    tunnel
  };
}

function type(control, value) {
  control.value = value;
  control.dispatch("input");
}

function client(root, id) {
  return root.querySelectorAll(".client-row").find(row => row.dataset.clientID === id);
}

test("tunnel drafts retain identity, focus and IME text while capabilities change", () => {
  const ui = runtime();
  ui.render(page());
  const tunnelID = ui.input("输入 Tunnel ID");
  const runtimeKey = ui.input("不会写入 UI 状态");
  tunnelID.focus();
  tunnelID.setSelectionRange(2, 6, "forward");
  tunnelID.dispatch("compositionstart");
  type(tunnelID, "正在输入 Tunnel");
  type(runtimeKey, "runtime-key-test");

  ui.render(page({ tunnel: { tunnelID: "server-updated", canConfigure: false } }));
  assert.equal(ui.input("输入 Tunnel ID"), tunnelID);
  assert.equal(ui.document.activeElement, tunnelID);
  assert.equal(tunnelID.value, "正在输入 Tunnel");
  assert.equal(tunnelID.selectionStart, 2);
  assert.equal(tunnelID.selectionEnd, 6);
  assert.equal(ui.input("不会写入 UI 状态"), runtimeKey);
  assert.equal(runtimeKey.value, "runtime-key-test");
  assert.equal(ui.button("保存并启动连接").disabled, true);

  tunnelID.dispatch("compositionend");
  ui.render(page({ tunnel: { tunnelID: "server-updated", canConfigure: true } }));
  ui.button("保存并启动连接").dispatch("click");
  assert.deepEqual(ui.commands[0], {
    command: "configureTunnel",
    payload: { tunnelID: "正在输入 Tunnel", runtimeKey: "runtime-key-test" }
  });
  assert.equal(runtimeKey.value, "");
});

test("connection page keeps tunnel facts inline and removes summary and bound ID panels", () => {
  const ui = runtime();
  ui.render(page({
    summaryRows: [
      { title: "Service", value: "ready" },
      { title: "MCP", value: "ready" },
      { title: "Tunnel", value: "stopped" },
      { title: "Agent", value: "1" }
    ]
  }));
  assert.equal(ui.root.querySelectorAll(".connection-summary").length, 0);
  assert.equal(ui.root.querySelectorAll(".summary-card").length, 0);
  assert.equal(ui.find(ui.root, node => node.textContent === "已绑定的 Tunnel ID"), null);
  const inlineFacts = ui.find(ui.root, node => node.className.split(" ").includes("tunnel-facts"));
  assert.equal(inlineFacts.children.length, 3);
});

test("agent registration and MCP client rows retain drafts while lists and permissions update", () => {
  const ui = runtime();
  ui.render(page());
  const name = ui.input("Agent 名称");
  name.focus();
  name.dispatch("compositionstart");
  type(name, "正在输入名称");
  const qwen = client(ui.root, "qwen.studio");
  const exposure = qwen.querySelector("select");
  assert.equal(exposure.value, "read-only");
  assert.equal(exposure.disabled, false);
  const clientsCard = ui.find(ui.root, node => node.className.split(" ").includes("connection-card")
    && node.querySelector(".client-row"));
  const originalAppend = clientsCard.appendChild.bind(clientsCard);
  let appendCount = 0;
  clientsCard.appendChild = child => { appendCount += 1; return originalAppend(child); };

  ui.render(page({
    canRegisterAgent: false,
    clients: [{
      ...page().clients[0],
      enabled: true,
      exposureMode: "full",
      displayName: "Qwen Studio 更新",
      canCopyConfiguration: false,
      canRotateCredential: false
    }],
    providers: [{ providerID: "opencode", displayName: "OpenCode 更新", requiresConfiguration: false, detail: "权限已刷新" }]
  }));
  assert.equal(ui.input("Agent 名称"), name);
  assert.equal(ui.document.activeElement, name);
  assert.equal(name.value, "正在输入名称");
  assert.equal(ui.button("弹窗选择文件登记…").disabled, true);
  assert.equal(ui.button("按上方路径登记").disabled, true);
  assert.equal(client(ui.root, "qwen.studio"), qwen);
  assert.equal(qwen.querySelector("select"), exposure);
  assert.equal(exposure.value, "full");
  assert.equal(exposure.disabled, false);
  assert.equal(appendCount, 0);
  assert.equal(ui.find(qwen, node => node.tagName === "button" && node.textContent === "复制 Qwen JSON 配置").hidden, true);

  name.dispatch("compositionend");
  ui.render(page({ canRegisterAgent: true }));
  ui.button("按上方路径登记").dispatch("click");
  assert.equal(ui.commands.at(-1).command, "beginAgentRegistration");
});

test("connection rows expose parity labels and hide ChatGPT toggle", () => {
  const ui = runtime();
  ui.render(page({
    clients: [
      { ...page().clients[0], enabled: true },
      {
        clientID: "chatgpt", displayName: "ChatGPT / OpenAI Tunnel", enabled: true,
        exposureMode: "read-only", exposureOptions: page().clients[0].exposureOptions,
        activeSessionCount: 0, lastConnectedAt: null, canToggle: false,
        canCopyConfiguration: false, canRotateCredential: false
      }
    ],
    installations: [{
      installationID: "install-a", providerID: "opencode", displayName: "OpenCode",
      executablePath: "C:\\Tools\\opencode.exe", version: "1.2.3", protocolRevision: "1",
      adapterRevision: 2, availability: "available", effectiveCapabilities: [],
      enabled: true, canToggle: true, canReprobe: true, canRemove: true
    }]
  }));
  const clientRow = client(ui.root, "qwen.studio");
  assert.equal(clientRow.querySelector(".check-field").hidden, false);
  const chatRow = client(ui.root, "chatgpt");
  assert.equal(chatRow.querySelector(".check-field").hidden, true);
  const chatExposure = chatRow.querySelector("select");
  chatExposure.value = "read-only";
  chatExposure.dispatch("change");
  assert.equal(ui.commands.at(-1).command, "setMCPClientExposure");
  assert.equal(ui.commands.at(-1).payload.clientID, "chatgpt");
  const agent = ui.find(ui.root, node => node.className.split(" ").includes("agent-connect-row"));
  const installation = agent.querySelector(".agent-installation-detail");
  assert.equal(installation.querySelector(".status-badge").textContent, "已连接");
  assert.equal(installation.querySelectorAll(".row-detail")[1].textContent.includes("ACP 1"), true);
  assert.equal(ui.button("重新检查", installation).disabled, false);
  assert.equal(ui.button("移除登记", agent).disabled, false);
});

test("DeepSeek MCP stays inside the DSH connection details across refreshes", () => {
  const ui = runtime();
  const provider = {
    providerID: "deepseek-harness",
    displayName: "DeepSeek Harness",
    requiresConfiguration: false,
    detail: "ACP"
  };
  const server = {
    id: "mcp-filesystem",
    name: "filesystem",
    enabled: true,
    transport: "stdio",
    command: "/usr/local/bin/mcp-filesystem",
    arguments: [],
    environment: [],
    headers: [],
    canToggle: true,
    canEdit: true,
    canDelete: true
  };
  ui.render(page({
    providers: [provider],
    canManageDeepSeekHarnessMCP: true,
    deepSeekHarnessMCPServers: [server]
  }));
  const agent = ui.find(ui.root, node => node.className.split(" ").includes("agent-connect-row"));
  const detailsBody = ui.find(agent, node => node.className.split(" ").includes("agent-details-body"));
  const mcp = ui.find(detailsBody, node => node.className.split(" ").includes("dsh-mcp-card"));
  assert.ok(mcp);
  assert.equal(mcp.parentNode, detailsBody);
  const editor = ui.find(mcp, node => node.className.split(" ").includes("dsh-mcp-editor"));
  ui.find(mcp, node => node.tagName === "button" && node.textContent === "添加 MCP").dispatch("click");
  assert.equal(editor.hidden, false);

  ui.render(page({
    providers: [provider],
    canManageDeepSeekHarnessMCP: true,
    deepSeekHarnessMCPServers: [server, { ...server, id: "mcp-http", name: "http" }]
  }));
  assert.equal(ui.find(ui.root, node => node.className.split(" ").includes("dsh-mcp-card")), mcp);
  assert.equal(ui.find(mcp, node => node.className.split(" ").includes("dsh-mcp-editor")), editor);
  assert.equal(editor.hidden, false);
  assert.equal(ui.findAll(ui.root, node => node.tagName === "section" && node.children.includes(mcp)).length, 0);
});
