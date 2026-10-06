import { fault, text } from './errors.mjs';
import { hash } from './protocol.mjs';
import { mapNativeEvent, promptRequestID } from './event-mapping.mjs';

const requestFingerprint = params => hash(JSON.stringify([params.projectPath, params.sessionID ?? null, params.text, params.modelID ?? null, params.effort ?? null, params.accessMode]));
const TERMINAL = new Set(['completed', 'failed', 'cancelled']);
export class Runs {
  constructor(native, grants, store) {
    this.native = native;
    this.grants = grants;
    this.store = store;
    this.turns = new Map();
    this.starts = new Map();
    this.disconnects = new Map();
    this.sessionAdmissions = new Set();
    this.terminals = new Map();
    this.recovered = new Set();
    this.cancellations = new Map();
  }
  owned(requestID, key) {
    const run = this.store.get(text(requestID, 'requestID'));
    if (!run || run.owner !== key) throw fault('run_not_found', 'Bridge request does not belong to this connection');
    return run;
  }
  async start(params, key) {
    const requestID = text(params.requestID, 'requestID');
    const fingerprint = requestFingerprint(params);
    const existing = this.store.get(requestID);
    if (existing) {
      const run = this.owned(requestID, key);
      if (run.fingerprint !== fingerprint) throw fault('request_identity_conflict', 'Request ID refers to different native input');
      await this.recover(run);
      return this.view(run);
    }
    const starting = this.starts.get(requestID);
    if (starting) {
      if (starting.owner !== key || starting.fingerprint !== fingerprint) throw fault('request_identity_conflict', 'Request ID refers to another admission');
      return starting.promise;
    }
    if (params.sessionID && this.sessionAdmissions.has(params.sessionID)) throw fault('native_session_busy', 'Session admission is already in progress');
    if (params.sessionID) this.sessionAdmissions.add(params.sessionID);
    const work = this.admit(params, key).finally(() => { this.starts.delete(requestID); this.sessionAdmissions.delete(params.sessionID); });
    this.starts.set(requestID, { owner: key, fingerprint, promise: work });
    return work;
  }
  async admit(params, key) {
    if (params.accessMode !== 'full') throw fault('read_only_unsupported', 'Native Desktop execution requires full access');
    if (params.attachments?.length || params.skills?.length || params.mcpServers?.length) throw fault('input_unsupported', 'Native Desktop execution accepts text only');
    text(params.text, 'prompt');
    const root = await this.grants.require(key, params.projectPath);
    if (params.sessionID) {
      const { summary } = await this.grants.requireSession(key, root, params.sessionID, this.native);
      if (summary.running) throw fault('native_session_busy', 'Native session is already running');
      if ([...this.store.runs.values()].some(run => run.sessionID === params.sessionID && !TERMINAL.has(run.status))) throw fault('native_session_busy', 'Bridge already owns a request in this session');
    }
    const created = await this.native.create(root, params.sessionID);
    const sessionID = created.sessionId;
    if (params.modelID) await this.native.selectModel(sessionID, params);
    const run = { requestID: params.requestID, fingerprint: requestFingerprint(params), sessionID, owner: key, projectPath: root, status: 'running', cursor: 0, nativeCursor: 0, events: [], createdAt: Date.now(), pendingInput: { text: params.text } };
    this.store.runs.set(run.requestID, run);
    await this.store.save();
    try {
      await this.native.prompt(sessionID, run.requestID, params.text);
      delete run.pendingInput;
      this.recovered.add(run.requestID);
      await this.store.save();
      return this.view(run);
    } catch (error) {
      this.append(run, 'failed', { message: error.message });
      await this.store.save();
      throw error;
    }
  }
  view(run) { return { requestID: run.requestID, sessionID: run.sessionID, status: run.status, cursor: run.cursor }; }
  append(run, eventType, data) {
    const event = { requestID: run.requestID, eventType, data, cursor: ++run.cursor };
    run.events.push(event);
    if (TERMINAL.has(eventType)) {
      run.status = eventType;
      this.terminals.get(run.requestID)?.();
      this.terminals.delete(run.requestID);
    }
    return event;
  }
  consume(sessionID, event) {
    let changed = false;
    if (event.type === 'turn/start') this.turns.set(sessionID, event.data.turn);
    for (const run of this.store.runs.values()) {
      if (run.sessionID !== sessionID || TERMINAL.has(run.status) || event.seq <= run.nativeCursor) continue;
      run.nativeCursor = event.seq;
      changed = true;
      if (promptRequestID(event) === run.requestID) { run.turn = this.turns.get(sessionID); delete run.pendingInput; }
      const turn = event.data?.turn ?? this.turns.get(sessionID);
      if (run.turn === undefined || run.turn !== turn) continue;
      for (const mapped of mapNativeEvent(event)) this.append(run, mapped.eventType, mapped.data);
    }
    return changed;
  }
  onEvent(session, event) {
    return this.consume(session.id, event) ? this.store.save() : Promise.resolve();
  }
  async recover(run) {
    if (TERMINAL.has(run.status) || this.recovered.has(run.requestID)) return;
    const history = await this.native.records(run.sessionID);
    let accepted = false;
    for (const record of history.records) {
      const event = record.event ?? record;
      if (promptRequestID(event) === run.requestID) accepted = true;
      this.consume(run.sessionID, event);
    }
    if (!accepted && run.pendingInput) {
      try {
        await this.grants.require(run.owner, run.projectPath);
        const summary = await this.native.summary(run.sessionID);
        if (summary?.running) throw fault('native_session_busy', 'Native session became busy before recovered admission');
        await this.native.create(run.projectPath, run.sessionID);
        await this.native.prompt(run.sessionID, run.requestID, run.pendingInput.text);
      } catch (error) { this.append(run, 'failed', { message: error.message }); }
    }
    delete run.pendingInput;
    this.recovered.add(run.requestID);
    await this.store.save();
  }
  async observe(params, key) {
    const run = this.owned(params.requestID, key);
    this.reconnected(key);
    await this.recover(run);
    const cursor = params.cursor ?? 0;
    if (!Number.isSafeInteger(cursor) || cursor < 0 || cursor > run.cursor) throw fault('invalid_cursor', 'Invalid Bridge event cursor');
    return { ...this.view(run), events: run.events.filter(event => event.cursor > cursor) };
  }
  currentRun(agent) {
    return [...this.store.runs.values()].find(run => run.sessionID === agent.id && !TERMINAL.has(run.status) && run.turn !== undefined && run.turn === this.turns.get(agent.id));
  }
  async cancel(params, key) {
    this.owned(params.requestID, key);
    if (this.cancellations.has(params.requestID)) return this.cancellations.get(params.requestID);
    const work = this.cancelRun(params, key).finally(() => this.cancellations.delete(params.requestID));
    this.cancellations.set(params.requestID, work);
    return work;
  }
  async cancelRun(params, key) {
    const run = this.owned(params.requestID, key);
    if (TERMINAL.has(run.status)) return this.view(run);
    const agent = this.native.agent(run.sessionID);
    const pending = [...(agent?.inbox?.nextTurn ?? []), ...(agent?.inbox?.nextStep ?? [])].find(message => message.source?.rpcId === run.requestID);
    if (pending) {
      agent.inbox.remove(pending.id);
      this.append(run, 'cancelled', { reason: 'queued-input-removed' });
    } else if (agent && this.currentRun(agent) === run) {
      const ended = new Promise(resolve => this.terminals.set(run.requestID, resolve));
      try { await this.native.cancel(run.sessionID); await ended; }
      finally { this.terminals.delete(run.requestID); }
    } else {
      await this.recover(run);
      if (!TERMINAL.has(run.status)) throw fault('run_cancel_unconfirmed', 'Native request cancellation could not be confirmed');
    }
    await this.store.save();
    return this.view(run);
  }
  async steer(params, key) {
    const run = this.owned(params.requestID, key);
    const agent = this.native.agent(run.sessionID);
    if (!agent || this.currentRun(agent) !== run) throw fault('run_not_active', 'Request is no longer active');
    await this.native.prompt(run.sessionID, text(params.inputID, 'inputID'), text(params.text, 'prompt'), 'steer');
    return { accepted: true };
  }
  disconnected(key) {
    if (this.disconnects.has(key)) return;
    const timer = setTimeout(() => {
      this.disconnects.delete(key);
      void this.cancelOwned(key).catch(() => {});
    }, 30000);
    timer.unref?.();
    this.disconnects.set(key, timer);
  }
  reconnected(key) { clearTimeout(this.disconnects.get(key)); this.disconnects.delete(key); }
  async cancelOwned(key) {
    for (const run of this.store.runs.values()) if (run.owner === key && !TERMINAL.has(run.status)) await this.cancel({ requestID: run.requestID }, key);
  }
  async close() {
    for (const timer of this.disconnects.values()) clearTimeout(timer);
    this.disconnects.clear();
    const owners = new Set([...this.store.runs.values()].filter(run => !TERMINAL.has(run.status)).map(run => run.owner));
    await Promise.all([...owners].map(key => this.cancelOwned(key)));
  }
}
