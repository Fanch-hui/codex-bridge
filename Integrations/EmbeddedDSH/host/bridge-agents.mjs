import { createHash, randomUUID } from 'node:crypto';
import { readFile, rename, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { createUserMessage, freezeMessage } from '@deepseek-ai/dsh-llm';
import { defineTool } from '@deepseek-ai/dsh-tools';

const textOutput = { schema: { type: 'string' }, render: (_args, text) => [{ type: 'text', text }] };
const deliveryID = result => `bridge-${createHash('sha256').update(JSON.stringify([result.rootSessionID, result.childID, result.requestID, result.taskID])).digest('hex')}`;
function stableID(...parts) {
  const bytes = createHash('sha256').update(JSON.stringify(parts)).digest().subarray(0, 16);
  bytes[6] = (bytes[6] & 15) | 80;
  bytes[8] = (bytes[8] & 63) | 128;
  const hex = bytes.toString('hex');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

export class BridgeAgents {
  constructor(ctx, rpc, home, events, sessions) {
    this.ctx = ctx;
    this.rpc = rpc;
    this.events = events;
    this.sessions = sessions;
    this.path = join(home, 'bridge-subagents.json');
    this.bindings = [];
    this.providers = new Set();
    this.queue = Promise.resolve();
    this.running = new Map();
  }
  async start() {
    try { this.bindings = JSON.parse(await readFile(this.path, 'utf8')); }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
    this.registerTools();
    for (const rootSessionID of new Set(this.bindings.map(b => b.rootSessionID))) {
      void this.reconcile(rootSessionID).catch(error => process.stderr.write(`DSH subagent recovery failed: ${error.message}\n`));
    }
    const timer = setInterval(() => {
      for (const root of new Set(this.bindings.map(binding => binding.rootSessionID))) {
        void this.reconcile(root).catch(error => process.stderr.write(`DSH subagent recovery failed: ${error.message}\n`));
      }
    }, 5000);
    timer.unref();
  }
  async persist() {
    const task = this.queue.then(async () => {
      const temp = `${this.path}.tmp`;
      await writeFile(temp, `${JSON.stringify(this.bindings, null, 2)}\n`, { mode: 0o600 });
      await rename(temp, this.path);
    });
    this.queue = task.catch(() => {});
    await task;
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
  async agents(agent) {
    return this.rpc.request('bridge/agents', { sessionID: this.rootOf(agent) });
  }
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
  async startExternal(installationID, request) {
    const parent = request.parent;
    const rootSessionID = this.rootOf(parent);
    const toolCallID = request.agentOptions?.provider;
    if (!toolCallID) throw new Error('Missing delegation request identity');
    const childID = stableID('child', rootSessionID, parent.session.id, toolCallID, installationID);
    const requestID = stableID('request', rootSessionID, parent.session.id, toolCallID, installationID);
    const prompt = request.prompt.filter(part => part.type === 'text').map(part => part.text).join('\n');
    const call = { rootSessionID, childID, installationID, requestID,
      ...(request.agentOptions?.model ? { model: request.agentOptions.model } : {}),
      ...(request.agentOptions?.reasoningEffort ? { effort: request.agentOptions.reasoningEffort } : {}) };
    let binding = this.bindings.find(item => item.childID === childID && item.requestID === requestID);
    if (!binding) {
      binding = { ...call, parentSessionID: parent.session.id, state: 'created', initialRequestID: requestID,
        label: request.label, createdAt: Date.now() };
      this.bindings.push(binding);
      await this.persist();
    }
    const receipt = await this.rpc.request('bridge/subagent', { operation: 'start', ...call, prompt });
    if (receipt.childID !== childID || !receipt.taskID) throw new Error('Bridge returned an invalid subagent receipt');
    Object.assign(binding, { taskID: receipt.taskID, state: receipt.state });
    await this.persist();
    this.events.emit(parent.session.id, 'subagent.started', { ...binding, rootSessionID, parentSessionId: parent.session.id });
    let finished = false;
    const result = this.wait(binding).then(value => {
      finished = true;
      return { output: value.output ? [{ type: 'text', text: value.output }] : [],
        stopReason: value.state === 'completed' ? 'completed' : value.state === 'interrupted' ? 'aborted' : 'error',
        ...(value.error ? { diagnostic: String(value.error).slice(0, 4096) } : {}) };
    });
    return { id: childID, result, dispose: async () => {
      if (!finished) await this.rpc.request('bridge/subagent', { operation: 'stop', ...call });
    } };
  }
  async wait(binding) {
    for (;;) {
      const started = Date.now();
      const result = await this.rpc.request('bridge/subagent', { operation: 'wait', ...binding });
      binding.state = result.state;
      await this.persist();
      if (result.terminal === true && result.state !== 'unknown') return result;
      const delay = Math.max(0, 1000 - (Date.now() - started));
      if (delay) await new Promise(resolve => setTimeout(resolve, delay));
    }
  }
  async delegate(args, exec) {
    if (!exec.agent) throw new Error('Delegation requires an agent');
    const agents = await this.agents(exec.agent);
    if (!agents.agents.some(agent => agent.installationID === args.installationID && agent.available)) throw new Error('Agent is not available');
    const parent = exec.agent;
    const rootSessionID = this.rootOf(parent);
    const activation = await this.ctx.subagents.startActivation({
      provider: this.provider(args.installationID), label: args.description,
      request: { parent, prompt: [{ type: 'text', text: args.prompt }], agentOptions: {
        provider: exec.callId,
        ...(args.model ? { model: args.model } : {}), ...(args.effort ? { reasoningEffort: args.effort } : {})
      } }, signal: exec.signal, delivery: 'parent'
    });
    const binding = this.bindings.find(item => item.childID === activation.childId);
    this.running.set(activation.childId, activation);
    void activation.result.then(async () => {
      try {
        if (this.sessions.stopGate.isStopped(rootSessionID)) return;
        const recorded = parent.session.snapshotEvents().some(event => JSON.stringify(event.data).includes(`\"senderSessionId\":\"${binding.childID}\"`));
        if (!recorded || !await this.ctx.sessions.flush(parent.session)) throw new Error('Subagent result is not yet persisted');
        if (this.sessions.stopGate.isStopped(rootSessionID)) return;
        await this.ack(binding);
      } finally { this.running.delete(activation.childId); }
    }).catch(error => process.stderr.write(`DSH subagent delivery failed: ${error.message}\n`));
    return JSON.stringify({ childID: activation.childId, taskID: binding.taskID });
  }
  async ack(binding) {
    await this.rpc.request('bridge/subagent', { operation: 'ack', rootSessionID: binding.rootSessionID,
      childID: binding.childID, requestID: binding.requestID, taskID: binding.taskID });
  }
  async reconcile(rootSessionID) {
    if (this.sessions.stopGate.isStopped(rootSessionID)) return;
    if (this.reconciling?.has(rootSessionID)) return;
    this.reconciling ??= new Set();
    this.reconciling.add(rootSessionID);
    try {
    const { results } = await this.rpc.request('bridge/subagent', { operation: 'results', rootSessionID });
    for (const result of results) {
      if (result.state === 'unknown') continue;
      const binding = this.bindings.find(item => item.childID === result.childID && item.requestID === result.requestID && (!item.taskID || item.taskID === result.taskID));
      if (!binding || this.running.has(binding.childID)) continue;
      if (!binding.taskID) { binding.taskID = result.taskID; binding.state = result.state; await this.persist(); }
      await this.deliver(binding, result);
    }
    } finally { this.reconciling.delete(rootSessionID); }
  }
  async deliver(binding, result) {
    if (this.sessions.stopGate.isStopped(binding.rootSessionID)) return;
    const found = await this.ctx.sessionController.resolveAgent(binding.parentSessionID);
    if (found.error) throw found.error;
    const parent = found.agent;
    const rootAgent = binding.rootSessionID === binding.parentSessionID ? parent : await this.sessions.agent(binding.rootSessionID);
    let group, generation;
    try { ({ group, generation } = await this.sessions.begin(binding.rootSessionID, rootAgent)); }
    catch (error) { if (this.sessions.stopGate.isStopped(binding.rootSessionID)) return; throw error; }
    const id = deliveryID({ ...result, rootSessionID: binding.rootSessionID });
    const events = parent.session.snapshotEvents();
    const already = events.some(event => JSON.stringify(event.data).includes(id));
    const nativeFirst = binding.requestID === binding.initialRequestID && events.some(event =>
      JSON.stringify(event.data).includes(`"senderSessionId":"${binding.childID}"`));
    try {
      if (this.sessions.stopGate.isStopped(binding.rootSessionID)) return;
      if (!events.some(event => event.type === 'subagent/catalog' && event.data.childId === binding.childID)) {
        parent.session.append('subagent/catalog', { version: 2, childId: binding.childID,
          childCreatedAt: binding.createdAt ?? Date.now(), mode: 'external', ...(binding.label ? { label: binding.label } : {}) });
      }
      if (!already && !nativeFirst) {
        const summary = `Bridge subagent ${binding.childID} finished (${result.state}).`;
        const message = createUserMessage({ content: [{ type: 'text', text: `${summary}\n${result.output ?? result.error ?? ''}` }],
          source: { kind: 'subagent-settled', form: 'notice', summary, senderSessionId: binding.childID } });
        parent.steer(freezeMessage({ ...message, id }));
      }
      if (!await this.ctx.sessions.flush(parent.session)) throw new Error('Parent session could not be persisted');
      if (this.sessions.stopGate.isStopped(binding.rootSessionID)) return;
      await this.ack(binding);
    } finally { setImmediate(() => void this.sessions.settle(binding.rootSessionID, rootAgent, group, generation)); }
  }
  async send(childID, prompt, requestID = randomUUID(), rootSessionID) {
    const binding = this.bindings.find(item => item.childID === childID);
    if (!binding) throw new Error('Bridge subagent not found');
    if (binding.rootSessionID !== rootSessionID) throw new Error('Subagent belongs to another session');
    const promptHash = createHash('sha256').update(prompt).digest('hex');
    const existing = this.bindings.find(item => item.childID === childID && item.requestID === requestID);
    if (existing) {
      if (existing.promptHash !== promptHash) throw new Error('Request ID is already bound to another instruction');
      if (existing.taskID) return { accepted: true, taskID: existing.taskID };
    }
    const active = this.running.get(childID);
    if (active && !active.result) throw new Error('Subagent input is being admitted');
    if (!active) this.running.set(childID, {});
    const rootAgent = await this.sessions.agent(rootSessionID);
    let group, generation;
    try {
      ({ group, generation } = await this.sessions.begin(rootSessionID, rootAgent));
      const call = { ...binding, requestID };
      const round = existing ?? { ...call, taskID: undefined, state: 'created', promptHash };
      if (!existing) { this.bindings.push(round); await this.persist(); }
      const receipt = await this.rpc.request('bridge/subagent', { operation: 'send', ...call, prompt });
      Object.assign(round, { taskID: receipt.taskID, state: receipt.state });
      await this.persist();
      if (active?.result) {
        void active.result.finally(() => this.sessions.settle(rootSessionID, rootAgent, group, generation)).catch(() => {});
        return { accepted: true, taskID: round.taskID };
      }
      const task = this.wait(round).then(result => this.deliver(round, result)).finally(() => {
        this.running.delete(childID);
        void this.sessions.settle(rootSessionID, rootAgent, group, generation);
      });
      this.running.set(childID, { result: task });
      void task.catch(error => process.stderr.write(`DSH subagent continuation failed: ${error.message}\n`));
      return { accepted: true, taskID: round.taskID };
    } catch (error) {
      if (!active) this.running.delete(childID);
      if (group) void this.sessions.settle(rootSessionID, rootAgent, group, generation);
      throw error;
    }
  }
  async stop(childID, rootSessionID) {
    const binding = [...this.bindings].reverse().find(item => item.childID === childID);
    if (!binding) throw new Error('Bridge subagent not found');
    if (binding.rootSessionID !== rootSessionID) throw new Error('Subagent belongs to another session');
    await this.rpc.request('bridge/subagent', { operation: 'stop', ...binding });
    return { accepted: true };
  }
  registerTools() {
    const register = (name, description, parameters, execute) => this.ctx.tools.register(defineTool({
      name, description, parameters, output: textOutput, isConcurrencySafe: () => true, execute
    }));
    register('bridge_agents', 'List available connected agents for delegation.', {}, async (_args, exec) => JSON.stringify(await this.agents(exec.agent)));
    register('bridge_agent_models', 'List models for a connected agent.', { installationID: { type: 'string', required: true } },
      async (args, exec) => JSON.stringify(await this.rpc.request('bridge/agentModels', { sessionID: this.rootOf(exec.agent), installationID: args.installationID })));
    register('bridge_delegate', 'Start an independent connected agent. It works in the shared project and its result is delivered to you.', {
      installationID: { type: 'string', required: true }, description: { type: 'string', required: true },
      prompt: { type: 'string', required: true }, model: { type: 'string' }, effort: { type: 'string' }
    }, (args, exec) => this.delegate(args, exec));
    register('bridge_send_agent', 'Send another instruction to a running or finished connected subagent.', {
      childID: { type: 'string', required: true }, prompt: { type: 'string', required: true }
    }, async (args, exec) => {
      const root = this.rootOf(exec.agent);
      return JSON.stringify(await this.send(args.childID, args.prompt, stableID('continue', root, args.childID, exec.callId), root));
    });
    register('bridge_stop_agent', 'Stop a connected subagent.', { childID: { type: 'string', required: true } },
      async (args, exec) => JSON.stringify(await this.stop(args.childID, this.rootOf(exec.agent))));
  }
}
