import { setTimeout as delay } from 'node:timers/promises';

const validID = value => typeof value === 'string' && value.length > 0 && value.length <= 1024;
const requestKey = (rootID, ownerID) => JSON.stringify([rootID, ownerID]);

/**
 * Task-long write leases for the owners of connected subagents (`external:<childID>:<requestID>`), offered
 * to the Bridge service as operations that never wait for a lease.
 *
 * `acquire` registers a request with the shared `WorkspaceWrites` pool and answers `granted` when the
 * lease arrives within a short window, `waiting` otherwise. A waiting request stays queued here; the
 * grant (or refusal) is announced as `workspace.externalLease` and the service asks again, which then
 * answers from the pool. So no service request is held open while another writer owns the project, and
 * `release` withdraws a queued request as well as a held lease.
 */
export class ExternalWriteLeases {
  constructor(writes, emit, { grantWindowMs = 250 } = {}) {
    this.writes = writes;
    this.emit = emit;
    this.grantWindowMs = grantWindowMs;
    this.requests = new Map();
  }

  call(payload) {
    const { operation, rootSessionID, ownerID } = payload ?? {};
    if (!validID(rootSessionID) || !validID(ownerID)) throw new Error('A session and write owner are required');
    if (payload.workspaceID) this.writes.domains.bind(rootSessionID, payload.workspaceID);
    switch (operation) {
      case 'acquire': return this.acquire(rootSessionID, ownerID);
      case 'release': return this.release(rootSessionID, ownerID);
      case 'holder': return this.holder(rootSessionID, ownerID);
      case 'recover': return this.recover(rootSessionID, ownerID);
      default: throw new Error('Unknown external write lease operation');
    }
  }

  async acquire(rootID, ownerID) {
    const key = requestKey(rootID, ownerID);
    let entry = this.requests.get(key);
    if (!entry) {
      const holder = this.writes.holder(rootID, ownerID);
      if (holder && !holder.ready) return { state: 'granted' };
      entry = this.begin(key, rootID, ownerID);
      // Only a new request waits for its grant; asking again about a queued one answers at once.
      const window = new AbortController();
      await Promise.race([entry.settled, delay(this.grantWindowMs, undefined, { signal: window.signal }).catch(() => {})]);
      window.abort();
    }
    if (entry.state === 'pending') {
      entry.reported = true;
      return { state: 'waiting' };
    }
    if (this.requests.get(key) === entry) this.requests.delete(key);
    if (entry.state === 'failed') throw entry.error;
    return { state: 'granted' };
  }

  begin(key, rootID, ownerID) {
    const controller = new AbortController();
    const entry = { controller, state: 'pending', reported: false, released: false };
    entry.settled = this.writes.acquire(rootID, ownerID, { signal: controller.signal, persistent: true }).then(
      () => { entry.state = 'granted'; },
      error => { entry.state = 'failed'; entry.error = error; }
    ).then(() => {
      // A granted request needs no entry: the pool now holds the lease for this owner.
      if (entry.state === 'granted' && this.requests.get(key) === entry) this.requests.delete(key);
      if (entry.reported && !entry.released) this.emit(rootID, 'workspace.externalLease', { ownerID, state: entry.state });
    });
    this.requests.set(key, entry);
    return entry;
  }

  async release(rootID, ownerID) {
    const key = requestKey(rootID, ownerID);
    const entry = this.requests.get(key);
    if (entry) {
      this.requests.delete(key);
      entry.released = true;
      entry.controller.abort(new Error('Workspace write request released'));
      await entry.settled;
    }
    const holder = this.writes.holder(rootID, ownerID);
    if (!holder) return { released: false };
    await this.writes.release(rootID, ownerID, holder.token);
    return { released: true };
  }

  holder(rootID, ownerID) {
    return { held: this.writes.holder(rootID, ownerID) !== undefined,
      waiting: this.requests.get(requestKey(rootID, ownerID))?.state === 'pending' };
  }

  /** Re-creates the lease of a dispatched round whose holder record is missing after a restart. */
  async recover(rootID, ownerID) {
    await this.writes.recover(rootID, ownerID);
    return { state: 'granted' };
  }

  dispose() {
    for (const entry of this.requests.values()) {
      entry.released = true;
      entry.controller.abort(new Error('Workspace write coordinator is closed'));
    }
    this.requests.clear();
  }
}
