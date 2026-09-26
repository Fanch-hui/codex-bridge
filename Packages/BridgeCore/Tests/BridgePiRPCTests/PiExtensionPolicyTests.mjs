import assert from "node:assert/strict";
import { mkdtemp, mkdir, writeFile, symlink, rm, realpath } from "node:fs/promises";
import path from "node:path";
import { test } from "node:test";
import { createPolicy, createReadOnlyChildPolicy, digest, isContained, validateContext } from "../../Sources/BridgePiRPC/Resources/PiBridgeExtension/policy.mjs";

async function fixture(t, overrides = {}) {
  const base = path.resolve(process.env.CODEX_BRIDGE_PI_TEST_TMP
    ?? path.join(process.cwd(), ".build", "pi-policy-tests"));
  await mkdir(base, { recursive: true });
  const directory = await realpath(await mkdtemp(path.join(base, "run-")));
  t.after(() => rm(directory, { recursive: true, force: true }));
  await writeFile(path.join(directory, "sample.txt"), "hello");
  await writeFile(path.join(directory, "other.txt"), "other");
  const context = { revision: 1, nonce: "11111111-1111-4111-a111-111111111111",
    taskID: "test-task", projectRoot: directory, mode: "workspace-write", networkAllowed: true,
    cliArgv: [process.execPath, "/pi.js"],
    tools: ["read", "grep", "find", "ls", "bridge_plan", "bridge_ask_user", "bridge_subtask",
      "write", "edit", "bash", "powershell"], ...overrides };
  return { directory, context, policy: createPolicy(context) };
}

function event(toolName, input) { return { toolName, toolCallId: "tool-1", input }; }

test("read operations remain available in read-only mode", async t => {
  const { policy } = await fixture(t, { mode: "read-only" });
  assert.equal((await policy.inspect(event("read", { path: "sample.txt" }))).allowed, true);
});

test("managed plan and user-question tools do not require permission prompts", async t => {
  const { policy } = await fixture(t, { mode: "read-only",
    tools: ["read", "grep", "find", "ls", "bridge_plan", "bridge_ask_user", "bridge_subtask"] });
  assert.equal((await policy.inspect(event("bridge_plan", {}))).allowed, true);
  assert.equal((await policy.inspect(event("bridge_ask_user", {}))).allowed, true);
  assert.equal((await policy.inspect(event("bridge_subtask", {}))).allowed, true);
});

test("configured MCP tools are discoverable only for network-enabled write tasks and need approval", async t => {
  const server = { id: "configured-server", name: "Local docs", transport: "http",
    command: null, args: [], url: "http://127.0.0.1:4317/mcp", environment: {}, headers: {} };
  const { policy } = await fixture(t, { mcpServers: [server] });
  const name = "bridge_mcp_0123456789ab_search_docs_0123456789";
  assert.equal(policy.registerMCPTool(name, server.id, server.name, "search_docs"), true);
  assert.equal(policy.activeToolNames().includes(name), true);
  const call = event(name, { query: "Pi RPC" });
  const approval = await policy.inspect(call);
  assert.equal(approval.allowed, false);
  assert.equal(approval.envelope.approvalKind, "network");
  assert.equal(approval.envelope.networkTarget, "Local docs / search_docs");
  assert.equal(policy.decide(approval.envelope, "allow_for_session"), true);
  assert.equal((await policy.inspect(call)).allowed, true);

  const readOnly = await fixture(t, { mode: "read-only", mcpServers: [server] });
  assert.equal(readOnly.policy.registerMCPTool(name, server.id, server.name, "search_docs"), true);
  const denied = await readOnly.policy.inspect(call);
  assert.equal(denied.denied, true);
});

test("child tasks are restricted to the project and selected skill snapshots", async t => {
  const base = path.resolve(process.env.CODEX_BRIDGE_PI_TEST_TMP
    ?? path.join(process.cwd(), ".build", "pi-policy-tests"));
  await mkdir(base, { recursive: true });
  const directory = await realpath(await mkdtemp(path.join(base, "child-")));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const projectRoot = path.join(directory, "project");
  const skillRoot = path.join(directory, "runtime", "skill-0");
  await mkdir(projectRoot, { recursive: true });
  await mkdir(path.join(skillRoot, "references"), { recursive: true });
  await writeFile(path.join(projectRoot, "sample.txt"), "project");
  await writeFile(path.join(skillRoot, "references", "guide.md"), "skill resource");
  const policy = createReadOnlyChildPolicy({ revision: 1, projectRoot,
    skillPaths: [skillRoot], nativePermissionRules: [] });
  assert.equal(await policy.inspect(event("read", { path: "sample.txt" })), true);
  assert.equal(await policy.inspect(event("read", {
    path: path.join(skillRoot, "references", "guide.md"),
  })), true);
  await assert.rejects(policy.inspect(event("read", { path: "../runtime/skill-0/references/guide.md" })), /outside|scope/);
  await assert.rejects(policy.inspect(event("read", { path: path.join(directory, "outside.txt") })), /outside|scope/);
  assert.equal(await policy.inspect(event("write", { path: "sample.txt" })), false);

  const denied = createReadOnlyChildPolicy({ revision: 1, projectRoot,
    skillPaths: [skillRoot], nativePermissionRules: [
      { effect: "deny", action: "read", target: "sample.txt" },
    ] });
  assert.equal(await denied.inspect(event("read", { path: "sample.txt" })), false);
});

test("write and shell are denied in read-only mode", async t => {
  const { policy } = await fixture(t, { mode: "read-only" });
  await assert.rejects(policy.inspect(event("write", { path: "sample.txt", content: "change" })), /read-only/);
  await assert.rejects(policy.inspect(event("bash", { command: "echo hello" })), /Write mode/);
});

test("write requires a local decision", async t => {
  const { policy } = await fixture(t);
  const result = await policy.inspect(event("write", { path: "sample.txt", content: "change" }));
  assert.equal(result.allowed, false);
  assert.deepEqual(result.envelope.relativePaths, ["sample.txt"]);
  assert.equal(policy.decide(result.envelope, "deny"), false);
  assert.equal(policy.decide(result.envelope, undefined), false);
  assert.equal(policy.decide(result.envelope, "allow_once"), true);
  assert.equal((await policy.inspect(event("write", { path: "sample.txt", content: "change" }))).allowed, false);
});

test("saved deny rules override tool defaults and saved allow rules remain mode-bounded", async t => {
  const denied = await fixture(t, { nativePermissionRules: [
    { effect: "deny", action: "read", target: "sample*" },
  ] });
  const denyResult = await denied.policy.inspect(event("read", { path: "sample.txt" }));
  assert.equal(denyResult.denied, true);

  const allowed = await fixture(t, { nativePermissionRules: [
    { effect: "allow", action: "write", target: "sample*" },
  ] });
  assert.equal((await allowed.policy.inspect(event("write", { path: "sample.txt", content: "change" }))).allowed, true);

  const readOnly = await fixture(t, { mode: "read-only", nativePermissionRules: [
    { effect: "allow", action: "write", target: "sample*" },
  ] });
  await assert.rejects(readOnly.policy.inspect(event("write", { path: "sample.txt", content: "change" })), /read-only/);
});

test("saved ask rules require an operation-specific approval", async t => {
  const { policy } = await fixture(t, { nativePermissionRules: [
    { effect: "ask", action: "write", target: "sample.txt" },
  ] });
  const result = await policy.inspect(event("write", { path: "sample.txt", content: "change" }));
  assert.equal(result.allowed, false);
  assert.equal(policy.decide(result.envelope, "allow_for_session"), true);
  assert.equal((await policy.inspect(event("write", { path: "sample.txt", content: "change" }))).allowed, true);
  assert.equal((await policy.inspect(event("write", { path: "other.txt", content: "change" }))).allowed, false);
});

test("session approval applies only to the exact tool input", async t => {
  const { policy } = await fixture(t);
  const command = event("bash", { command: "echo hello" });
  const result = await policy.inspect(command);
  assert.equal(policy.decide(result.envelope, "allow_for_session"), true);
  assert.equal((await policy.inspect(command)).allowed, true);
  assert.equal((await policy.inspect(event("bash", { command: "echo changed" }))).allowed, false);
  policy.clear();
  assert.equal((await policy.inspect(command)).allowed, false);
});

test("shell is denied without network-capable execution", async t => {
  const { policy } = await fixture(t, { networkAllowed: false });
  await assert.rejects(policy.inspect(event("powershell", { command: "Get-Date" })), /network/);
});

test("parent escape and root prefix siblings are rejected", async t => {
  const { directory, policy } = await fixture(t);
  await assert.rejects(policy.inspect(event("read", { path: "../outside" })), /outside/);
  await assert.rejects(policy.inspect(event("write", { path: directory + "-other/file" })), /outside/);
});

test("sensitive paths cannot be directly read", async t => {
  const { policy } = await fixture(t);
  for (const target of [".env", ".env.local", ".git/config", ".ssh/id_rsa", "Secrets/data"]) {
    await assert.rejects(policy.inspect(event("read", { path: target })), /Sensitive/);
  }
});

test("symlink targets are rejected", async t => {
  const { directory, policy } = await fixture(t);
  const destination = path.join(directory, "actual");
  await mkdir(destination);
  await symlink(destination, path.join(directory, "link"), process.platform === "win32" ? "junction" : "dir");
  await assert.rejects(policy.inspect(event("write", { path: "link/new.txt" })), /Linked/);
});

test("new nested files may request approval", async t => {
  const { policy } = await fixture(t);
  const result = await policy.inspect(event("write", { path: "new/nested/file.txt", content: "hello" }));
  assert.equal(result.allowed, false);
  assert.deepEqual(result.envelope.relativePaths, ["new/nested/file.txt"]);
});

test("unknown tools and invalid commands fail closed", async t => {
  const { policy } = await fixture(t);
  await assert.rejects(policy.inspect(event("unregistered", {})), /active task policy/);
  await assert.rejects(policy.inspect(event("bash", { command: "echo\0hello" })), /Invalid/);
  await assert.rejects(policy.inspect(event("bash", { command: "x".repeat(8193) })), /Invalid/);
});

test("Windows containment respects drives separators and case", () => {
  assert.equal(isContained("D:\\Project", "d:/project/src/a.swift", path.win32), true);
  assert.equal(isContained("D:\\Project", "D:\\ProjectOther\\a", path.win32), false);
  assert.equal(isContained("D:\\Project", "E:\\Project\\a", path.win32), false);
  assert.equal(isContained("D:\\Project", "D:\\Project\\..\\secret", path.win32), false);
});

test("canonical digest is independent of JSON property order", () => {
  assert.equal(digest({ a: 1, b: { c: 2, d: 3 } }), digest({ b: { d: 3, c: 2 }, a: 1 }));
  assert.notEqual(digest({ a: [1, 2] }), digest({ a: [2, 1] }));
});

test("invalid execution contexts are rejected", async t => {
  const { context } = await fixture(t);
  assert.throws(() => validateContext({ ...context, tools: ["read", "read"] }), /Invalid/);
  assert.throws(() => validateContext({ ...context, mode: "all" }), /Invalid/);
  assert.throws(() => validateContext({ ...context, nonce: "" }), /Invalid/);
  assert.throws(() => validateContext({ ...context, tools: ["custom"] }), /Invalid/);
});

test("approval cache is bounded", async t => {
  const { policy } = await fixture(t);
  for (let index = 0; index < 256; index += 1) {
    const result = await policy.inspect(event("bash", { command: `echo ${index}` }));
    assert.equal(policy.decide(result.envelope, "allow_for_session"), true);
  }
  const next = await policy.inspect(event("bash", { command: "echo over-limit" }));
  assert.equal(policy.decide(next.envelope, "allow_for_session"), false);
  assert.equal(policy.decide(next.envelope, "allow_once"), true);
});
