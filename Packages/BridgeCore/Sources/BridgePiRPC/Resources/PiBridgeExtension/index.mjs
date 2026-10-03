import { approvalOptions, approvalPrefix, createPolicy } from "./policy.mjs";
import { registerAskUserTool } from "./ask-user.mjs";
import { registerPlanTool } from "./plan.mjs";
import { registerMCPTools } from "./mcp.mjs";
import { registerSubtaskTool } from "./subtask.mjs";

export default async function registerBridge(pi) {
  const encodedContext = process.env.CODEX_BRIDGE_PI_CONTEXT;
  delete process.env.CODEX_BRIDGE_PI_CONTEXT;
  const context = JSON.parse(encodedContext ?? "null");
  const policy = createPolicy(context);
  const version = process.versions.node.split(".").map(Number);
  if (version[0] < 22 || (version[0] === 22 && version[1] < 19)) {
    throw new Error("The Bridge Pi extension requires Node.js 22.19 or newer.");
  }
  if (typeof pi.getActiveTools !== "function" || typeof pi.setActiveTools !== "function") {
    throw new Error("The installed Pi extension API is incompatible.");
  }
  registerPlanTool(pi, policy.context);
  registerAskUserTool(pi);
  const subtaskRuntime = registerSubtaskTool(pi, policy.context);
  const mcpRuntime = await registerMCPTools(pi, policy, policy.context);

  pi.on("session_start", (_event, ctx) => {
    if (!ctx.hasUI) throw new Error("The Bridge Pi extension requires RPC UI support.");
    pi.setActiveTools(mcpRuntime.activeTools);
    const active = pi.getActiveTools();
    if (active.length !== mcpRuntime.activeTools.length
        || mcpRuntime.activeTools.some(name => !active.includes(name))) {
      throw new Error("The installed Pi runtime does not provide the requested tools.");
    }
    ctx.ui.setStatus("codex-bridge.pi", JSON.stringify({ revision: 1,
      nonce: policy.context.nonce, tools: mcpRuntime.activeTools,
      capabilities: ["plan", "user_input", "mcp_client", "subagents"],
      mcp: mcpRuntime.state }));
  });

  pi.on("tool_call", async (event, ctx) => {
    const result = await policy.inspect(event);
    if (result.allowed) return;
    if (result.denied) return { block: true, reason: result.reason };
    if (!ctx.hasUI || ctx.signal?.aborted) return { block: true, reason: "Tool approval cancelled." };
    const option = await ctx.ui.select(approvalPrefix + JSON.stringify(result.envelope), [...approvalOptions]);
    if (ctx.signal?.aborted || !policy.decide(result.envelope, option)) {
      return { block: true, reason: "The local user did not approve this operation." };
    }
  });

  pi.on("session_shutdown", async () => {
    policy.clear();
    await Promise.all([mcpRuntime.close(), subtaskRuntime.close()]);
  });
}
