// Codex Bridge: the words the bridge says to the model and to the operator
// about client tools. Kept apart from index.mjs so an upstream update changes
// little around them.

// The answer agy's MCP call gets when the client's tool has not finished by
// the call deadline (index.mjs, #deferCall). It is not a result: agy fails an
// MCP call after a fixed three minutes, and this ends the call before then.
// The only thing a repeat call with the same arguments does is wait for the
// run in progress, never start it again (acceptMcpCall finds the deferred
// call by name and arguments), so the model is told to do just that. Callers
// match "still running", keep it.
export function stillRunningText(name) {
  return `${name} is still running in the client; no result yet. This is not a result and not an error. ` +
    `Do not start other work, do not run it another way, and do not assume it failed. ` +
    `To keep waiting, call ${name} again now with exactly the same arguments. ` +
    `That call only waits for the run in progress and does not start it a second time. ` +
    `Keep doing this until the real result arrives.`
}

// Added after the real results of calls that finished once agy had moved on
// (index.mjs, renderLateResults). "Their real results" stays in the first
// line, which callers match.
export const LATE_RESULTS_NOTE =
  "These are the final results of those calls and replace the earlier \"still running\" notes. " +
  "Continue from them and do not run those calls again."

// Said with the error for a request whose tools agy never listed
// (index.mjs, toolsUnlistedError). A new agy release can change how it starts
// MCP servers (it runs `nc` for the bridge's), and then every request that
// declares a tool fails the same way.
export function toolBridgeHint(agentVersion) {
  const version = agentVersion ? ` ${agentVersion}` : ""
  return `If agy${version} was updated recently, its way of starting MCP servers may have changed: ` +
    `update Codex Bridge, or use the agy version it was last known to work with`
}
