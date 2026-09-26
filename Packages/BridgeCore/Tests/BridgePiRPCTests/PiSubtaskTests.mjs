import assert from "node:assert/strict";
import { mkdir, mkdtemp, realpath, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { registerSubtaskTool } from "../../Sources/BridgePiRPC/Resources/PiBridgeExtension/subtask.mjs";

test("parent shutdown waits for a cancelled child process to exit", async t => {
  const base = path.resolve(process.env.CODEX_BRIDGE_PI_TEST_TMP
    ?? path.join(process.cwd(), ".build", "pi-subtask-tests"));
  await mkdir(base, { recursive: true });
  const root = await realpath(await mkdtemp(path.join(base, "run-")));
  t.after(() => rm(root, { recursive: true, force: true }));
  const childCLI = path.join(root, "rpc-fixture.mjs");
  await writeFile(childCLI, `
    let buffer = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", chunk => {
      buffer += chunk;
      const boundary = buffer.indexOf("\\n");
      if (boundary < 0) return;
      const request = JSON.parse(buffer.slice(0, boundary));
      process.stdout.write(JSON.stringify({ type: "response", id: request.id, success: true }) + "\\n");
      process.stdout.write(JSON.stringify({ type: "message_end", message: { role: "assistant", content: [{ type: "text", text: JSON.stringify({ args: process.argv.slice(2), prompt: request.message }) }] } }) + "\\n");
    });
    process.on("SIGTERM", () => setTimeout(() => process.exit(0), 200));
  `);
  const tools = new Map();
  const runtime = registerSubtaskTool({ registerTool: tool => tools.set(tool.name, tool) }, {
    projectRoot: root, cliArgv: [process.execPath, childCLI], skillPaths: [], nativePermissionRules: [],
  });
  const updates = [];
  const task = "TASK_SENTINEL_70f2 inspect project state";
  const run = tools.get("bridge_subtask").execute("call", { task },
    new AbortController().signal, value => updates.push(value), { cwd: root });

  await waitFor(() => updates.some(value => value.content[0].text.includes("TASK_SENTINEL_70f2")));
  const rpc = JSON.parse(updates.find(value => value.content[0].text.includes("TASK_SENTINEL_70f2")).content[0].text);
  assert.equal(rpc.prompt, `Read-only subtask: ${task}`);
  assert.equal(rpc.args.some(value => value.includes("TASK_SENTINEL_70f2")), false);
  const started = Date.now();
  await runtime.close();
  const elapsed = Date.now() - started;
  await assert.rejects(run, /cancelled/);
  assert.ok(elapsed >= 150, `shutdown returned before child exit (${elapsed}ms)`);
});

async function waitFor(predicate) {
  const deadline = Date.now() + 5_000;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await new Promise(resolve => setTimeout(resolve, 10));
  }
  throw new Error("Child fixture did not receive its RPC prompt.");
}
