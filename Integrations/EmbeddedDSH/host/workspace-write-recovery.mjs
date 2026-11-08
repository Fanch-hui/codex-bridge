import { createHash } from 'node:crypto';

export class WorkspaceWriteRecovery {
  constructor(writes) {
    this.writes = writes;
    this.outcomes = new Map();
    this.queue = Promise.resolve();
  }

  holders(rootID) {
    return [...this.writes.pool(rootID).holders.values()].filter(holder => holder.recovered);
  }

  identity(rootID, holders) {
    const input = JSON.stringify([rootID, holders.map(holder => holder.token).sort()]);
    return `process:${createHash('sha256').update(input).digest('hex')}`;
  }

  snapshot() {
    let read = false, snapshot, failure;
    return () => {
      if (!read) {
        read = true;
        try { snapshot = this.writes.scopes.inspector.table(); } catch (error) { failure = error; }
      }
      if (failure) throw failure;
      return snapshot;
    };
  }

  inspect(rootID, snapshot = this.snapshot()) {
    const holders = this.holders(rootID);
    if (!holders.length) return undefined;
    const states = holders.map(holder => {
      if (!holder.scopeID) return { status: 'unknown', legacy: true, processes: [], canTerminate: false };
      try {
        const record = this.writes.scopes.read(holder.scopeID, rootID, holder.ownerID);
        return { ...this.writes.scopes.inspect(record, snapshot), record };
      } catch { return { status: 'unknown', legacy: true, processes: [], canTerminate: false }; }
    });
    const status = states.some(state => state.status === 'unknown') ? 'unknown'
      : states.some(state => state.status === 'running') ? 'running' : 'exited';
    const executionActive = Boolean(this.writes.sessions.groups?.has(rootID));
    return { recoveryID: this.identity(rootID, holders), kind: states.some(state => state.legacy) ? 'legacy' : 'process',
      sessionId: rootID, status, executionActive,
      message: status === 'running' ? '后台进程仍在运行，可结束后恢复项目。'
        : status === 'unknown' ? '需要核对原会话的后台进程。' : '原会话的后台进程已结束。',
      processes: states.flatMap(state => state.processes), canCheck: true,
      canTerminate: states.some(state => state.canTerminate), canResume: status === 'exited' && !executionActive,
      canConfirmLegacy: status === 'unknown' && !states.some(state => state.hostAlive), states };
  }

  present(item) {
    const { states, visible, ...result } = item;
    const executionActive = Boolean(this.writes.sessions.groups?.has(item.sessionId));
    return { ...result, executionActive,
      canResume: item.status === 'exited' && !executionActive && this.holders(item.sessionId).length === 0 };
  }

  list() {
    const snapshot = this.snapshot();
    const active = [...this.writes.pools.keys()].map(rootID => this.inspect(rootID, snapshot)).filter(Boolean);
    const roots = new Set(active.map(item => item.sessionId));
    const completed = [...this.outcomes.values()].filter(item => item.visible && !roots.has(item.sessionId));
    return { items: [...active, ...completed].map(item => this.present(item)) };
  }

  run(operation) {
    const task = this.queue.then(operation);
    this.queue = task.catch(() => {});
    return task;
  }

  validate(sessionId, recoveryID) {
    if (typeof sessionId !== 'string' || !sessionId || sessionId.length > 1024) {
      throw new Error('A workspace session is required');
    }
    if (recoveryID !== undefined && (typeof recoveryID !== 'string' || !/^process:[0-9a-f]{64}$/.test(recoveryID))) {
      throw new Error('A valid workspace recovery identity is required');
    }
  }

  find(sessionId, recoveryID) {
    this.validate(sessionId, recoveryID);
    const active = this.inspect(sessionId);
    if (active && (recoveryID === undefined || active.recoveryID === recoveryID)) return active;
    if (recoveryID !== undefined) {
      const completed = this.outcomes.get(recoveryID);
      if (completed?.sessionId === sessionId) return completed;
      throw new Error('Workspace recovery has changed; refresh its status');
    }
    return active ?? [...this.outcomes.values()].findLast(item => item.sessionId === sessionId);
  }

  async clear(item) {
    for (const holder of this.holders(item.sessionId)) {
      holder.releasingRecovery = true;
      try { await this.writes.release(item.sessionId, holder.ownerID, holder.token); }
      finally { holder.releasingRecovery = false; }
    }
    const completed = { recoveryID: item.recoveryID, kind: item.kind, sessionId: item.sessionId,
      status: 'exited', message: '原会话的后台进程已结束。', processes: [], canCheck: true,
      canTerminate: false, canResume: true, canConfirmLegacy: false, visible: true };
    this.outcomes.set(item.recoveryID, completed);
    while (this.outcomes.size > 128) this.outcomes.delete(this.outcomes.keys().next().value);
    this.writes.onRecovery(item.sessionId, 'exited');
    return completed;
  }

  async checkNow(sessionId, recoveryID) {
    if (sessionId !== undefined) {
      const item = this.find(sessionId, recoveryID);
      if (!item) return { items: [] };
      const current = item.states && item.status === 'exited' ? await this.clear(item) : item;
      return { items: [this.present(current)] };
    }
    let snapshot = this.snapshot();
    for (const rootID of this.writes.pools.keys()) {
      const item = this.inspect(rootID, snapshot);
      if (item?.status === 'exited') {
        await this.clear(item);
        snapshot = this.snapshot();
      }
    }
    return this.list();
  }

  check({ sessionId, recoveryID } = {}) { return this.run(() => this.checkNow(sessionId, recoveryID)); }

  acknowledge({ sessionId, recoveryID } = {}) {
    return this.run(() => {
      this.validate(sessionId, recoveryID);
      const item = this.find(sessionId, recoveryID);
      if (item?.states) throw new Error('Workspace recovery is still pending');
      if (item) item.visible = false;
      return { items: [] };
    });
  }

  terminate({ sessionId, recoveryID } = {}) {
    return this.run(async () => {
      const item = this.find(sessionId, recoveryID);
      if (item?.status === 'exited' && !item.states) return { items: [this.present(item)] };
      if (!item?.canTerminate) throw new Error('No verified running process is available to stop');
      for (const state of item.states) if (state.canTerminate) await this.writes.scopes.terminate(state.record);
      return this.checkNow(sessionId, item.recoveryID);
    });
  }

  confirmLegacy({ sessionId, recoveryID, confirmed } = {}) {
    return this.run(async () => {
      const item = this.find(sessionId, recoveryID);
      if (item?.status === 'exited' && !item.states) return { items: [this.present(item)] };
      if (confirmed !== true || !item?.canConfirmLegacy || item.canTerminate) {
        throw new Error('The previous process state needs explicit confirmation');
      }
      const completed = await this.clear(item);
      return { items: [this.present(completed)] };
    });
  }
}
