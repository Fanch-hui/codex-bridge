import { present, presentHistory, presentProjections } from './presentation.mjs';
import { SessionStopGate } from './session-stop-gate.mjs';
import { PromptReceipts, promptFingerprint } from './prompt-receipts.mjs';
import { inboxEvidence } from './inbox-evidence.mjs';

const durableAdmission = Symbol.for('codex-bridge.durable-session-admission');

export class Sessions {
  constructor(ctx, rpc, home) {
    this.ctx = ctx; this.rpc = rpc; this.groups = new Map(); this.stopGate = new SessionStopGate(home);
    this.receipts = new PromptReceipts(home); this.promptRequests = new Map();
    this.titles = new Map();
    this.titleSeqs = new Map();
    ctx.on('session/created', session => { this.titles.delete(session.id); this.titleSeqs.delete(session.id); }, { global: true });
    ctx.on('session/event', (session, event) => {
      if (event.type === 'session/title') {
        this.titles.set(session.id, event.data.title);
        this.titleSeqs.set(session.id, event.seq);
      }
    }, { global: true });
  }
  async start() {
    await this.stopGate.start();
    await this.receipts.start();
  }
  async list(signal) {
    const result = await this.ctx.sessionController.list({}, signal);
    const cold = result.items.filter(row => !this.ctx.sessions.get(row.sessionId) && !this.titles.has(row.sessionId));
    const observations = await this.ctx.sessionQuery.readTitleSnapshots(cold.map(row => row.sessionId), signal);
    const failures = new Set();
    for (const observation of observations) {
      if (observation.status === 'rejected') {
        failures.add(observation.sessionId);
        process.stderr.write(`DSH session title lookup failed: ${observation.reason?.message ?? observation.reason}\n`);
      } else if (!this.titles.has(observation.sessionId)) {
        this.titles.set(observation.sessionId, observation.value.title?.title ?? null);
        if (Number.isSafeInteger(observation.value.title?.eventSeq)) {
          this.titleSeqs.set(observation.sessionId, observation.value.title.eventSeq);
        }
      }
    }
    return { ...result, items: result.items.map(row => {
      if (failures.has(row.sessionId)) return { ...row, titleUnavailable: true };
      const title = this.ctx.sessions.get(row.sessionId)
        ? row.projections?.values?.title : this.titles.get(row.sessionId);
      if (title === undefined) return row;
      return { ...row, title, ...(row.projections ? {
        projections: { ...row.projections, values: { ...row.projections.values, title } }
      } : {}) };
    }) };
  }
  async agent(id) {
    const live = this.ctx.agents.get(id);
    if (live) return live;
    const found = await this.ctx.sessionController.resolveAgent(id);
    if (found.error) throw found.error;
    return found.agent;
  }
  async queue(id) {
    const agent = await this.agent(id);
    const entries = [['next-turn', agent.inbox.nextTurn], ['next-step', agent.inbox.nextStep]];
    return { items: entries.flatMap(([target, messages]) => messages.filter(message => message.source?.kind === 'user')
      .map(message => ({ id: message.id, target, content: present(message.content),
        ...(message.source.rpcId ? { requestId: message.source.rpcId } : {}) }))) };
  }
  async rootID(id) {
    let header = (await this.ctx.sessionController.inspect(id)).meta;
    const seen = new Set();
    while (header.origin === 'subagent' && header.parentSession) {
      if (seen.has(header.id)) throw new Error('Invalid subagent lineage');
      seen.add(header.id);
      header = (await this.ctx.sessionController.inspect(header.parentSession)).meta;
    }
    return header.id;
  }
  async history(payload, signal) {
    const { meta } = await this.ctx.sessionController.inspect(payload.sessionId, signal);
    const address = meta.origin === 'subagent' && meta.parentSession
      ? { kind: 'subagent', parentSessionId: meta.parentSession, childSessionId: payload.sessionId, mode: 'unknown' }
      : { kind: 'session', sessionId: payload.sessionId };
    if (payload.throughSeq !== undefined && payload.beforeSeq !== undefined) {
      const page = await this.ctx.sessionController.page({
        address, throughSeq: payload.throughSeq,
        beforeSeq: payload.beforeSeq, ...(payload.maxMessages ? { maxMessages: payload.maxMessages } : {})
      }, signal);
      const projected = presentHistory(page.records);
      return { records: projected.records, hasMore: page.hasMore || projected.truncated, cursor: payload.throughSeq };
    }
    const iterator = this.ctx.sessionController.follow({ address, assistantStream: true }, signal)[Symbol.asyncIterator]();
    try {
      const frame = (await iterator.next()).value;
      if (frame?.type !== 'snapshot') throw new Error('Missing DSH session history');
      const projected = presentHistory(frame.records);
      const { projections, omitted } = presentProjections(frame.projections);
      return { records: projected.records, hasMore: frame.hasMore || projected.truncated, cursor: frame.cursor,
        modelSelection: frame.projections.values.modelSelection?.next ?? null,
        header: present(frame.header), projections,
        ...(frame.assistantStream ? { assistantStream: present(frame.assistantStream) } : {}),
        ...(omitted.length ? { omittedProjections: omitted } : {}) };
    } finally { await iterator.return?.(); }
  }
  async prompt(payload) {
    if (typeof payload.sessionId !== 'string' || !payload.sessionId ||
        typeof payload.requestId !== 'string' || !payload.requestId) throw new Error('Session and request IDs are required');
    const key = JSON.stringify([payload.sessionId, payload.requestId]);
    const fingerprint = promptFingerprint(payload);
    const running = this.promptRequests.get(key);
    if (running) {
      if (running.fingerprint !== fingerprint) throw new Error('Request ID was already used for different content');
      return running.promise;
    }
    const promise = this.admitPrompt(payload, fingerprint);
    this.promptRequests.set(key, { fingerprint, promise });
    try { return await promise; }
    finally { if (this.promptRequests.get(key)?.promise === promise) this.promptRequests.delete(key); }
  }
  async admitPrompt(payload, fingerprint) {
    const durable = globalThis[durableAdmission] === true;
    const registered = await this.receipts.register(payload.sessionId, payload.requestId, fingerprint, durable);
    if (registered.existing) {
      const receipt = await this.receiptFor(payload.sessionId, payload.requestId, registered);
      if (receipt.state === 'accepted') return { accepted: true };
      if (receipt.state !== 'notFound') throw new Error('Prompt admission outcome is still being checked');
    }
    const revision = this.stopGate.revision(payload.sessionId);
    const agent = await this.agent(payload.sessionId);
    this.scopes?.prepareAgent(agent);
    await this.stopGate.resume(payload.sessionId, revision);
    const { group, generation } = await this.begin(payload.sessionId, agent);
    try {
      const result = await this.ctx.sessionController.prompt({
        sessionId: payload.sessionId, requestId: payload.requestId, mode: payload.mode ?? 'queue',
        ...(payload.clientTimeZone ? { clientTimeZone: payload.clientTimeZone } : {}),
        content: payload.content ?? [{ type: 'text', text: payload.text }],
        ...(durable ? { bridgeAdmission: { mayWake: () => this.stopGate.revision(payload.sessionId) === revision &&
          !this.stopGate.isStopped(payload.sessionId) } } : {})
      }, new AbortController().signal);
      await this.receipts.accept(payload.sessionId, payload.requestId);
      setImmediate(() => void this.settle(payload.sessionId, agent, group, generation));
      return result;
    } catch (error) {
      setImmediate(() => void this.settle(payload.sessionId, agent, group, generation));
      throw error;
    }
  }
  async receipt(payload) {
    if (typeof payload.sessionId !== 'string' || !payload.sessionId ||
        typeof payload.requestId !== 'string' || !payload.requestId) throw new Error('Session and request IDs are required');
    const key = JSON.stringify([payload.sessionId, payload.requestId]);
    if (this.promptRequests.has(key)) return { state: 'unknown' };
    return this.receiptFor(payload.sessionId, payload.requestId, this.receipts.get(payload.sessionId, payload.requestId));
  }
  async receiptFor(sessionID, requestID, row) {
    try {
      const agent = await this.agent(sessionID);
      const matches = message => message?.source?.kind === 'user' && message.source.rpcId === requestID;
      const pending = [...agent.inbox.nextTurn, ...agent.inbox.nextStep].some(matches);
      const evidence = inboxEvidence(agent.session.snapshotEvents(), matches);
      const accepted = pending || evidence.state !== 'missing';
      if (accepted) {
        if (row?.state !== 'accepted' && !await this.ctx.sessions.flush(agent.session)) return { state: 'unknown' };
        return { state: 'accepted', pending: pending || evidence.state === 'claimed' };
      }
      if (row?.state === 'accepted') return { state: 'accepted' };
      if (row?.durable && globalThis[durableAdmission] === true) return { state: 'notFound' };
    } catch (error) {
      if (row?.state === 'accepted') return { state: 'accepted' };
    }
    return { state: 'unknown' };
  }
  async resumePending(payload) {
    if (typeof payload.sessionId !== 'string' || typeof payload.requestId !== 'string') throw new Error('Session and request IDs are required');
    const agent = await this.agent(payload.sessionId);
    const matches = message => message?.source?.kind === 'user' && message.source.rpcId === payload.requestId;
    let pending = [...agent.inbox.nextTurn, ...agent.inbox.nextStep].some(matches);
    const evidence = inboxEvidence(agent.session.snapshotEvents(), matches);
    const recoverClaim = !pending && evidence.state === 'claimed' && !!evidence.message && agent.status === 'idle';
    if ((!pending && !recoverClaim) || this.stopGate.isStopped(payload.sessionId)) return { accepted: true, resumed: false };
    const revision = this.stopGate.revision(payload.sessionId);
    const { group, generation } = await this.begin(payload.sessionId, agent);
    if (this.stopGate.revision(payload.sessionId) !== revision || this.stopGate.isStopped(payload.sessionId)) {
      setImmediate(() => void this.settle(payload.sessionId, agent, group, generation));
      return { accepted: true, resumed: false };
    }
    try {
      if (recoverClaim) {
        agent.inbox.splice(evidence.target, Infinity, 0, [evidence.message]);
        pending = true;
      }
      if (!await this.ctx.sessions.flush(agent.session)) throw new Error('Session persistence did not acknowledge recovery');
      if (pending && this.stopGate.revision(payload.sessionId) === revision &&
          !this.stopGate.isStopped(payload.sessionId) && agent.status === 'idle') agent.wakeDriver();
      setImmediate(() => void this.settle(payload.sessionId, agent, group, generation));
      return { accepted: true, resumed: true };
    } catch (error) {
      setImmediate(() => void this.settle(payload.sessionId, agent, group, generation));
      throw error;
    }
  }
  async withExecution(id, operation) {
    const rootID = await this.rootID(id);
    const revision = this.stopGate.revision(rootID);
    const agent = await this.agent(id);
    const rootAgent = rootID === id ? agent : await this.agent(rootID);
    await this.stopGate.resume(rootID, revision);
    const { group, generation } = await this.begin(rootID, rootAgent);
    try { return await operation(agent); }
    finally { setImmediate(() => void this.settle(rootID, rootAgent, group, generation)); }
  }
  async begin(id, agent) {
    if (this.stopGate.isStopped(id)) throw new Error('Session was stopped');
    let group = this.groups.get(id);
    if (group?.closing) {
      await group.closing;
      return this.begin(id, agent);
    }
    if (!group) {
      group = { generation: 0, begin: this.rpc.request('bridge/execution', {
        operation: 'begin', sessionID: id,
        permissionMode: this.ctx.sandboxPolicy.resolve({ session: agent.session }).mode
      }) };
      this.groups.set(id, group);
    }
    const generation = ++group.generation;
    let admitted = false;
    try {
      await group.begin;
      admitted = true;
      if (this.stopGate.isStopped(id)) {
        void this.settle(id, agent, group, generation);
        throw new Error('Session was stopped');
      }
      return { group, generation };
    } catch (error) {
      if (!admitted && this.groups.get(id) === group && group.generation === generation) this.groups.delete(id);
      throw error;
    }
  }
  async endGroup(id, group) {
    const binding = await group.begin;
    group.closing ??= this.rpc.request('bridge/execution', { operation: 'end', sessionID: id,
      ...(Number.isSafeInteger(binding?.executionGeneration) ? { executionGeneration: binding.executionGeneration } : {}) });
    await group.closing;
    if (this.groups.get(id) === group) this.groups.delete(id);
  }
  async settle(id, agent, group, generation) {
    try {
      do {
        await agent.whenIdle();
      } while (await this.ctx.subagents.waitForChildren(agent));
      const children = await this.ctx.subagents.listDescendants(id);
      const owners = [id, ...children.filter(c => c.kind === 'child').map(c => c.id)];
      for (const owner of owners) {
        for (const job of this.ctx.jobs.list(owner).filter(j => j.owner === owner && ['running', 'stopping'].includes(j.status))) {
          let state = job;
          while (['running', 'stopping'].includes(state.status)) state = await this.ctx.jobs.wait(job.id, 30000, owner);
        }
      }
      if (this.groups.get(id) !== group || group.generation !== generation) return;
      await this.endGroup(id, group);
    } catch (error) { process.stderr.write(`DSH execution settlement failed: ${error.message}\n`); }
  }
  async stop(id) {
    await this.stopGate.stop(id);
    const agent = await this.agent(id);
    const children = await this.ctx.subagents.listDescendants(id);
    for (const child of children.filter(c => c.kind === 'child' && c.activity === 'running')) {
      this.ctx.subagents.interrupt(child.id, { kind: 'ancestor', agent });
    }
    await this.ctx.sessionController.cancel({ sessionId: id });
    for (const owner of [id, ...children.filter(c => c.kind === 'child').map(c => c.id)]) {
      for (const job of this.ctx.jobs.list(owner).filter(j => j.owner === owner && ['running', 'stopping'].includes(j.status))) {
        this.ctx.jobs.kill(job.id, owner, 'Stopped by user');
        let state = job;
        while (['running', 'stopping'].includes(state.status)) state = await this.ctx.jobs.wait(job.id, 30000, owner);
      }
    }
    await agent.whenIdle();
    while (await this.ctx.subagents.waitForChildren(agent)) await agent.whenIdle();
    return { accepted: true };
  }
  async stopStatus(id) {
    const agent = await this.agent(id);
    const children = await this.ctx.subagents.listDescendants(id);
    const owners = [id, ...children.filter(child => child.kind === 'child').map(child => child.id)];
    const jobsActive = owners.some(owner => this.ctx.jobs.list(owner)
      .some(job => job.owner === owner && ['running', 'stopping'].includes(job.status)));
    return { stopped: this.stopGate.isStopped(id) && agent.status === 'idle' && !jobsActive
      && !children.some(child => child.kind === 'child' && child.activity === 'running') };
  }
  async listChildren(id, signal) {
    const rows = await this.ctx.subagents.listDescendants(id, signal);
    return { items: rows.filter(row => row.kind === 'child').map(row => ({
      childId: row.id, sessionId: row.mode === 'external' ? undefined : row.id,
      parentSessionId: row.parentId, rootSessionId: id, status: row.activity,
      mode: row.mode, label: row.label
    })) };
  }
}
