import assert from "node:assert/strict";
import { test } from "node:test";
import registerBridge from "../../Sources/BridgePiRPC/Resources/PiBridgeExtension/index.mjs";

async function extensionFixture() {
  const context = { revision: 1, nonce: "11111111-1111-4111-a111-111111111111",
    taskID: "test-task", projectRoot: process.cwd(), mode: "read-only", networkAllowed: false,
    cliArgv: [process.execPath, "/pi.js"],
    tools: ["read", "grep", "find", "ls", "bridge_plan", "bridge_ask_user", "bridge_subtask"] };
  const handlers = new Map();
  const tools = new Map();
  const statuses = [];
  let activeTools = [];
  const pi = {
    on(name, handler) { handlers.set(name, [...(handlers.get(name) ?? []), handler]); },
    registerTool(tool) { tools.set(tool.name, tool); },
    getActiveTools() { return activeTools; },
    setActiveTools(names) { activeTools = [...names]; },
  };
  const ctx = { hasUI: true, signal: new AbortController().signal,
    ui: { setStatus(key, text) { statuses.push({ key, text }); } } };
  const previousContext = process.env.CODEX_BRIDGE_PI_CONTEXT;
  process.env.CODEX_BRIDGE_PI_CONTEXT = JSON.stringify(context);
  await registerBridge(pi);
  if (previousContext === undefined) delete process.env.CODEX_BRIDGE_PI_CONTEXT;
  else process.env.CODEX_BRIDGE_PI_CONTEXT = previousContext;
  return { context, handlers, tools, statuses, activeTools: () => activeTools, ctx };
}

test("registers Bridge plan tool and publishes status updates", async () => {
  const fixture = await extensionFixture();
  await fixture.handlers.get("session_start")[0]({}, fixture.ctx);
  assert.deepEqual(fixture.activeTools(), fixture.context.tools);
  assert.equal(fixture.tools.has("bridge_plan"), true);
  const handshake = JSON.parse(fixture.statuses[0].text);
  assert.deepEqual(handshake.capabilities, ["plan", "user_input", "mcp_client", "subagents"]);

  const tool = fixture.tools.get("bridge_plan");
  const result = await tool.execute("tool-1", { items: [
    { id: "inspect", content: "Inspect the project", priority: "high", status: "in_progress" },
    { id: "fix", content: "Fix the issue", status: "pending" },
  ] }, undefined, undefined, fixture.ctx);
  assert.match(result.content[0].text, /2 plan items/);
  const update = JSON.parse(fixture.statuses[1].text);
  assert.equal(fixture.statuses[1].key, "codex-bridge.pi.plan");
  assert.equal(update.nonce, fixture.context.nonce);
  assert.equal(update.taskID, fixture.context.taskID);
  assert.deepEqual(update.items.map(item => item.status), ["in_progress", "pending"]);
  assert.equal(update.items[1].priority, "normal");
});

test("rejects malformed and duplicate plan items", async () => {
  const fixture = await extensionFixture();
  await fixture.handlers.get("session_start")[0]({}, fixture.ctx);
  const tool = fixture.tools.get("bridge_plan");
  await assert.rejects(tool.execute("tool-1", { items: [
    { id: "same", content: "One", status: "pending" },
    { id: "same", content: "Two", status: "completed" },
  ] }, undefined, undefined, fixture.ctx), /Invalid plan item/);
  await assert.rejects(tool.execute("tool-1", { items: [
    { id: "bad", content: "Bad", status: "unknown" },
  ] }, undefined, undefined, fixture.ctx), /Invalid plan item/);
  assert.equal(fixture.statuses.length, 1);
});
