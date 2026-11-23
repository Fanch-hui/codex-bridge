// Pools retain root ownership for cancellation and recovery; domains coordinate writers sharing a directory.
// Shared holders (native DSH tool calls) run together; an exclusive holder needs the directory to itself.
// Waiters are admitted in arrival order, so a later shared request does not overtake a queued exclusive one.
const idleRetained = holder => holder.refs === 0 && holder.retained;

export class WorkspaceWriteDomains {
  constructor(writes) { this.writes = writes; this.bindings = new Map(); }
  key(rootID) { return this.bindings.get(rootID) ?? rootID; }
  bind(rootID, workspaceID) {
    if (typeof workspaceID !== 'string' || !workspaceID) throw new Error('Workspace identity is required');
    const previous = this.bindings.get(rootID);
    if (previous && previous !== workspaceID && this.busy(rootID)) {
      throw new Error('An active workspace binding cannot change');
    }
    this.bindings.set(rootID, workspaceID);
  }
  roots(rootID) {
    const key = this.key(rootID);
    return [...this.writes.pools.keys()].filter(id => this.key(id) === key);
  }
  busy(rootID) {
    return this.roots(rootID).some(id => {
      const pool = this.writes.pool(id);
      return pool.holders.size || pool.waiters.length || pool.clearing;
    });
  }
  hasExclusiveWaiter(rootID) {
    return this.roots(rootID).some(id => this.writes.pool(id).waiters.some(waiter => !waiter.shared));
  }
  firstWaiter(roots) {
    let first;
    for (const id of roots) {
      const waiter = this.writes.pool(id).waiters[0];
      if (waiter && (!first || waiter.order < first.waiter.order)) first = { id, waiter };
    }
    return first;
  }
  holders(roots) { return roots.flatMap(id => [...this.writes.pool(id).holders.values()]); }
  admits(waiter, holders) {
    return waiter.shared ? holders.every(holder => holder.shared) : holders.length === 0;
  }
  drain(rootID) {
    if (this.writes.disposed) return;
    const roots = this.roots(rootID);
    if (roots.some(id => this.writes.pool(id).clearing)) return;
    for (let head = this.firstWaiter(roots); head && this.admits(head.waiter, this.holders(roots));
      head = this.firstWaiter(roots)) {
      this.writes.grant(head.id);
    }
    const head = this.firstWaiter(roots);
    if (!this.holders(roots).length) {
      if (head) return;
      for (const id of roots) {
        const pool = this.writes.pool(id);
        if (pool.notifyWhenFree || pool.quiescence.length) this.writes.announceFree(id);
      }
      return;
    }
    // Idle interpreters and terminals give way to an exclusive writer, a stop, or a merge waiting for the directory.
    const exclusiveWaiting = head && !head.waiter.shared;
    const freeRequested = roots.some(id => this.writes.pool(id).notifyWhenFree);
    for (const id of roots) {
      const pool = this.writes.pool(id);
      if (!pool.holders.size || ![...pool.holders.values()].every(idleRetained)) continue;
      if (exclusiveWaiting || freeRequested || pool.quiescence.length) this.writes.clearRetained(id);
    }
  }
}
