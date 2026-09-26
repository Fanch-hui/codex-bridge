import { createReadOnlyChildPolicy } from "./policy.mjs";

export default function registerBridgePiChildPolicy(pi) {
  const encoded = process.env.CODEX_BRIDGE_PI_CHILD_CONTEXT;
  delete process.env.CODEX_BRIDGE_PI_CHILD_CONTEXT;
  const policy = createReadOnlyChildPolicy(JSON.parse(encoded ?? "null"));

  pi.on("tool_call", async event => {
    try {
      if (await policy.inspect(event)) return;
    } catch {}
    return { block: true, reason: "Child tasks may read only the approved workspace and selected skills." };
  });
}
