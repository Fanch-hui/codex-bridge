import { AsyncLocalStorage } from 'node:async_hooks';

// Project execution slots count connected Agents only. Native DSH agents follow the engine's own
// subagent limits; their steps only need an admitted root session.
export class RuntimeAdmission {
  constructor(ctx, sessions) {
    this.ctx = ctx; this.sessions = sessions; this.pools = new Map();
    this.context = new AsyncLocalStorage(); this.closed = false; this.external = new Map();
    this.revoked = new Set(); this.seenExternal = new Set();
    this.holds = new Map(); this.ownerHolds = new Map(); this.pendingHolds = new Map();
  }
  pool(projectID, limit, revision) {
    if (typeof projectID !== 'string' || !projectID ||
        (limit !== undefined && (!Number.isInteger(limit) || limit < 1 || limit > 4)) ||
        (revision !== undefined && (typeof revision !== 'number' || !Number.isFinite(revision) || revision < 0))) {
      throw new Error('Invalid project execution capacity');
    }
    let pool = this.pools.get(projectID);
    if (!pool) {
      if (limit === undefined) throw new Error('Project execution capacity is unavailable');
      pool = { active: new Set(), waiters: [], limit, revision }; this.pools.set(projectID, pool);
    } else if (limit !== undefined &&
        (revision === undefined ? pool.revision === undefined : pool.revision === undefined || revision >= pool.revision)) {
      pool.limit = limit;
      pool.revision = revision;
    }
    return pool;
  }
  reserve({ projectID, limit, revision, owner }) {
    if (this.closed) throw new Error('Execution admission is closed');
    if (this.revoked.has(owner)) throw new Error('Execution owner was cancelled');
    if (typeof owner !== 'string' || !owner) throw new Error('Execution owner is required');
    const pool = this.pool(projectID, limit, revision);
    this.drain(pool);
    return { state: this.tryReserve(pool, owner) ? 'reserved' : 'waiting' };
  }
  tryReserve(pool, owner) {
    if (pool.active.has(owner)) return true;
    if (pool.active.size >= pool.limit || pool.waiters.length) return false;
    pool.active.add(owner);
    if (owner.startsWith('external:')) this.seenExternal.add(owner);
    return true;
  }
  restore(projectID, limit, owners, revision) {
    const pool = this.pool(projectID, limit, revision);
    for (const owner of owners) {
      if (this.seenExternal.has(owner) || this.revoked.has(owner)) continue;
      this.seenExternal.add(owner);
      pool.active.add(owner);
    }
    this.drain(pool);
  }
  release({ projectID, owner }) {
    const pool = this.pools.get(projectID);
    if (!pool) return { state: 'released' };
    pool.active.delete(owner);
    this.drain(pool);
    return { state: 'released' };
  }
  cancel(slot) {
    this.revoked.add(slot.owner);
    this.rejectWaiters(slot, new Error('Execution owner was cancelled'));
    if (!this.hasHolds(slot)) return this.release(slot);
    return { state: 'released' };
  }
  rejectWaiters(slot, error) {
    const pool = this.pools.get(slot.projectID);
    if (pool) for (const waiter of [...pool.waiters]) {
      if (waiter.owner !== slot.owner) continue;
      pool.waiters.splice(pool.waiters.indexOf(waiter), 1);
      waiter.signal?.removeEventListener('abort', waiter.abort);
      waiter.reject(error);
    }
  }
  ownerKey(slot) { return JSON.stringify([slot.projectID, slot.owner]); }
  hasHolds(slot) { return (this.ownerHolds.get(this.ownerKey(slot)) ?? 0) > 0; }
  beginHold(hold) {
    if (typeof hold !== 'string' || !hold) throw new Error('Workspace hold identity is required');
    let pending = this.pendingHolds.get(hold);
    if (!pending) { pending = new Set(); this.pendingHolds.set(hold, pending); }
    const ticket = { invalidated: false }; pending.add(ticket);
    return ticket;
  }
  finishHold(hold, ticket) {
    const pending = this.pendingHolds.get(hold);
    pending.delete(ticket);
    if (!pending.size) this.pendingHolds.delete(hold);
  }
  pin(slot, hold, ticket) {
    if (ticket.invalidated) throw new Error('Workspace hold was released');
    const existing = this.holds.get(hold);
    if (existing) {
      if (this.ownerKey(existing) !== this.ownerKey(slot)) throw new Error('Workspace hold has another owner');
      return;
    }
    this.holds.set(hold, slot);
    const key = this.ownerKey(slot);
    this.ownerHolds.set(key, (this.ownerHolds.get(key) ?? 0) + 1);
  }
  unpin(hold) {
    for (const ticket of this.pendingHolds.get(hold) ?? []) {
      ticket.invalidated = true;
      ticket.abort?.();
    }
    const slot = this.holds.get(hold);
    if (!slot) return;
    this.holds.delete(hold);
    const key = this.ownerKey(slot);
    const count = this.ownerHolds.get(key) - 1;
    if (count) this.ownerHolds.set(key, count); else this.ownerHolds.delete(key);
    const state = slot.suspension;
    if (!count && (state.suspended || this.revoked.has(slot.owner))) {
      this.release(slot);
    }
    this.cleanupExternal(slot, state);
  }
  cleanupExternal(slot, state) {
    const key = this.ownerKey(slot);
    if (this.external.get(key) === state && !state.calls && !this.hasHolds(slot)) this.external.delete(key);
  }
  async suspendExternal(slot, next, options) {
    const pool = this.pool(slot.projectID, slot.limit, slot.revision);
    this.drain(pool);
    const key = this.ownerKey(slot);
    let shared = this.external.get(key);
    if (!shared) { shared = { suspended: 0, calls: 0 }; this.external.set(key, shared); }
    shared.calls++;
    try { return await this.context.run({ ...slot, suspension: shared }, () => this.suspend(next, options)); }
    finally { shared.calls--; this.cleanupExternal(slot, shared); }
  }
  drain(pool) {
    while (!this.closed && pool.waiters.length) {
      let index = pool.waiters.findIndex(waiter => pool.active.has(waiter.owner));
      if (index < 0) {
        if (pool.active.size >= pool.limit) return;
        index = 0;
      }
      const [waiter] = pool.waiters.splice(index, 1);
      waiter.signal?.removeEventListener('abort', waiter.abort);
      if (waiter.signal?.aborted) { waiter.reject(waiter.signal.reason); continue; }
      if (this.revoked.has(waiter.owner)) { waiter.reject(new Error('Execution owner was cancelled')); continue; }
      pool.active.add(waiter.owner); waiter.resolve();
    }
  }
  async acquire(slot, ticket) {
    slot.signal?.throwIfAborted();
    if (this.closed) throw new Error('Execution admission is closed');
    if (this.revoked.has(slot.owner)) throw new Error('Execution owner was cancelled');
    if (ticket?.invalidated) throw new Error('Workspace hold was released');
    const pool = this.pool(slot.projectID);
    if (this.tryReserve(pool, slot.owner)) return;
    try {
      await new Promise((resolve, reject) => {
        const waiter = { ...slot, resolve, reject };
        const withdraw = error => {
          const index = pool.waiters.indexOf(waiter);
          if (index < 0) return;
          pool.waiters.splice(index, 1);
          slot.signal?.removeEventListener('abort', waiter.abort);
          reject(error);
          this.drain(pool);
        };
        waiter.abort = () => withdraw(slot.signal.reason);
        if (ticket) ticket.abort = () => withdraw(new Error('Workspace hold was released'));
        slot.signal?.addEventListener('abort', waiter.abort, { once: true });
        pool.waiters.push(waiter);
        this.drain(pool);
      });
    } finally { if (ticket) ticket.abort = undefined; }
    if (this.revoked.has(slot.owner)) throw new Error('Execution owner was cancelled');
    if (ticket?.invalidated) throw new Error('Workspace hold was released');
  }
  async suspend(next, { hold } = {}) {
    const slot = this.context.getStore();
    if (!slot) return next();
    slot.signal?.throwIfAborted();
    if (this.closed) throw new Error('Execution admission is closed');
    if (this.revoked.has(slot.owner)) throw new Error('Execution owner was cancelled');
    if (slot.yielding && hold === undefined) return next();
    const state = slot.suspension;
    const outer = !slot.yielding;
    const ticket = hold === undefined ? undefined : this.beginHold(hold);
    if (outer) {
      state.suspended++;
      if (state.suspended === 1 && !this.hasHolds(slot)) this.release(slot);
    }
    let result; let succeeded = false;
    try {
      result = await this.context.run({ ...slot, yielding: true }, next);
      succeeded = true;
      return result;
    }
    finally {
      if (outer) state.suspended--;
      const shouldPin = ticket && succeeded && result?.acquired !== false;
      try {
        if (outer || shouldPin) {
          await this.acquire(slot, shouldPin ? ticket : undefined);
          slot.signal?.throwIfAborted();
          if (this.revoked.has(slot.owner)) throw new Error('Execution owner was cancelled');
          if (shouldPin) this.pin(slot, hold, ticket);
        }
      } finally { if (ticket) this.finishHold(hold, ticket); }
    }
  }
  start() {
    this.removeStep = this.ctx.on('agent/pre-step', async ({ agent }, next) => {
      const rootID = await this.sessions.rootID(agent.session.id);
      const group = this.sessions.groups.get(rootID);
      if (!group) throw new Error('Agent execution has no admitted root');
      await group.begin;
      return next();
    }, { global: true });
  }
  dispose() {
    this.closed = true;
    this.removeStep?.();
    for (const pool of this.pools.values()) for (const waiter of pool.waiters.splice(0)) {
      waiter.signal?.removeEventListener('abort', waiter.abort);
      waiter.reject(new Error('Execution admission is closed'));
    }
  }
}
