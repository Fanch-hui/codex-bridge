const validID = value => typeof value === 'string' && value.length > 0 && value.length <= 1024;

/**
 * Keeps a root session's execution open on behalf of the Bridge service while it still has subagent work
 * to dispatch or follow (queued rounds, running tasks), even though the root's own agent is idle.
 *
 * A hold is a `sessions.begin` that is settled again on release, remembered under the caller's `holdID`.
 * The execution group is not reference counted: whoever began last settles it. So `hold` is idempotent
 * while the group it began is still the live one, and begins again once another party's settlement has
 * closed it; the service repeats the request while it needs the root. A hold dies with the engine process.
 */
export class ExternalRootHolds {
  constructor(sessions) {
    this.sessions = sessions;
    this.holds = new Map();
  }

  call(payload) {
    const { operation, rootSessionID, holdID } = payload ?? {};
    if (!validID(rootSessionID)) throw new Error('A root session is required');
    if (operation === 'status') return this.status(rootSessionID);
    if (!validID(holdID)) throw new Error('A hold identity is required');
    switch (operation) {
      case 'hold': return this.hold(rootSessionID, holdID);
      case 'release': return this.release(rootSessionID, holdID);
      default: throw new Error('Unknown external root operation');
    }
  }

  status(rootID) {
    return { stopped: this.sessions.stopGate.isStopped(rootID) };
  }

  async hold(rootID, holdID) {
    const existing = this.holds.get(holdID);
    if (existing && existing.rootID !== rootID) throw new Error('Hold identity belongs to another session');
    if (existing && this.sessions.groups.get(rootID) === existing.group && !existing.group.closing) return { held: true };
    if (this.sessions.stopGate.isStopped(rootID)) return this.stopped(holdID);
    if (await this.sessions.rootID(rootID) !== rootID) throw new Error('The execution owner must be a root session');
    try {
      const agent = await this.sessions.agent(rootID);
      const { group, generation } = await this.sessions.begin(rootID, agent);
      this.holds.set(holdID, { rootID, agent, group, generation });
      return { held: true };
    } catch (error) {
      if (this.sessions.stopGate.isStopped(rootID)) return this.stopped(holdID);
      throw error;
    }
  }

  stopped(holdID) {
    this.holds.delete(holdID);
    return { held: false, reason: 'stopped' };
  }

  release(rootID, holdID) {
    const hold = this.holds.get(holdID);
    if (!hold || hold.rootID !== rootID) return { released: false };
    this.holds.delete(holdID);
    // Settlement waits for the root to go idle; the service does not wait for it.
    void this.sessions.settle(rootID, hold.agent, hold.group, hold.generation);
    return { released: true };
  }
}
