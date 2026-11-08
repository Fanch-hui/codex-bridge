export const writeGatePrefix = "codex-bridge.pi.write-gate.v1:";
export const writeGateGranted = "granted";

/**
 * Asks the Bridge host for project write admission before a writing tool runs. The host answers
 * once the shared-directory write lease is held and releases it after the matching
 * `tool_execution_end` event, so no release round trip is needed here.
 */
export async function acquireWriteGate(context, event, ctx) {
  if (!ctx.hasUI || ctx.signal?.aborted) return false;
  const title = writeGatePrefix + JSON.stringify({ revision: 1, nonce: context.nonce,
    taskID: context.taskID, toolCallID: event.toolCallId, tool: event.toolName });
  const option = await ctx.ui.select(title, [writeGateGranted], { signal: ctx.signal });
  return option === writeGateGranted && !ctx.signal?.aborted;
}
