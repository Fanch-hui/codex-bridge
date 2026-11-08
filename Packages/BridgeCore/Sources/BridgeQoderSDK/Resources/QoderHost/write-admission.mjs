import { HostError, identifier } from './validation.mjs';

// Tools that cannot change the project directory. Every other tool (shell, file edits, MCP and
// anything unknown) is treated as a writer while a shared-directory write gate is active.
// `Agent` only starts a subagent, whose own tool calls pass through the same hooks and take their
// own leases; holding one for the whole subagent run would block those calls.
const readOnlyTools = new Set(['Read', 'Glob', 'Grep', 'WebSearch', 'WebFetch', 'AskUserQuestion',
  'TaskCreate', 'TaskUpdate', 'TaskGet', 'TaskList', 'UpdateGoal', 'Agent', 'Skill']);
// A write request can wait behind other Agents, so the PreToolUse hook gets more than the default 10 minutes.
export const hookTimeoutSeconds = 3600;

export const isWriteTool = tool => !readOnlyTools.has(tool);

// The channel is gone or the request was withdrawn: the task owner releases whatever is left.
const undeliverable = error => error instanceof HostError
  && ['interaction_cancelled', 'transport_closed'].includes(error.code);

function denial(error) {
  const code = error instanceof HostError ? error.code : 'write_admission_failed';
  return `The project write lease could not be acquired (${code}); the operation was not run.`;
}

/**
 * Per-tool-call project write admission. The Swift side owns the lease; this class asks for it
 * before a writing tool runs and gives it back when the tool is finished, whatever the outcome.
 * `send(phase, toolUseID, signal)` carries one request to the Swift side.
 */
export class WriteAdmission {
  constructor(send) { this.send = send; this.leases = new Map(); }

  // Waits until the lease for this tool call is granted. Repeated calls share one request.
  acquire(toolUseID, signal) {
    const id = identifier(toolUseID, 200);
    let lease = this.leases.get(id);
    if (!lease) {
      lease = Promise.resolve().then(() => this.request(id, signal));
      this.leases.set(id, lease);
    }
    return lease;
  }

  async request(id, signal) {
    try {
      const answer = await this.send('acquire', id, signal);
      if (answer?.granted !== true) throw new HostError('write_admission_denied');
    } catch (error) {
      await this.release(id); // The grant may have raced with this failure.
      throw error;
    }
  }

  async release(toolUseID) {
    if (!this.leases.delete(toolUseID)) return;
    try { await this.send('release', toolUseID); }
    catch (error) { if (!undeliverable(error)) throw error; }
  }

  async releaseAll() {
    let failure;
    for (const id of [...this.leases.keys()]) {
      try { await this.release(id); } catch (error) { failure ??= error; }
    }
    if (failure) throw failure;
  }

  // PreToolUse: a tool that will be approved interactively waits for its lease until the approval
  // is given, so a pending approval never blocks other Agents.
  async preTool(tool, toolUseID, policyResult, signal) {
    const decision = policyResult.hookSpecificOutput?.permissionDecision;
    if (!isWriteTool(tool) || decision === 'deny' || decision === 'ask') return policyResult;
    try { await this.acquire(toolUseID, signal); } catch (error) {
      return { hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny',
        permissionDecisionReason: denial(error) } };
    }
    return policyResult;
  }

  // canUseTool: take the lease once a writing tool is approved; a refusal gives back any lease
  // the PreToolUse hook already took.
  async approved(tool, toolUseID, decision, signal) {
    if (!isWriteTool(tool)) return decision;
    if (decision.behavior !== 'allow') {
      await this.release(toolUseID);
      return decision;
    }
    try { await this.acquire(toolUseID, signal); } catch (error) {
      return { behavior: 'deny', message: denial(error) };
    }
    return decision;
  }
}
