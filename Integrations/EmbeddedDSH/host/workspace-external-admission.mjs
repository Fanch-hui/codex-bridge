import { setTimeout as delay } from 'node:timers/promises';

const terminal = new Set(['completed', 'failed', 'interrupted', 'cancelled']);
// 'tool': Bridge gates each writing tool call of the provider; 'task': the whole task holds the lease.
const writeScopes = new Set(['task', 'tool']);

export class ExternalWorkspaceAdmission {
  constructor(ctx, rpc, sessions, writes, persist) {
    this.ctx = ctx;
    this.rpc = rpc;
    this.sessions = sessions;
    this.writes = writes;
    this.persist = persist;
  }

  owner(binding) { return `external:${binding.childID}:${binding.requestID}`; }

  async recoverBindings(bindings) {
    for (const binding of bindings) {
      if (binding.admission === 'waiting' || binding.admission === 'attached' || binding.workspaceMode === 'read-only' ||
          binding.workspaceMode === 'isolated' || binding.writeScope === 'tool' || terminal.has(binding.state)) continue;
      await this.writes.recover(binding.rootSessionID, this.owner(binding));
    }
  }

  async readOnly(binding) {
    const root = await this.sessions.agent(binding.rootSessionID);
    return this.ctx.sandboxPolicy.resolve({ session: root.session }).mode === 'read-only';
  }

  async reserve(binding, signal) {
    for (;;) {
      signal?.throwIfAborted();
      const receipt = await this.rpc.request('bridge/subagent', { operation: 'reserve',
        rootSessionID: binding.rootSessionID, childID: binding.childID, requestID: binding.requestID,
        ...(binding.installationID ? { installationID: binding.installationID } : {}) });
      if (receipt?.state === 'reserved') {
        const scope = receipt.writeScope ?? 'task';
        if (!writeScopes.has(scope)) throw new Error('Bridge returned an invalid workspace write scope');
        binding.writeScope = scope;
        binding.reservationHeld = true;
        delete binding.waitingReason;
        await this.persist();
        return;
      }
      if (receipt?.state !== 'waiting') throw new Error('Bridge returned an invalid workspace reservation');
      if (binding.waitingReason !== 'capacity') {
        binding.waitingReason = 'capacity';
        await this.persist();
      }
      await delay(200, undefined, { signal });
    }
  }

  async releaseReservation(binding) {
    const receipt = await this.rpc.request('bridge/subagent', { operation: 'releaseReservation',
      rootSessionID: binding.rootSessionID, childID: binding.childID, requestID: binding.requestID });
    if (receipt?.state === 'released') {
      delete binding.reservationHeld;
      await this.persist();
    } else if (!['active', 'unknown'].includes(receipt?.state)) {
      throw new Error('Bridge returned an invalid workspace reservation release');
    }
    return receipt.state;
  }

  async begin(binding, dispatch, signal) {
    const ownerID = this.owner(binding);
    let token;
    let dispatched = false;
    let requestedReservation = false;
    try {
      if (await this.readOnly(binding)) {
        binding.workspaceMode = 'read-only';
        delete binding.writeScope;
      } else {
        binding.workspaceMode = 'shared';
        requestedReservation = true;
        await this.reserve(binding, signal);
        // Bridge gates tool-scoped writers around each writing tool call, so no task-long lease is taken.
        if (binding.writeScope !== 'tool') {
          token = await this.writes.acquire(binding.rootSessionID, ownerID, { signal, persistent: true });
        }
      }
      signal?.throwIfAborted();
      binding.admission = 'dispatching';
      await this.persist();
      signal?.throwIfAborted();
      dispatched = true;
      const receipt = await dispatch();
      if (!receipt?.taskID) throw new Error('Bridge returned an invalid subagent receipt');
      Object.assign(binding, { taskID: receipt.taskID, state: receipt.state,
        admission: 'accepted', ...(receipt.workspaceMode ? { workspaceMode: receipt.workspaceMode } : {}),
        ...(receipt.workspaceReason ? { workspaceReason: receipt.workspaceReason } : {}) });
      delete binding.pendingPrompt;
      delete binding.pendingOperation;
      await this.persist();
      if (receipt.workspaceMode === 'isolated' && token) await this.writes.release(binding.rootSessionID, ownerID, token);
      if (receipt.workspaceMode !== 'isolated' && binding.reservationHeld) {
        try { await this.releaseReservation(binding); }
        catch (error) { process.stderr.write(`DSH workspace reservation recovery failed: ${error.message}\n`); }
      }
      return receipt;
    } catch (error) {
      if (!dispatched) {
        binding.admission = 'cancelled';
        binding.state = 'cancelled';
        delete binding.pendingPrompt;
        delete binding.pendingOperation;
        await this.persist();
        if (token) await this.writes.release(binding.rootSessionID, ownerID, token);
        if (requestedReservation) await this.releaseReservation(binding);
      } else {
        // Keep Bridge's answer: if reconciliation later finds no task, this is the reason.
        binding.admission = 'unknown';
        binding.dispatchError = String(error?.message || error).slice(0, 2000);
        await this.persist();
      }
      throw error;
    }
  }

  async release(binding) {
    const ownerID = this.owner(binding);
    const holder = this.writes.holder(binding.rootSessionID, ownerID);
    if (holder) await this.writes.release(binding.rootSessionID, ownerID, holder.token);
    if (binding.reservationHeld) await this.releaseReservation(binding);
  }

  async reconcile(binding) {
    const holder = this.writes.holder(binding.rootSessionID, this.owner(binding));
    if (!holder && !binding.reservationHeld && !['dispatching', 'unknown'].includes(binding.admission)) return;
    const state = await this.rpc.request('bridge/subagent', { operation: 'probe',
      rootSessionID: binding.rootSessionID, childID: binding.childID, requestID: binding.requestID });
    if (state?.state === 'absent' || state?.state === 'terminal' ||
        (state?.state === 'active' && state?.workspaceMode === 'isolated')) {
      if (holder) await this.release(binding);
      else if (binding.reservationHeld && ['absent', 'terminal'].includes(state?.state)) await this.releaseReservation(binding);
    } else if (state?.state === 'active' && state?.workspaceMode === 'shared' && binding.reservationHeld) {
      await this.releaseReservation(binding);
    }
    return state;
  }
}
