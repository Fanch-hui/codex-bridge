import assert from "node:assert/strict";
import { test } from "node:test";
import registerBridge from "../../Sources/BridgePiRPC/Resources/PiBridgeExtension/index.mjs";

async function fixture() {
  const context = { revision: 1, nonce: "11111111-1111-4111-a111-111111111111",
    taskID: "ask-user-test", projectRoot: process.cwd(), mode: "read-only", networkAllowed: false,
    cliArgv: [process.execPath, "/pi.js"],
    tools: ["read", "grep", "find", "ls", "bridge_plan", "bridge_ask_user", "bridge_subtask"] };
  const handlers = new Map();
  const tools = new Map();
  const requests = [];
  let activeTools = [];
  const pi = {
    on(name, handler) { handlers.set(name, [...(handlers.get(name) ?? []), handler]); },
    registerTool(tool) { tools.set(tool.name, tool); },
    getActiveTools() { return activeTools; },
    setActiveTools(names) { activeTools = [...names]; },
  };
  const ctx = { hasUI: true, signal: new AbortController().signal,
    ui: {
      setStatus() {},
      async select(title, options) { requests.push({ method: "select", title, options }); return options[1]; },
      async input(title, placeholder) {
        requests.push({ method: "input", title, placeholder });
        const questionnaire = JSON.parse(title.slice(title.indexOf(":" ) + 1));
        const question = questionnaire.questions[0];
        const answer = question.options.length ? question.options[1].label : "free-form";
        return JSON.stringify({ answers: { [question.id]: [answer] } });
      },
    } };
  const previousContext = process.env.CODEX_BRIDGE_PI_CONTEXT;
  process.env.CODEX_BRIDGE_PI_CONTEXT = JSON.stringify(context);
  await registerBridge(pi);
  if (previousContext === undefined) delete process.env.CODEX_BRIDGE_PI_CONTEXT;
  else process.env.CODEX_BRIDGE_PI_CONTEXT = previousContext;
  return { context, handlers, tools, requests, activeTools: () => activeTools, ctx };
}

test("registers an active model-callable ask-user tool with controlled options", async () => {
  const value = await fixture();
  await value.handlers.get("session_start")[0]({}, value.ctx);
  assert.equal(value.tools.has("bridge_ask_user"), true);
  assert.equal(value.activeTools().includes("bridge_ask_user"), true);
  const result = await value.tools.get("bridge_ask_user").execute("call-1", {
    question: "Choose a direction", options: ["Keep", "Change"],
  }, value.ctx.signal, undefined, value.ctx);
  assert.equal(value.requests[0].method, "input");
  assert.equal(value.requests[0].title.startsWith("codex-bridge.pi.questionnaire.v1:"), true);
  assert.deepEqual(JSON.parse(result.content[0].text), { answers: { answer: ["Change"] } });
});

test("uses the native free-text dialog when options are omitted", async () => {
  const value = await fixture();
  const result = await value.tools.get("bridge_ask_user").execute("call-2", {
    question: "What should happen next?",
  }, value.ctx.signal, undefined, value.ctx);
  assert.equal(value.requests[0].method, "input");
  assert.equal(value.requests[0].placeholder, "等待 Bridge 用户表单");
  assert.deepEqual(JSON.parse(result.content[0].text), { answers: { answer: ["free-form"] } });
});
