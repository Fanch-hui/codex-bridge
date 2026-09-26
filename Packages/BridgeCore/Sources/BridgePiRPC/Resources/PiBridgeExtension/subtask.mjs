import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { realpath } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { Type } from "./mcp-client-sdk.mjs";

const maximumRuns = 2;
const maximumRuntimeMs = 120_000;
const maximumOutputBytes = 128 * 1024;
const maximumLineBytes = 2 * 1024 * 1024;
const childPolicyPath = fileURLToPath(new URL("./child-policy.mjs", import.meta.url));
const parameters = Type.Object({
  task: Type.String({ minLength: 1, maxLength: 8_192,
    description: "A bounded, read-only subtask for an independent investigation or verification." }),
  name: Type.Optional(Type.String({ maxLength: 128,
    description: "A short display label for the child run." })),
}, { additionalProperties: false });

export function registerSubtaskTool(pi, context) {
  const active = new Map();
  let runCount = 0;
  pi.registerTool({
    name: "bridge_subtask",
    label: "Run read-only subtask",
    description: "Delegate one bounded read-only investigation to a separate Pi CLI process. The child has only read/search tools, no extensions, no MCP tools, no shell, and cannot create recursive subagents.",
    promptSnippet: "Use bridge_subtask for a small independent investigation. Give it a bounded task; child runs are read-only and do not inherit MCP tools.",
    executionMode: "sequential",
    parameters,
    execute: async (toolCallID, params, signal, onUpdate, ctx) => {
      if (runCount >= maximumRuns) throw new Error("The Pi child-run limit for this task has been reached.");
      const task = validateTask(params?.task);
      runCount += 1;
      const id = randomUUID();
      const name = safeName(params?.name);
      const controller = new AbortController();
      const signalSet = [controller.signal];
      if (signal) signalSet.push(signal);
      const combinedSignal = AbortSignal.any(signalSet);
      const update = (status, summary) => onUpdate?.({
        content: [{ type: "text", text: summary || `Pi 子任务 ${status === "in_progress" ? "正在运行" : status}.` }],
        details: { codexBridgeChildRuns: [{ id, name, status, summary: summary || undefined }] },
      });
      update("in_progress", "");
      try {
        const operation = runSubtask({
          context, cwd: ctx.cwd, task, signal: combinedSignal,
          model: ctx.model, thinkingLevel: ctx.thinkingLevel,
          onText: text => update("in_progress", text),
        });
        active.set(controller, operation);
        const result = await operation;
        const status = result.code === 0 ? "completed" : "failed";
        const summary = bounded(result.summary || result.error || "子任务结束，没有返回文本。", maximumOutputBytes);
        const childRun = { id, name, status, summary };
        update(status, summary);
        if (status !== "completed") throw new Error("The Pi child process did not complete successfully.");
        return {
          content: [{ type: "text", text: summary }],
          details: { codexBridgeChildRuns: [childRun] },
        };
      } catch (error) {
        const status = combinedSignal.aborted ? "cancelled" : "failed";
        update(status, status === "cancelled" ? "Pi 子任务已取消。" : "Pi 子任务失败，请检查模型认证与子进程状态。");
        throw error;
      } finally {
        active.delete(controller);
      }
    },
  });
  return {
    async close() {
      const runs = [...active.entries()];
      for (const [controller] of runs) controller.abort();
      await Promise.allSettled(runs.map(([, operation]) => operation));
    },
  };
}

async function runSubtask({ context, cwd, task, signal, model, thinkingLevel, onText }) {
  const projectRoot = await projectWorkingDirectory(cwd, context.projectRoot);
  if (signal.aborted) throw new Error("Pi child process was cancelled.");
  return runCLIChild({ context, cwd: projectRoot, task, signal, model, thinkingLevel, onText });
}

async function runCLIChild({ context, cwd, task, signal, model, thinkingLevel, onText }) {
  const invocation = context.cliArgv;
  if (!Array.isArray(invocation) || invocation.length < 1 || invocation.length > 2
      || invocation.some(value => typeof value !== "string" || !value)) {
    throw new Error("The registered Pi runtime cannot start a child CLI.");
  }
  const promptID = randomUUID();
  const args = [...invocation.slice(1), "--mode", "rpc", "--no-session", "--no-extensions",
    "-e", childPolicyPath, "--no-skills", "--no-prompt-templates", "--no-themes",
    "--no-approve", "--offline", "--tools", "read,grep,find,ls"];
  for (const skillPath of context.skillPaths) args.push("--skill", skillPath);
  if (model?.provider && model?.id) args.push("--provider", model.provider, "--model", model.id);
  if (thinkingLevel) args.push("--thinking", thinkingLevel);
  const childContext = {
    revision: 1,
    projectRoot: context.projectRoot,
    skillPaths: context.skillPaths,
    nativePermissionRules: context.nativePermissionRules.filter(rule =>
      ["read", "grep", "find", "ls"].includes(rule.action)
        && ["deny", "ask"].includes(rule.effect)),
  };
  const environment = { ...process.env,
    CODEX_BRIDGE_PI_CHILD_CONTEXT: JSON.stringify(childContext) };
  delete environment.CODEX_BRIDGE_PI_CONTEXT;
  const child = spawn(invocation[0], args, {
    cwd, env: environment, shell: false, windowsHide: true,
    stdio: ["pipe", "pipe", "ignore"],
  });
  let buffer = "";
  let output = "";
  let promiseFinished = false;
  let promptAccepted = false;
  let agentSettled = false;
  let failure;
  let timeout;
  return await new Promise((resolve, reject) => {
    const finish = (error, result) => {
      if (promiseFinished) return;
      promiseFinished = true;
      clearTimeout(timeout);
      signal.removeEventListener("abort", abort);
      if (error) reject(error); else resolve(result);
    };
    const abort = () => terminate(child);
    if (signal.aborted) abort();
    else signal.addEventListener("abort", abort, { once: true });
    timeout = setTimeout(() => terminate(child), maximumRuntimeMs);
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", chunk => {
      buffer += chunk;
      if (Buffer.byteLength(buffer) > maximumLineBytes) { terminate(child); return; }
      let newline;
      while ((newline = buffer.indexOf("\n")) >= 0) {
        const line = buffer.slice(0, newline);
        buffer = buffer.slice(newline + 1);
        processRPCLine(line, promptID, {
          onPromptAccepted() { promptAccepted = true; },
          onText(text) {
            output = bounded(text, maximumOutputBytes);
            onText(output);
          },
          onSettled() {
            if (!promptAccepted) return;
            agentSettled = true;
            terminate(child);
          },
          onError(message) {
            failure = message;
            terminate(child);
          },
        });
      }
    });
    child.on("error", () => finish(new Error("Pi child process could not start.")));
    child.stdin.on("error", () => terminate(child));
    child.on("close", code => {
      if (signal.aborted) { finish(new Error("Pi child process was cancelled.")); return; }
      if (buffer.trim()) processRPCLine(buffer, promptID, {
        onPromptAccepted() { promptAccepted = true; },
        onText(text) { output = bounded(text, maximumOutputBytes); },
        onSettled() { agentSettled = promptAccepted; },
        onError(message) { failure = message; },
      });
      if (failure) { finish(undefined, { code: 1, summary: output, error: failure }); return; }
      if (agentSettled) { finish(undefined, { code: 0, summary: output }); return; }
      finish(undefined, { code: code ?? 1, summary: output,
        error: "Pi 子任务未能完成。" });
    });
    child.stdin.write(JSON.stringify({ type: "prompt", id: promptID,
      message: `Read-only subtask: ${task}` }) + "\n");
  });
}

function processRPCLine(line, promptID, handlers) {
  if (!line || Buffer.byteLength(line) > maximumLineBytes) return;
  let event;
  try { event = JSON.parse(line); } catch { return; }
  if (event?.type === "response" && event.id === promptID) {
    if (!event.success) handlers.onError(event.error || "Pi child prompt was rejected.");
    else handlers.onPromptAccepted();
    return;
  }
  if (event?.type === "agent_settled") { handlers.onSettled(); return; }
  const message = event?.message;
  if (event?.type !== "message_end" || message?.role !== "assistant") return;
  const text = Array.isArray(message.content)
    ? message.content.filter(block => block?.type === "text").map(block => block.text).join("\n")
    : "";
  if (text) handlers.onText(text);
}

async function projectWorkingDirectory(cwd, projectRoot) {
  if (typeof cwd !== "string" || typeof projectRoot !== "string") {
    throw new Error("Pi child task project identity changed.");
  }
  const [actualCwd, actualRoot] = await Promise.all([realpath(cwd), realpath(projectRoot)]);
  if (!samePath(actualCwd, actualRoot)) throw new Error("Pi child task project identity changed.");
  return actualRoot;
}

function samePath(left, right) {
  const relative = path.relative(left, right);
  const reverse = path.relative(right, left);
  return !relative && !reverse;
}

function terminate(child) {
  if (child.exitCode !== null || child.killed) return;
  child.kill("SIGTERM");
  const force = setTimeout(() => {
    if (child.exitCode === null) child.kill("SIGKILL");
  }, 5_000);
  force.unref?.();
}

function validateTask(value) {
  if (typeof value !== "string" || !value.trim() || value.includes("\0")
      || Buffer.byteLength(value) > 8_192) throw new Error("Invalid Pi child task.");
  return value;
}

function safeName(value) {
  if (typeof value !== "string" || !value.trim()) return "Pi 子任务";
  return bounded(value, 128);
}

function bounded(value, maximumBytes) {
  if (Buffer.byteLength(value) <= maximumBytes) return value;
  return Buffer.from(value).subarray(0, maximumBytes).toString("utf8");
}
