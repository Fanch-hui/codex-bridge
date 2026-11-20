// Pools retain root ownership for cancellation and recovery; domains serialize writers sharing a directory.
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
  drain(rootID) {
    const roots = this.roots(rootID);
    const occupied = roots.filter(id => {
      const pool = this.writes.pool(id);
      return pool.holders.size || pool.clearing;
    });
    if (occupied.length) {
      for (const id of occupied) {
        const pool = this.writes.pool(id);
        // A waiter in another root must also retire an idle retained interpreter.
        if (roots.some(other => this.writes.pool(other).waiters.length || this.writes.pool(other).quiescence.length)) pool.notifyWhenFree = true;
        this.writes.drainRoot(id);
      }
      return;
    }
    const waiting = roots.filter(id => this.writes.pool(id).waiters.length)
      .sort((a, b) => this.writes.pool(a).waiters[0].order - this.writes.pool(b).waiters[0].order);
    if (waiting.length) this.writes.drainRoot(waiting[0]);
    else for (const id of roots) this.writes.drainRoot(id);
  }
}
