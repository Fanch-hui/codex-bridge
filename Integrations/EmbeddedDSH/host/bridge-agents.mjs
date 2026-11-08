import { createHash } from 'node:crypto';
import { readFile, rename, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { createUserMessage, freezeMessage } from '@deepseek-ai/dsh-llm';
import { registerBridgeTools, registerCollaborationTools } from './agent-collaboration-tools.mjs';
import { AgentInputs } from './agent-inputs.mjs';
import { AgentDependencyError, dependenciesFor, handoffPrompt, waitForDependencies, waitForPreviousRound } from './agent-handoff.mjs';
import { ExternalWorkspaceAdmission } from './workspace-external-admission.mjs';

const deliveryID = result => `bridge-${createHash('sha256').update(JSON.stringify([result.rootSessionID, result.childID, result.requestID, result.taskID])).digest('hex')}`;
const terminal = new Set(['completed', 'failed', 'interrupted', 'cancelled']);
function workspaceNotice(result) {
  if (result.workspaceMode !== 'isolated') return '';
  const status = result.workspaceStatus ?? 'pending';
  const guidance = {
    pending: 'Changes are waiting to be merged into the project.',
    merged: 'Changes have been merged into the project.',
    conflict: 'Changes have conflicts and remain in the isolated workspace; use bridge_agent_changes to inspect them.',
    retained: 'Changes remain in the isolated workspace and have not been merged.',
    failed: 'The merge failed; changes remain in the isolated workspace.',
    validation_required: 'Changes await successful project validation. Use the workbench recovery area to configure checks or retry validation.',
    recovery_required: 'A partial merge needs recovery. Project writes are paused; use the workbench recovery area to finish or roll back the merge.'
  }[status] ?? `Workspace status: ${status}.`;
  const detail = { workspaceStatus: status,
    ...(result.workspacePath ? { workspacePath: result.workspacePath } : {}),
    ...(result.changedFiles ? { changedFiles: result.changedFiles } : {}),
    ...(result.conflicts ? { conflicts: result.conflicts } : {}),
    ...(result.failureReason ? { failureReason: result.failureReason } : {}),
    ...(result.changedFilesOmitted === undefined ? {} : { changedFilesOmitted: result.changedFilesOmitted }),
    ...(result.conflictsOmitted === undefined ? {} : { conflictsOmitted: result.conflictsOmitted }) };
  return `${guidance}\n${JSON.stringify(detail)}`;
}
function stableID(...parts) {
  const bytes = createHash('sha256').update(JSON.stringify(parts)).digest().subarray(0, 16);
  bytes[6] = (bytes[6] & 15) | 80;
  bytes[8] = (bytes[8] & 63) | 128;
  const hex = bytes.toString('hex');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

export class BridgeAgents {
  constructor(ctx, rpc, home, events, sessions, writes) {
    this.ctx = ctx;
    this.rpc = rpc;
    this.events = events;
    this.sessions = sessions;
    this.path = join(home, 'bridge-subagents.json');
    this.bindings = [];
    this.providers = new Set();
    this.queue = Promise.resolve();
    this.running = new Map();
    this.starting = new Map();
    this.inputs = new AgentInputs(this);
    this.handoffs = new Map();
    this.admission = new ExternalWorkspaceAdmission(ctx, rpc, sessions, writes, () => this.persist());
  }
  async start() {
    try { this.bindings = JSON.parse(await readFile(this.path, 'utf8')); }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
    await this.admission.recoverBindings(this.bindings);
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
  continuationID(rootSessionID, childID, callID) {
    return stableID('continue', rootSessionID, childID, callID);
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
    if (request.prompt.some(part => part.type !== 'text')) throw new Error('This subagent cannot receive non-text content directly; provide supported attachment paths');
    const prompt = request.prompt.filter(part => part.type === 'text').map(part => part.text).join('\n');
    const handoff = this.handoffs.get(`${rootSessionID}:${parent.session.id}:${toolCallID}`) ?? {};
    const call = { rootSessionID, childID, installationID, requestID,
      ...(request.agentOptions?.model ? { model: request.agentOptions.model } : {}),
      ...(request.agentOptions?.reasoningEffort ? { effort: request.agentOptions.reasoningEffort } : {}),
      ...(handoff.attachmentPaths?.length ? { attachmentPaths: handoff.attachmentPaths } : {}) };
    const requestHash = createHash('sha256').update(JSON.stringify({ call, prompt, dependencies: handoff.dependencies ?? [] })).digest('hex');
    let binding = this.bindings.find(item => item.childID === childID && item.requestID === requestID);
    if (!binding) {
      binding = { ...call, parentSessionID: parent.session.id, state: 'created', initialRequestID: requestID,
        admission: 'waiting', label: request.label, createdAt: Date.now(), requestHash,
        dependencies: handoff.dependencies ?? [], deliveryRequired: true, pendingOperation: 'start', pendingPrompt: prompt };
      this.bindings.push(binding);
      await this.persist();
    } else if (binding.admission !== 'waiting' || binding.pendingPrompt !== prompt ||
        (binding.requestHash && binding.requestHash !== requestHash)) {
      throw new Error('Subagent request was already admitted');
    }
    if (this.starting.has(childID)) throw new Error('Subagent request is already queued');
    const controller = new AbortController();
    const abort = () => controller.abort(request.signal?.reason);
    request.signal?.addEventListener('abort', abort, { once: true });
    if (request.signal?.aborted) abort();
    let finished = false;
    const launch = async () => {
      try { await this.waitForDependencies(binding, controller.signal); }
      catch (error) {
        if (controller.signal.aborted) await this.cancelQueued(row => row === binding);
        else if (error instanceof AgentDependencyError) await this.failQueued(binding, error);
        throw error;
      }
      await this.admission.begin(binding, async () => {
        const value = await this.rpc.request('bridge/subagent', { operation: 'start', ...call, prompt });
        if (value.childID !== childID) throw new Error('Bridge returned an invalid subagent receipt');
        return value;
      }, controller.signal);
      this.events.emit(parent.session.id, 'subagent.started', { ...binding, rootSessionID, parentSessionId: parent.session.id });
      if (controller.signal.aborted) await this.requestStop(binding);
      const value = await this.wait(binding);
      await this.admission.release(binding);
      return value;
    };
    let starting;
    const result = launch().then(value => {
      finished = true;
      const output = [value.output, workspaceNotice(value)].filter(Boolean).map(text => ({ type: 'text', text }));
      return { output,
        stopReason: value.state === 'completed' ? 'completed' : value.state === 'interrupted' ? 'aborted' : 'error',
        ...(value.error ? { diagnostic: String(value.error).slice(0, 4096) } : {}) };
    }).finally(() => {
      finished = true;
      if (this.starting.get(childID) === starting) this.starting.delete(childID);
      this.resumeNext(childID);
    });
    starting = { controller, result, binding };
    this.starting.set(childID, starting);
    request.signal?.removeEventListener('abort', abort);
    return { id: childID, result, dispose: async () => {
      controller.abort();
      if (!finished && binding.taskID) await this.requestStop(binding);
      await result.catch(() => {});
    } };
  }
  async wait(binding) {
    const observation = new AbortController();
    void this.observeProgress(binding, observation.signal).catch(error =>
      process.stderr.write(`DSH subagent progress failed: ${error.message}\n`));
    try {
      for (;;) {
        const started = Date.now();
        let result;
        try { result = await this.rpc.request('bridge/subagent', { operation: 'wait', ...binding }); }
        catch (error) {
          process.stderr.write(`DSH subagent wait unavailable: ${error.message}\n`);
          await delay(1000);
          continue;
        }
        if (result.taskID !== binding.taskID || (result.requestID && result.requestID !== binding.requestID)) {
          throw new Error('Bridge returned a result for another subagent request');
        }
        this.rememberSnapshot(binding, result);
        await this.persist();
        if (result.terminal === true && result.state !== 'unknown') return result;
        const pause = Math.max(0, 1000 - (Date.now() - started));
        if (pause) await delay(pause);
      }
    } finally { observation.abort(); }
  }
  async observeProgress(binding, signal) {
    try {
      while (!signal.aborted) {
        await delay(1000, undefined, { signal });
        let snapshot;
        try { snapshot = await this.rpc.request('bridge/subagent', { operation: 'get', ...binding }); }
        catch (error) {
          if (!signal.aborted) process.stderr.write(`DSH subagent progress unavailable: ${error.message}\n`);
          continue;
        }
        if (signal.aborted) return;
        if (snapshot.taskID !== binding.taskID || (snapshot.requestID && snapshot.requestID !== binding.requestID)) {
          throw new Error('Bridge returned progress for another subagent request');
        }
        this.rememberSnapshot(binding, snapshot);
        await this.persist();
      }
    } catch (error) { if (!signal.aborted) throw error; }
  }
  rememberSnapshot(binding, result) {
    const fields = ['state', 'runID', 'capabilities', 'workspaceMode', 'workspaceReason', 'workspaceStatus', 'canRepairWithAgent',
      'changedFiles', 'conflicts', 'failureReason', 'waitingForApproval'];
    for (const key of fields) if (result[key] !== undefined) binding[key] = result[key];
    const active = this.starting.get(binding.childID)?.binding;
    if (!active || active === binding) this.events.emit(binding.parentSessionID, 'subagent.updated', { ...result,
      rootSessionID: binding.rootSessionID, parentSessionId: binding.parentSessionID,
      childID: binding.childID, requestID: binding.requestID });
  }
  async delegate(args, exec) {
    if (!exec.agent) throw new Error('Delegation requires an agent');
    const agents = await this.agents(exec.agent);
    if (!agents.agents.some(agent => agent.installationID === args.installationID && agent.available)) throw new Error('Agent is not available');
    const parent = exec.agent;
    const rootSessionID = this.rootOf(parent);
    const key = `${rootSessionID}:${parent.session.id}:${exec.callId}`;
    this.handoffs.set(key, { dependencies: dependenciesFor(this.bindings, rootSessionID, args.dependsOn),
      attachmentPaths: args.attachmentPaths });
    let activation;
    try {
      activation = await this.ctx.subagents.startActivation({
        provider: this.provider(args.installationID), label: args.description,
        request: { parent, prompt: [{ type: 'text', text: handoffPrompt(args) }], agentOptions: {
          provider: exec.callId,
          ...(args.model ? { model: args.model } : {}), ...(args.effort ? { reasoningEffort: args.effort } : {})
        } }, signal: exec.signal, delivery: 'parent'
      });
    } finally { this.handoffs.delete(key); }
    const binding = this.bindings.find(item => item.childID === activation.childId);
    this.running.set(activation.childId, activation);
    void activation.result.then(async () => {
      if (this.sessions.stopGate.isStopped(rootSessionID)) return;
      const recorded = parent.session.snapshotEvents().some(event => JSON.stringify(event.data).includes(`\"senderSessionId\":\"${binding.childID}\"`));
      if (!recorded || !await this.ctx.sessions.flush(parent.session)) throw new Error('Subagent result is not yet persisted');
      if (this.sessions.stopGate.isStopped(rootSessionID)) return;
      if (binding.taskID && terminal.has(binding.state)) {
        await this.ack(binding);
        binding.resultDelivered = true;
        await this.persist();
      }
    }).finally(() => {
      if (this.running.get(activation.childId) === activation) this.running.delete(activation.childId);
      this.resumeNext(activation.childId);
    }).catch(error => process.stderr.write(`DSH subagent delivery failed: ${error.message}\n`));
    return JSON.stringify({ childID: activation.childId, taskID: binding.taskID,
      state: binding.admission === 'waiting' ? 'waiting-for-workspace' : binding.state });
  }
  async ack(binding) {
    await this.rpc.request('bridge/subagent', { operation: 'ack', rootSessionID: binding.rootSessionID,
      childID: binding.childID, requestID: binding.requestID, taskID: binding.taskID });
  }
  async waitForDependencies(binding, signal) {
    await waitForDependencies(binding, this.bindings, this.rpc, signal, async pending => {
      await this.persist();
      this.events.emit(binding.parentSessionID, 'subagent.dependencies', { childID: binding.childID,
        requestID: binding.requestID, dependencies: pending });
    });
  }
  async reconcile(rootSessionID) {
    if (this.reconciling?.has(rootSessionID)) return;
    this.reconciling ??= new Set();
    this.reconciling.add(rootSessionID);
    try {
      for (const binding of this.bindings.filter(row => row.rootSessionID === rootSessionID)) {
        if (this.inputs.isSending(binding.childID, binding.requestID)) continue;
        if (binding.admission === 'delivery_unknown') continue;
        if (binding.admission === 'waiting' && binding.pendingOperation && typeof binding.pendingPrompt === 'string') {
          this.resumeNext(binding.childID);
          continue;
        }
        if (this.starting.get(binding.childID)?.binding === binding && binding.admission !== 'unknown') continue;
        const state = await this.admission.reconcile(binding);
        if (state?.state === 'delivery_unknown' && binding.inputKind === 'steer') {
          if (binding.taskID && state.taskID && binding.taskID !== state.taskID) throw new Error('Invalid recovered task identity');
          if (state.taskID) binding.taskID = state.taskID;
          binding.admission = 'delivery_unknown';
          await this.persist();
          this.events.emit(binding.parentSessionID, 'subagent.input-unknown', { childID: binding.childID,
            requestID: binding.requestID, ...(binding.taskID ? { taskID: binding.taskID } : {}) });
        } else if (state?.state === 'absent' && ['dispatching', 'unknown'].includes(binding.admission)) {
          const reason = binding.dispatchError;
          Object.assign(binding, { admission: 'cancelled', state: 'failed', ...(reason ? { failureReason: reason } : {}) });
          delete binding.pendingPrompt;
          delete binding.pendingOperation;
          delete binding.dispatchError;
          await this.persist();
          if (!this.sessions.stopGate.isStopped(rootSessionID)) {
            await this.deliver(binding, { state: 'failed', error: reason
              ? `Bridge rejected the subagent request: ${reason}`
              : 'The subagent request was not dispatched; delegate again if still needed.' });
          }
          this.resumeNext(binding.childID);
        } else if (state?.state === 'active' || state?.state === 'terminal') {
          if (['dispatching', 'unknown'].includes(binding.admission)) {
            try {
              const snapshot = await this.rpc.request('bridge/subagent', { operation: 'get',
                rootSessionID, childID: binding.childID, requestID: binding.requestID });
              if (!snapshot.taskID || (binding.taskID && binding.taskID !== snapshot.taskID)) throw new Error('Invalid recovered task identity');
              binding.taskID = snapshot.taskID;
              binding.admission = binding.inputKind === 'steer' ? 'attached' : 'accepted';
              delete binding.dispatchError;
              this.rememberSnapshot(binding, snapshot);
            } catch (error) {
              process.stderr.write(`DSH subagent receipt recovery failed: ${error.message}\n`);
              continue;
            }
          }
          delete binding.pendingPrompt;
          delete binding.pendingOperation;
          if (this.sessions.stopGate.isStopped(rootSessionID)) {
            if (state.state === 'active') await this.requestStop(binding);
            else Object.assign(binding, { admission: 'settled', state: 'interrupted' });
          }
          await this.persist();
        }
      }
      if (this.sessions.stopGate.isStopped(rootSessionID)) return;
      const { results } = await this.rpc.request('bridge/subagent', { operation: 'results', rootSessionID });
      for (const result of results) {
        if (result.state === 'unknown') continue;
        const binding = this.bindings.find(item => item.childID === result.childID && item.requestID === result.requestID && (!item.taskID || item.taskID === result.taskID));
        if (!binding || this.running.has(binding.childID)) continue;
        binding.taskID = result.taskID;
        binding.state = result.state;
        await this.persist();
        if (await this.deliver(binding, result) !== false) {
          binding.resultDelivered = true;
          await this.persist();
        }
        this.resumeNext(binding.childID);
      }
    } finally { this.reconciling.delete(rootSessionID); }
  }
  resumeQueued(binding) {
    if (this.starting.has(binding.childID) || this.running.has(binding.childID)) return;
    const controller = new AbortController();
    let starting, running;
    const task = this.runQueued(binding, controller.signal).finally(() => {
      if (this.starting.get(binding.childID) === starting) this.starting.delete(binding.childID);
      if (this.running.get(binding.childID) === running) this.running.delete(binding.childID);
      const retryLater = binding.retryAfterReconcile;
      delete binding.retryAfterReconcile;
      if (!retryLater || binding.admission === 'cancelled') this.resumeNext(binding.childID);
    });
    starting = { controller, result: task, binding, recovered: true };
    running = { result: task };
    this.starting.set(binding.childID, starting);
    this.running.set(binding.childID, running);
    void task.catch(error => process.stderr.write(`DSH subagent recovery failed: ${error.message}\n`));
  }
  resumeNext(childID) {
    if (this.starting.has(childID) || this.running.has(childID)) return;
    if (this.bindings.some(binding => binding.childID === childID && binding.inputKind !== 'steer' &&
      (['dispatching', 'unknown'].includes(binding.admission) ||
       (binding.admission === 'accepted' && !terminal.has(binding.state))))) return;
    if (this.bindings.some(binding => binding.childID === childID && binding.inputKind !== 'steer' &&
      binding.admission === 'accepted' && binding.deliveryRequired && !binding.resultDelivered)) return;
    const waiting = this.bindings.filter(binding => binding.childID === childID && binding.admission === 'waiting' && binding.pendingOperation);
    const next = waiting.some(binding => binding.waitingReason === 'conflict')
      ? waiting.find(binding => binding.repairConflict) ?? waiting[0] : waiting[0];
    if (next) this.resumeQueued(next);
  }
  async runQueued(binding, signal) {
    if (this.sessions.stopGate.isStopped(binding.rootSessionID)) {
      binding.admission = 'cancelled';
      binding.state = 'cancelled';
      delete binding.pendingPrompt;
      delete binding.pendingOperation;
      await this.persist();
      await this.admission.release(binding);
      return;
    }
    let rootAgent, group, generation;
    let completed = false;
    try {
      rootAgent = await this.sessions.agent(binding.rootSessionID);
      ({ group, generation } = await this.sessions.begin(binding.rootSessionID, rootAgent));
      await this.waitForDependencies(binding, signal);
      const ready = await waitForPreviousRound(binding, this.bindings, this.rpc, signal, async status => {
        if (binding.waitingReason !== status) {
          binding.waitingReason = status;
          await this.persist();
          this.events.emit(binding.parentSessionID, 'subagent.waiting', { childID: binding.childID,
            requestID: binding.requestID, workspaceStatus: status });
        }
        return status === 'conflict' && this.bindings.some(row => row.childID === binding.childID &&
          row !== binding && row.admission === 'waiting' && row.repairConflict === true);
      });
      if (ready === false) { completed = true; return; }
      delete binding.waitingReason;
      await this.admission.begin(binding, async () => {
        const { pendingOperation: operation, pendingPrompt: prompt, ...call } = binding;
        const receipt = await this.rpc.request('bridge/subagent', { operation, ...call, prompt });
        if (operation === 'start' && receipt.childID !== binding.childID) throw new Error('Bridge returned an invalid subagent receipt');
        return receipt;
      }, signal);
      this.events.emit(binding.parentSessionID, 'subagent.started', { ...binding, parentSessionId: binding.parentSessionID });
      if (signal.aborted || this.sessions.stopGate.isStopped(binding.rootSessionID)) await this.requestStop(binding);
      const result = await this.wait(binding);
      await this.admission.release(binding);
      if (await this.deliver(binding, result) !== false) {
        binding.resultDelivered = true;
        await this.persist();
      }
      completed = true;
    } catch (error) {
      if (signal.aborted) await this.cancelQueued(row => row === binding);
      else if (error instanceof AgentDependencyError && binding.admission === 'waiting') await this.failQueued(binding, error);
      if (!['waiting', 'cancelled'].includes(binding.admission) && !this.sessions.stopGate.isStopped(binding.rootSessionID)) {
        await this.deliver(binding, { state: 'unknown', error: 'The subagent delivery outcome is being checked.' });
      }
      if (error instanceof AgentDependencyError && !signal.aborted) {
        await this.deliver(binding, { state: 'failed', error: error.message });
      }
      throw error;
    } finally {
      if (group) void this.sessions.settle(binding.rootSessionID, rootAgent, group, generation);
      if (!completed) binding.retryAfterReconcile = true;
    }
  }
  async requestStop(binding) {
    const starting = this.starting.get(binding.childID);
    if (starting?.stopRequest) return starting.stopRequest;
    const request = this.rpc.request('bridge/subagent', { operation: 'stop', ...binding });
    if (starting) starting.stopRequest = request;
    try { await request; }
    catch (error) { if (starting?.stopRequest === request) starting.stopRequest = undefined; throw error; }
  }
  async stopRoot(rootID) {
    const starts = [...this.starting.values()].filter(entry => entry.binding.rootSessionID === rootID);
    await this.cancelQueued(binding => binding.rootSessionID === rootID && !starts.some(entry => entry.binding === binding));
    for (const entry of starts) entry.controller.abort();
    for (const entry of starts) {
      if (entry.binding.taskID) await this.requestStop(entry.binding);
    }
    const recovered = this.bindings.filter(binding => binding.rootSessionID === rootID && binding.inputKind !== 'steer' &&
      !starts.some(entry => entry.binding === binding) && !terminal.has(binding.state) &&
      ['accepted', 'dispatching', 'unknown'].includes(binding.admission));
    for (const binding of recovered) await this.requestStop(binding);
  }
  async cancelQueued(matches) {
    let changed = false;
    for (const binding of this.bindings) {
      if (!matches(binding) || binding.admission !== 'waiting') continue;
      Object.assign(binding, { admission: 'cancelled', state: 'cancelled' });
      delete binding.pendingPrompt;
      delete binding.pendingOperation;
      changed = true;
    }
    if (changed) await this.persist();
  }
  async failQueued(binding, error) {
    Object.assign(binding, { admission: 'cancelled', state: 'failed', failureReason: error.message });
    delete binding.pendingPrompt;
    delete binding.pendingOperation;
    await this.persist();
  }
  hasRunning(rootID) {
    return [...this.starting.values()].some(entry => entry.binding.rootSessionID === rootID) ||
      this.bindings.some(binding => binding.rootSessionID === rootID && !terminal.has(binding.state) &&
        ['accepted', 'dispatching', 'unknown'].includes(binding.admission));
  }
  async deliver(binding, result) {
    if (this.sessions.stopGate.isStopped(binding.rootSessionID)) return false;
    const found = await this.ctx.sessionController.resolveAgent(binding.parentSessionID);
    if (found.error) throw found.error;
    const parent = found.agent;
    const rootAgent = binding.rootSessionID === binding.parentSessionID ? parent : await this.sessions.agent(binding.rootSessionID);
    let group, generation;
    try { ({ group, generation } = await this.sessions.begin(binding.rootSessionID, rootAgent)); }
    catch (error) { if (this.sessions.stopGate.isStopped(binding.rootSessionID)) return false; throw error; }
    const id = deliveryID({ ...result, rootSessionID: binding.rootSessionID, childID: binding.childID,
      requestID: binding.requestID, taskID: binding.taskID });
    const events = parent.session.snapshotEvents();
    const already = events.some(event => JSON.stringify(event.data).includes(id));
    const nativeFirst = binding.requestID === binding.initialRequestID && events.some(event =>
      JSON.stringify(event.data).includes(`"senderSessionId":"${binding.childID}"`));
    try {
      if (this.sessions.stopGate.isStopped(binding.rootSessionID)) return false;
      if (!events.some(event => event.type === 'subagent/catalog' && event.data.childId === binding.childID)) {
        parent.session.append('subagent/catalog', { version: 2, childId: binding.childID,
          childCreatedAt: binding.createdAt ?? Date.now(), mode: 'external', ...(binding.label ? { label: binding.label } : {}) });
      }
      if (!already && !nativeFirst) {
        const summary = result.state === 'unknown'
          ? `Bridge subagent ${binding.childID}, request ${binding.requestID}, delivery is being checked.`
          : `Bridge subagent ${binding.childID}, request ${binding.requestID}, finished (${result.state}).`;
        const detail = [result.output ?? result.error ?? '', workspaceNotice(result)].filter(Boolean).join('\n');
        const message = createUserMessage({ content: [{ type: 'text', text: `${summary}\n${detail}` }],
          source: { kind: 'subagent-settled', form: 'notice', summary, senderSessionId: binding.childID } });
        parent.steer(freezeMessage({ ...message, id }));
      }
      if (!await this.ctx.sessions.flush(parent.session)) throw new Error('Parent session could not be persisted');
      if (this.sessions.stopGate.isStopped(binding.rootSessionID)) return false;
      if (binding.taskID && result.state !== 'unknown') await this.ack(binding);
      return true;
    } finally { setImmediate(() => void this.sessions.settle(binding.rootSessionID, rootAgent, group, generation)); }
  }
  currentRun(childID) {
    const running = this.starting.get(childID)?.binding;
    if (running?.taskID) return running;
    return [...this.bindings].reverse().find(row => row.childID === childID && row.taskID && row.inputKind !== 'steer');
  }
  assertCurrent(childID, expectedTaskID, expectedRunID) {
    if (!expectedTaskID && !expectedRunID) return;
    const binding = this.currentRun(childID);
    if (!binding || (expectedTaskID && binding.taskID !== expectedTaskID) ||
        (expectedRunID && binding.runID !== expectedRunID)) {
      throw new Error('The subagent has moved to a different task or run');
    }
  }
  send(...args) { return this.inputs.send(...args); }
  receipt(...args) { return this.inputs.receipt(...args); }
  async cancelInput(rootSessionID, childID, requestID) {
    const binding = this.bindings.find(row => row.rootSessionID === rootSessionID &&
      row.childID === childID && row.requestID === requestID);
    if (!binding) return { state: this.inputs.isSending(childID, requestID) ? 'unknown' : 'notFound' };
    if (binding.inputKind === 'steer') {
      return { state: ['unknown', 'dispatching'].includes(binding.admission) ? 'unknown' : 'settled' };
    }
    const starting = this.starting.get(childID);
    if (binding.admission === 'waiting') {
      if (starting?.binding === binding) starting.controller.abort();
      await this.cancelQueued(row => row === binding);
      return { state: 'cancelled' };
    }
    if (binding.admission === 'cancelled' || terminal.has(binding.state)) return { state: 'settled' };
    if (starting?.binding === binding && !binding.taskID) {
      starting.controller.abort();
      return { state: 'unknown' };
    }
    const current = this.currentRun(childID);
    if (!binding.taskID || current?.taskID !== binding.taskID || (binding.runID && current?.runID !== binding.runID)) {
      return { state: 'unknown' };
    }
    await this.requestStop(binding);
    return { state: 'stopping' };
  }
  async stop(childID, rootSessionID, { expectedTaskID, expectedRunID } = {}) {
    this.assertCurrent(childID, expectedTaskID, expectedRunID);
    const rows = this.bindings.filter(item => item.childID === childID && item.inputKind !== 'steer');
    const binding = this.starting.get(childID)?.binding ?? [...rows].reverse().find(item =>
      ['dispatching', 'unknown', 'accepted'].includes(item.admission) && !terminal.has(item.state)) ?? rows.at(-1);
    if (!binding) throw new Error('Bridge subagent not found');
    if (binding.rootSessionID !== rootSessionID) throw new Error('Subagent belongs to another session');
    const starting = this.starting.get(childID);
    await this.cancelQueued(row => row.rootSessionID === rootSessionID && row.childID === childID && row !== starting?.binding);
    this.assertCurrent(childID, expectedTaskID, expectedRunID);
    if (starting && !starting.binding.taskID) {
      starting.controller.abort();
      if (starting.binding.admission === 'waiting' || starting.binding.admission === 'cancelled') {
        await starting.result.catch(() => {});
        return { accepted: true };
      }
      await starting.result.catch(() => {});
      if (starting.binding.admission === 'unknown') throw new Error('The subagent outcome is still being checked');
      return { accepted: true };
    }
    if (starting?.binding.taskID) await this.requestStop(starting.binding);
    else if ((binding.taskID || ['dispatching', 'unknown'].includes(binding.admission)) && !terminal.has(binding.state)) {
      await this.requestStop(binding);
    }
    return { accepted: true };
  }
  registerTools() {
    registerCollaborationTools(this);
    registerBridgeTools(this);
  }
}
