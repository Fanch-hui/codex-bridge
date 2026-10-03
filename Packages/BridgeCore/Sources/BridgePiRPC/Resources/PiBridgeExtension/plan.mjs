import { Type } from "./mcp-client-sdk.mjs";

export const planStatusKey = "codex-bridge.pi.plan";

export function registerPlanTool(pi, context) {
  pi.registerTool({
    name: "bridge_plan",
    label: "Update plan",
    description: "Create or update the structured task plan and mark item progress.",
    promptSnippet: "Use bridge_plan to publish a short, structured plan for multi-step work and update item statuses as work progresses.",
    parameters: Type.Object({
      items: Type.Array(Type.Object({
        id: Type.String({ minLength: 1, maxLength: 128 }),
        content: Type.String({ minLength: 1, maxLength: 4096 }),
        priority: Type.Optional(Type.Unsafe({
          type: "string", enum: ["low", "normal", "high"],
        })),
        status: Type.Unsafe({
          type: "string", enum: ["pending", "in_progress", "completed"],
        }),
      }, { additionalProperties: false }), { maxItems: 64 }),
    }, { additionalProperties: false }),
    execute: async (_toolCallId, params, _signal, _onUpdate, ctx) => {
      const items = validateItems(params?.items);
      if (!ctx.hasUI) throw new Error("Structured plans require RPC UI support.");
      ctx.ui.setStatus(planStatusKey, JSON.stringify({
        revision: 1,
        nonce: context.nonce,
        taskID: context.taskID,
        items,
      }));
      return { content: [{ type: "text", text: `Published ${items.length} plan items.` }] };
    },
  });
}

function validateItems(value) {
  if (!Array.isArray(value) || value.length > 64) throw new Error("Invalid plan items.");
  const ids = new Set();
  return value.map(item => {
    if (!item || typeof item !== "object" || typeof item.id !== "string"
        || !item.id.trim() || item.id.length > 128 || item.id.includes("\0")
        || ids.has(item.id) || typeof item.content !== "string"
        || !item.content.trim() || Buffer.byteLength(item.content) > 4096
        || !["pending", "in_progress", "completed"].includes(item.status)
        || (item.priority !== undefined && !["low", "normal", "high"].includes(item.priority))) {
      throw new Error("Invalid plan item.");
    }
    ids.add(item.id);
    return { id: item.id, content: item.content, priority: item.priority ?? "normal", status: item.status };
  });
}
