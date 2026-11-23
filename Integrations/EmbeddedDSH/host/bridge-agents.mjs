import { createHash, randomUUID } from 'node:crypto';
import { setTimeout as delay } from 'node:timers/promises';
import { registerBridgeTools, registerCollaborationTools } from './agent-collaboration-tools.mjs';
import { ResultDelivery, activationResult } from './agent-delivery.mjs';
import { dispatchRequest, recordDispatch } from './agent-dispatch.mjs';
import { attachNotices } from './agent-notices.mjs';
import { handoffPrompt } from './agent-handoff.mjs';
import { migrateLegacyBindings } from './agent-migration.mjs';

// How long a torn-down activation waits for the Service to report what became of its child.
const disposeWait = 30000;

export function stableID(...parts) {
  const bytes = createHash('sha256').update(JSON.stringify(parts)).digest().subarray(0, 16);
  bytes[6] = (bytes[6] & 15) | 80;
  bytes[8] = (bytes[8] & 63) | 128;
  const hex = bytes.toString('hex');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

/**
 * The engine's side of connected-agent delegation. The Service owns the rounds (queueing, dispatch,
 * capacity, workspaces, recovery, results; see `round.*` in `bridge/subagent`); this adapter turns the
 * delegation tools and the page's subagent actions into those calls and writes finished results into
 * the parent session.
 */
export class BridgeAgents {
  constructor(ctx, rpc, home, sessions, { pollInterval } = {}) {
    this.ctx = ctx;
    this.rpc = rpc;
    this.home = home;
    this.sessions = sessions;
    this.providers = new Set();
    this.handoffs = new Map();
    this.round = (operation, rootSessionID, fields = {}) =>
      rpc.request('bridge/subagent', { operation: `round.${operation}`, rootSessionID, ...fields });
    this.delivery = new ResultDelivery({ ctx, sessions, round: this.round, interval: pollInterval });
  }
  /** Moves the earlier orchestrator's records into the Service, then offers the tools. A failed move is retried at the next start. */
  async start() {
    this.removeNoticeHook = this.ctx.on('agent/pre-step', attachNotices, { global: true });
    try {
      const tally = await migrateLegacyBindings(this.rpc, this.home);
      if (tally?.skipped) process.stderr.write(`DSH subagent migration skipped ${tally.skipped} record(s): ${JSON.stringify(tally.reasons)}\n`);
    } catch (error) {
      process.stderr.write(`DSH subagent migration will be retried at the next start: ${error.message}\n`);
    }
    registerCollaborationTools(this);
    registerBridgeTools(this);
  }
  rootOf(agent) {
    let session = agent.session;
    const visited = new Set();
    while (session.header.origin === 'subagent' && session.header.parentSession) {
      if (visited.has(session.id)) throw new Error('Invalid subagent lineage');
      visited.add(session.id);
      session = this.ctx.sessions.get(session.header.parentSession);
      if (!session) throw new Error('Parent session is not active');
    }
    return session.id;
  }
  // Connected agents run on the user's own accounts, so only a main session may start or instruct them.
  requireMainSession(agent) {
    if (agent.session.header.origin === 'subagent') {
      throw new Error('Native subagents cannot use connected agents. Only the main session can delegate to or message them.');
    }
  }
  agents(agent) {
    this.requireMainSession(agent);
    return this.agentsFor(this.rootOf(agent));
  }
  agentsFor(rootSessionID) { return this.rpc.request('bridge/agents', { sessionID: rootSessionID }); }
  continuationID(rootSessionID, childID, callID) { return stableID('continue', rootSessionID, childID, callID); }
  provider(installationID) {
    const name = `bridge-${createHash('sha256').update(installationID).digest('hex').slice(0, 20)}`;
    if (!this.providers.has(name)) {
      this.ctx.subagents.registerProvider({
        name, inheritsParentContext: false,
        capabilities: { agentOptions: true, agentPreset: false, outputSchema: false, depthLimit: false },
        start: request => this.startExternal(installationID, request)
      });
      this.providers.add(name);
    }
    return name;
  }
  /** Records the child's first round and returns the activation that settles with its first result. */
  async startExternal(installationID, request) {
    const parent = request.parent;
    this.requireMainSession(parent);
    const rootSessionID = this.rootOf(parent);
    const toolCallID = request.agentOptions?.provider;
    if (!toolCallID) throw new Error('Missing delegation request identity');
    const childID = stableID('child', rootSessionID, parent.session.id, toolCallID, installationID);
    const requestID = stableID('request', rootSessionID, parent.session.id, toolCallID, installationID);
    if (request.prompt.some(part => part.type !== 'text')) throw new Error('This subagent cannot receive non-text content directly; provide supported attachment paths');
    const prompt = request.prompt.filter(part => part.type === 'text').map(part => part.text).join('\n');
    const handoff = this.handoffs.get(`${rootSessionID}:${parent.session.id}:${toolCallID}`) ?? {};
    const waiter = this.delivery.waitFor(rootSessionID, childID, requestID);
    try {
      await this.round('start', rootSessionID, { childID, requestID, installationID, prompt,
        parentSessionID: parent.session.id, ...(request.label ? { label: request.label } : {}),
        ...(request.agentOptions?.model ? { model: request.agentOptions.model } : {}),
        ...(request.agentOptions?.reasoningEffort ? { effort: request.agentOptions.reasoningEffort } : {}),
        ...(handoff.attachmentPaths?.length ? { attachmentPaths: handoff.attachmentPaths } : {}),
        ...(handoff.access ? { access: handoff.access } : {}),
        ...(handoff.dependsOn?.length ? { dependsOn: handoff.dependsOn } : {}) });
    } catch (error) { this.delivery.forget(waiter); throw error; }
    const result = waiter.promise.then(activationResult);
    this.delivery.kick(rootSessionID);
    return { id: childID, result, dispose: async () => {
      if (!waiter.settled) {
        // Nobody wants the child any more: cancel it and give the Service a bounded time to report how it ended.
        const { state } = await this.cancelInput(rootSessionID, childID, requestID);
        if (['cancelled', 'notFound', 'settled'].includes(state)) waiter.reject(new Error('The subagent request was cancelled'));
        else void delay(disposeWait, undefined, { ref: false }).then(() => waiter.reject(new Error('The subagent outcome is still being checked')));
      }
      await result.catch(() => {});
    } };
  }
  async delegate(args, exec) {
    if (!exec.agent) throw new Error('Delegation requires an agent');
    const agents = await this.agents(exec.agent);
    if (!agents.agents.some(agent => agent.installationID === args.installationID && agent.available)) throw new Error('Agent is not available');
    if (args.access !== undefined && args.access !== 'read-only') throw new Error('access must be "read-only" when given');
    const parent = exec.agent;
    const rootSessionID = this.rootOf(parent);
    const key = `${rootSessionID}:${parent.session.id}:${exec.callId}`;
    this.handoffs.set(key, { dependsOn: args.dependsOn, attachmentPaths: args.attachmentPaths, access: args.access });
    let activation;
    try {
      activation = await this.ctx.subagents.startActivation({
        provider: this.provider(args.installationID), label: args.description,
        parent, prompt: [{ type: 'text', text: handoffPrompt(args) }], agentOptions: {
          provider: exec.callId,
          ...(args.model ? { model: args.model } : {}), ...(args.effort ? { reasoningEffort: args.effort } : {})
        }, signal: exec.signal, delivery: 'parent'
      });
    } finally { this.handoffs.delete(key); }
    const waiter = this.delivery.waiterOf(rootSessionID, activation.childId);
    void activation.result.then(() => this.delivery.delivered(parent, rootSessionID, waiter.result))
      .catch(error => process.stderr.write(`DSH subagent delivery failed: ${error.message}\n`))
      .finally(() => this.delivery.forget(waiter));
    return JSON.stringify({ childID: activation.childId, state: 'waiting-for-workspace' });
  }
  /**
   * The user hands a message straight to a connected agent as a subtask of this root session, without the
   * model: the Service records the first round (`origin: 'user'`), and the session gets the child and a
   * notice that does not wake the model. Repeating the call changes nothing: the round is recorded once
   * and the notice is recognised.
   */
  async dispatch(p, revision) {
    const request = dispatchRequest(p);
    const { rootSessionID, childID, requestID, installationID } = request;
    const root = await this.sessions.agent(rootSessionID);
    if (root.session.header.origin === 'subagent') throw new Error('仅根会话可直派子任务');
    if (this.sessions.scopes.isChatOnly(rootSessionID)) throw new Error('请先为会话选择项目文件夹');
    const existing = await this.receipt(rootSessionID, childID, requestID);
    const readOnly = this.ctx.sandboxPolicy.resolve({ session: root.session }).mode === 'read-only';
    let target, saved;
    if (existing.state === 'notFound') {
      target = (await this.agentsFor(rootSessionID)).agents.find(agent => agent.installationID === installationID);
      if (!target?.available) throw new Error('该 Agent 未连接或不可用');
      if (readOnly && target.supportsReadOnly !== true) throw new Error('该 Agent 不支持只读任务');
    } else {
      saved = (await this.list(rootSessionID)).rounds.find(round => round.childID === childID && round.requestID === requestID);
    }
    await this.sessions.stopGate.resume(rootSessionID, revision);
    const catalog = root.session.snapshotEvents().find(event => event.type === 'subagent/catalog' && event.data.childId === childID);
    const name = catalog?.data.label ?? saved?.label ?? request.label ?? target?.displayName ?? installationID;
    await this.round('start', rootSessionID, { childID, requestID, installationID, prompt: request.text, parentSessionID: rootSessionID,
      label: name, origin: 'user', ...(request.model ? { model: request.model } : {}), ...(request.effort ? { effort: request.effort } : {}),
      ...(request.attachmentPaths ? { attachmentPaths: request.attachmentPaths } : {}), ...(readOnly ? { access: 'read-only' } : {}) });
    const { state } = await this.receipt(rootSessionID, childID, requestID);
    if (state === 'cancelled') return { accepted: false, childID, requestID, state };
    recordDispatch(root, { ...request, name });
    if (!await this.ctx.sessions.flush(root.session)) throw new Error('The session could not be persisted');
    void this.delivery.kick(rootSessionID);
    return { accepted: true, childID, requestID, state };
  }
  send(childID, prompt, requestID = randomUUID(), rootSessionID, { delivery, attachmentPaths, repairConflict, expectedTaskID, expectedRunID } = {}) {
    return this.round('send', rootSessionID, { childID, requestID, prompt,
      ...(delivery ? { delivery } : {}), ...(attachmentPaths ? { attachmentPaths } : {}),
      ...(repairConflict === undefined ? {} : { repairConflict }),
      ...(expectedTaskID ? { taskID: expectedTaskID } : {}), ...(expectedRunID ? { runID: expectedRunID } : {}) })
      .finally(() => this.delivery.kick(rootSessionID));
  }
  receipt(rootSessionID, childID, requestID) { return this.round('receipt', rootSessionID, { childID, requestID }); }
  cancelInput(rootSessionID, childID, requestID) { return this.round('cancelInput', rootSessionID, { childID, requestID }); }
  stop(childID, rootSessionID, { expectedTaskID, expectedRunID } = {}) {
    return this.round('stopChild', rootSessionID, { childID,
      ...(expectedTaskID ? { taskID: expectedTaskID } : {}), ...(expectedRunID ? { runID: expectedRunID } : {}) });
  }
  stopRoot(rootSessionID) { return this.round('stopRoot', rootSessionID); }
  async hasRunning(rootSessionID) { return (await this.round('hasRunning', rootSessionID)).running === true; }
  list(rootSessionID) { return this.round('list', rootSessionID); }
  dependencies(rootSessionID, dependsOn, dependencies) {
    return this.round('dependencies', rootSessionID, { dependsOn, ...(dependencies ? { dependencies } : {}) });
  }
  /** Checks the root for results to deliver now. */
  reconcile(rootSessionID) { return this.delivery.kick(rootSessionID); }
}
