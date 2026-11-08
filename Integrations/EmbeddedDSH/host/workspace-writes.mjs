import { randomUUID } from 'node:crypto';
import { AsyncLocalStorage } from 'node:async_hooks';
import { readFile, rename, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { WorkspaceProcessScopes } from './workspace-process-scopes.mjs';
import { trackWorkspaceSpawn, trackWorkspaceTerminal } from './workspace-process-launch.mjs';
import { WorkspaceWriteRecovery } from './workspace-write-recovery.mjs';

// These tools only observe data or control work that has its own admission.
const nonWritingTools = new Set([
  'read', 'read_image', 'glob', 'grep', 'web_search', 'web_fetch', 'ask_user_question',
  'todo_write', 'job_output', 'job_list', 'job_kill', 'terminal_read', 'terminal_list', 'subagent', 'subagent_fork',
  'send_message', 'interrupt_agent', 'list_agents', 'list_subagent_models',
  'bridge_agents', 'bridge_agent_models', 'bridge_delegate', 'bridge_send_agent',
  'bridge_stop_agent', 'bridge_agent_changes', 'spawn_teammate', 'team_send_message',
  'delegate_agent', 'list_child_agents', 'send_agent_message', 'stop_child_agent',
  'team_list_agents', 'team_interrupt_agent', 'wait_agent', 'team_task_create',
  'team_task_list', 'team_task_get', 'team_task_update'
]);

const activeJob = job => job.status === 'running' || job.status === 'stopping';
const validID = value => typeof value === 'string' && value.length > 0 && value.length <= 1024;
const workflowBusy = () => new Error('A workflow is using this workspace. Finish its current write step before starting another writing agent.');
const recoveryRequired = () => new Error('A previous workspace write could still be running. Its process needs to be checked before writing can resume.');

export class WorkspaceWrites {
  constructor(ctx, sessions, home, onAvailable = () => {}, onRecovery = () => {}) {
    this.ctx = ctx;
    this.sessions = sessions;
    this.path = join(home, 'bridge-workspace-writes.json');
    this.onAvailable = onAvailable;
    this.onRecovery = onRecovery;
    this.scopes = new WorkspaceProcessScopes(home);
    this.recovery = new WorkspaceWriteRecovery(this);
    this.pools = new Map();
    this.processContext = new AsyncLocalStorage();
    this.terminalRuntime = { release: async agent => {
      const terminals = this.ctx.get?.('terminals');
      if (!terminals) throw new Error('Terminal process status is unavailable');
      for (const session of terminals.list(agent)) await terminals.kill(agent, session.sessionId);
      if (terminals.hasOwnerActivity(agent)) throw new Error('Terminal processes are still stopping');
    } };
    this.persistQueue = Promise.resolve();
    this.disposed = false;
  }

  pool(rootID) {
    let pool = this.pools.get(rootID);
    if (!pool) {
      pool = { holders: new Map(), waiters: [], revoked: new Set(), processes: new Set(), settlements: new Set() };
      this.pools.set(rootID, pool);
    }
    return pool;
  }

  async start() {
    await this.scopes.start();
    try {
      const rows = JSON.parse(await readFile(this.path, 'utf8'));
      if (!Array.isArray(rows) || rows.some(row => !validID(row.rootID) || !validID(row.ownerID) || !validID(row.token))) {
        throw new Error('Invalid workspace write lease index');
      }
      for (const row of rows) {
        const pool = this.pool(row.rootID);
        if (pool.holders.has(row.ownerID)) throw new Error('Duplicate workspace write lease');
        pool.holders.set(row.ownerID, { ...row, persistent: true, refs: 1, workflows: 0,
          recovered: row.ownerID.startsWith('tool:') });
      }
    } catch (error) { if (error.code !== 'ENOENT') throw error; }
    const subprocess = this.ctx.get?.('subprocess');
    if (subprocess) {
      const original = subprocess.spawn;
      const context = this.processContext;
      const scopes = this.scopes;
      const wrapped = function (...args) {
        const scope = context.getStore();
        const handle = scope?.record ? trackWorkspaceSpawn(scopes, scope.record, () => original.apply(this, args))
          : original.apply(this, args);
        if (scope) scope.add(handle);
        return handle;
      };
      subprocess.spawn = wrapped;
      this.removeSpawn = () => { if (subprocess.spawn === wrapped) subprocess.spawn = original; };
      if (typeof subprocess.spawnTerminal === 'function') {
        const originalTerminal = subprocess.spawnTerminal;
        const wrappedTerminal = function (...args) {
          const scope = context.getStore();
          return scope?.record ? trackWorkspaceTerminal(scopes, scope.record, () => originalTerminal.apply(this, args))
            : originalTerminal.apply(this, args);
        };
        subprocess.spawnTerminal = wrappedTerminal;
        this.removeTerminal = () => { if (subprocess.spawnTerminal === wrappedTerminal) subprocess.spawnTerminal = originalTerminal; };
      }
    }
    this.removeExecute = this.ctx.on('tools/execute', (exec, next) => this.execute(exec, next),
      { global: true, prepend: true });
    await this.recoveryCheck();
    this.recoveryTimer = setInterval(() => this.pollProcesses(), 2000);
    this.recoveryTimer.unref();
  }

  pollProcesses() {
    const records = [];
    let hasRecovery = false;
    for (const pool of this.pools.values()) for (const holder of pool.holders.values()) {
      if (holder.recovered) hasRecovery = true;
      else if (holder.scopeRecord?.ranges.length) records.push(holder.scopeRecord);
    }
    if (records.length) {
      try {
        const snapshot = this.scopes.inspector.table();
        for (const record of records) {
          try { this.scopes.refresh(record, snapshot); }
          catch (error) { process.stderr.write(`Workspace process tracking failed: ${error.message}\n`); }
        }
      } catch (error) { process.stderr.write(`Workspace process tracking failed: ${error.message}\n`); }
    }
    if (hasRecovery) {
      void this.recoveryCheck().catch(error => process.stderr.write(`Workspace recovery check failed: ${error.message}\n`));
    }
  }

  persist() {
    const task = this.persistQueue.then(async () => {
      const rows = [];
      for (const [rootID, pool] of this.pools) for (const holder of pool.holders.values()) {
        if (holder.persistent) rows.push({ rootID, ownerID: holder.ownerID, token: holder.token,
          ...(holder.scopeID ? { scopeID: holder.scopeID } : {}) });
      }
      const temporary = `${this.path}.tmp`;
      await writeFile(temporary, `${JSON.stringify(rows)}\n`, { mode: 0o600 });
      await rename(temporary, this.path);
    });
    this.persistQueue = task.catch(() => {});
    return task;
  }

  async recover(rootID, ownerID) {
    this.validate(rootID, ownerID);
    const pool = this.pool(rootID);
    if (pool.revoked.has(ownerID)) throw new Error('Workspace write owner was cancelled');
    const existing = pool.holders.get(ownerID);
    if (existing) return existing.token;
    const holder = { ownerID, token: randomUUID(), persistent: true, refs: 1, workflows: 0 };
    pool.holders.set(ownerID, holder);
    try { await this.persist(); } catch (error) { pool.holders.delete(ownerID); throw error; }
    return holder.token;
  }

  validate(rootID, ownerID) {
    if (!validID(rootID) || !validID(ownerID)) throw new Error('A session and write owner are required');
  }

  async acquire(rootID, ownerID, { signal, persistent = false, reentrant = false, retainedAgent, retainedRuntime,
    allowWorkflowWait = false } = {}) {
    this.validate(rootID, ownerID);
    if (this.disposed) throw new Error('Workspace write coordinator is closed');
    signal?.throwIfAborted();
    const pool = this.pool(rootID);
    if (pool.revoked.has(ownerID)) throw new Error('Workspace write owner was cancelled');
    if (this.requiresRecovery(rootID)) throw recoveryRequired();
    const owned = pool.holders.get(ownerID);
    if (owned && (owned.refs > 0 || !owned.retained)) {
      if (owned.ready) await owned.ready;
      signal?.throwIfAborted();
      if (pool.holders.get(ownerID) !== owned) throw new Error('Workspace write lease is unavailable');
      if (reentrant) owned.refs++;
      return owned.token;
    }
    if (retainedAgent && !pool.waiters.length && !pool.clearing && pool.holders.size === 1) {
      const holder = [...pool.holders.values()][0];
      if (holder.refs === 0 && holder.retained?.agent === retainedAgent &&
          holder.retained.runtimes.size === 1 && holder.retained.runtimes.has(retainedRuntime)) {
        const previousOwner = holder.ownerID;
        pool.holders.delete(previousOwner);
        holder.ownerID = ownerID;
        holder.refs = 1;
        pool.holders.set(ownerID, holder);
        if (holder.persistent) {
          holder.ready = this.persist();
          try { await holder.ready; } catch (error) {
            pool.holders.delete(ownerID);
            holder.ownerID = previousOwner;
            holder.refs = 0;
            pool.holders.set(previousOwner, holder);
            throw error;
          } finally { holder.ready = undefined; }
        }
        return holder.token;
      }
    }
    if (!allowWorkflowWait && [...pool.holders.values()].some(holder => holder.workflows > 0)) {
      throw workflowBusy();
    }
    return new Promise((resolve, reject) => {
      const waiter = { ownerID, persistent, signal, resolve, reject, allowWorkflowWait };
      waiter.abort = () => {
        const index = pool.waiters.indexOf(waiter);
        if (index >= 0) pool.waiters.splice(index, 1);
        reject(signal.reason ?? new Error('Workspace write request cancelled'));
      };
      signal?.addEventListener('abort', waiter.abort, { once: true });
      pool.waiters.push(waiter);
      this.drain(rootID);
    });
  }

  drain(rootID) {
    const pool = this.pool(rootID);
    if (this.disposed || pool.clearing || (!pool.waiters.length && !pool.notifyWhenFree)) return;
    if (pool.holders.size) {
      if (pool.holders.size !== 1) return;
      const holder = [...pool.holders.values()][0];
      if (holder.refs || !holder.retained) return;
      pool.clearing = true;
      this.cleanupRetained(holder).then(async () => {
        const retained = holder.retained;
        holder.retained = undefined;
        try { await this.release(rootID, holder.ownerID, holder.token); }
        catch (error) { holder.retained = retained; throw error; }
        pool.clearing = false;
        this.drain(rootID);
      }).catch(error => {
        pool.clearing = false;
        for (const waiter of pool.waiters.splice(0)) {
          waiter.signal?.removeEventListener('abort', waiter.abort);
          waiter.reject(error);
        }
      });
      return;
    }
    if (!pool.waiters.length) {
      pool.notifyWhenFree = false;
      this.onAvailable(rootID);
      return;
    }
    const waiter = pool.waiters.shift();
    waiter.signal?.removeEventListener('abort', waiter.abort);
    if (waiter.signal?.aborted) { waiter.reject(waiter.signal.reason); this.drain(rootID); return; }
    const holder = { ownerID: waiter.ownerID, token: randomUUID(), persistent: waiter.persistent, refs: 1, workflows: 0 };
    pool.holders.set(waiter.ownerID, holder);
    const ready = holder.persistent ? this.persist() : Promise.resolve();
    holder.ready = ready;
    ready.then(() => {
      holder.ready = undefined;
      if (pool.revoked.has(waiter.ownerID)) {
        const reject = () => waiter.reject(new Error('Workspace write owner was cancelled'));
        if (pool.holders.get(waiter.ownerID) === holder) void this.release(rootID, holder.ownerID, holder.token).then(reject, waiter.reject);
        else reject();
        return;
      }
      if (waiter.signal?.aborted) {
        if (pool.holders.get(waiter.ownerID) === holder) {
          void this.release(rootID, holder.ownerID, holder.token).then(() => waiter.reject(waiter.signal.reason), waiter.reject);
        } else waiter.reject(waiter.signal.reason);
      } else waiter.resolve(holder.token);
    }, error => { holder.ready = undefined; pool.holders.delete(holder.ownerID); waiter.reject(error); this.drain(rootID); });
  }

  async release(rootID, ownerID, token) {
    this.validate(rootID, ownerID);
    const pool = this.pool(rootID);
    const holder = pool.holders.get(ownerID);
    if (!holder || holder.token !== token) throw new Error('Workspace write lease is unavailable');
    if (holder.recovered && !holder.releasingRecovery) throw recoveryRequired();
    if (holder.refs > 1) { holder.refs--; return; }
    if (holder.retained) { holder.refs = 0; this.drain(rootID); return; }
    if (holder.persistent) {
      holder.persistent = false;
      try { await this.persist(); } catch (error) { holder.persistent = true; throw error; }
    }
    pool.holders.delete(ownerID);
    if (holder.scopeRecord) holder.scopeRecord.active = false;
    if (holder.scopeID) {
      try { this.scopes.remove(holder.scopeID); }
      catch (error) { process.stderr.write(`Workspace process metadata cleanup failed: ${error.message}\n`); }
    }
    this.drain(rootID);
  }

  holder(rootID, ownerID) { return this.pool(rootID).holders.get(ownerID); }

  requiresRecovery(rootID) { return [...this.pool(rootID).holders.values()].some(holder => holder.recovered); }

  retain(holder, agent, runtime) {
    if (!holder.retained) holder.cleanup = undefined;
    holder.retained ??= { agent, runtimes: new Set() };
    if (holder.retained.agent !== agent) throw new Error('Workspace process owner changed');
    holder.retained.runtimes.add(runtime);
  }

  cleanupRetained(holder) {
    holder.cleanup ??= Promise.all([...holder.retained.runtimes].map(runtime => runtime.release(holder.retained.agent)))
      .catch(error => { holder.cleanup = undefined; throw error; });
    return holder.cleanup;
  }

  async quiesce(rootID) {
    const ownerID = `settle:${randomUUID()}`;
    const token = await this.acquire(rootID, ownerID, { allowWorkflowWait: true });
    await this.release(rootID, ownerID, token);
  }

  enterWorkflow(rootID, holder) {
    holder.workflows++;
    const pool = this.pool(rootID);
    const waiters = pool.waiters.splice(0);
    for (const waiter of waiters) {
      if (waiter.allowWorkflowWait) { pool.waiters.push(waiter); continue; }
      waiter.signal?.removeEventListener('abort', waiter.abort);
      waiter.reject(workflowBusy());
    }
  }

  async acquireForSession({ sessionId, ownerId, wait }, signal) {
    const rootID = await this.sessions.rootID(sessionId);
    if (rootID !== sessionId) throw new Error('The workspace owner must be a root session');
    this.validate(rootID, ownerId);
    const pool = this.pool(rootID);
    if (pool.revoked.has(ownerId)) throw new Error('Workspace write owner was cancelled');
    if (this.requiresRecovery(rootID)) {
      if (wait === false) return { acquired: false, reason: 'recovery-required' };
      throw recoveryRequired();
    }
    const existing = pool.holders.get(ownerId);
    if (existing?.refs > 0) return { acquired: true, token: existing.token };
    if (wait === false && (pool.holders.size || pool.waiters.length || pool.clearing)) {
      pool.notifyWhenFree = true;
      this.drain(rootID);
      return { acquired: false };
    }
    return { acquired: true, token: await this.acquire(rootID, ownerId, { signal }) };
  }

  async releaseForSession({ sessionId, ownerId, token }) {
    const rootID = await this.sessions.rootID(sessionId);
    if (rootID !== sessionId) throw new Error('The workspace owner must be a root session');
    await this.release(rootID, ownerId, token);
    return { accepted: true };
  }

  async statusForSession({ sessionId } = {}) {
    const recoveryRoots = [...this.pools.keys()].filter(rootID => this.requiresRecovery(rootID));
    if (sessionId === undefined) return { recoveryRoots };
    const rootID = await this.sessions.rootID(sessionId);
    if (rootID !== sessionId) throw new Error('The workspace owner must be a root session');
    return { recoveryRoots, recoveryRequired: this.requiresRecovery(rootID) };
  }

  recoveryList() { return this.recovery.list(); }
  recoveryCheck(payload = {}) { return this.recovery.check(payload); }
  recoveryTerminate(payload) { return this.recovery.terminate(payload); }
  recoveryConfirmLegacy(payload) { return this.recovery.confirmLegacy(payload); }
  recoveryAcknowledge(payload) { return this.recovery.acknowledge(payload); }

  async cancelForSession({ sessionId, ownerId }) {
    const rootID = await this.sessions.rootID(sessionId);
    if (rootID !== sessionId) throw new Error('The workspace owner must be a root session');
    this.validate(rootID, ownerId);
    const pool = this.pool(rootID);
    pool.revoked.add(ownerId);
    for (const waiter of [...pool.waiters]) {
      if (waiter.ownerID !== ownerId) continue;
      pool.waiters.splice(pool.waiters.indexOf(waiter), 1);
      waiter.signal?.removeEventListener('abort', waiter.abort);
      waiter.reject(new Error('Workspace write owner was cancelled'));
    }
    const holder = pool.holders.get(ownerId);
    if (holder) await this.release(rootID, ownerId, holder.token);
    else this.drain(rootID);
    return { accepted: true };
  }

  async stop(rootID) {
    const pool = this.pool(rootID);
    const processes = [...pool.processes];
    for (const process of processes) process.terminate();
    await Promise.all(processes.map(process => process.waitForExit()));
    await Promise.all([...pool.settlements].map(settlement => settlement.retry()));
    for (const holder of [...pool.holders.values()]) {
      if (!holder.retained) continue;
      await this.cleanupRetained(holder);
      const retained = holder.retained;
      holder.retained = undefined;
      if (holder.refs === 0 && pool.holders.get(holder.ownerID) === holder) {
        try { await this.release(rootID, holder.ownerID, holder.token); }
        catch (error) { holder.retained = retained; throw error; }
      }
      holder.cleanup = undefined;
    }
    if (this.requiresRecovery(rootID)) throw recoveryRequired();
  }

  hasActiveProcesses(rootID) {
    const pool = this.pool(rootID);
    return pool.processes.size > 0 || pool.settlements.size > 0 || this.requiresRecovery(rootID) ||
      [...pool.holders.values()].some(holder => holder.retained);
  }

  async execute(exec, next) {
    if (!exec.agent) return next();
    if (exec.name === 'wait_agent' && exec.rootCallId && exec.rootCallId !== exec.callId) {
      const rootID = await this.sessions.rootID(exec.agent.id);
      const holder = this.holder(rootID, `tool:${exec.agent.id}:${exec.rootCallId}`);
      const peers = holder?.refs > 0 ? this.ctx.agentTeams?.listMembers(exec.agent) : undefined;
      if (peers?.some(peer => peer.id !== exec.agent.id && ['running', 'provisioning'].includes(peer.status))) {
        throw new Error('Finish the current code step before waiting for another agent using this workspace.');
      }
    }
    if (nonWritingTools.has(exec.name)) return next();
    const rootID = await this.sessions.rootID(exec.agent.id);
    const ownerID = `tool:${exec.agent.id}:${exec.rootCallId ?? exec.callId}`;
    const retained = exec.name === 'run_code' && this.ctx.ptcRuntime?.config?.executionMode === 'persistent-in-memory';
    const terminalCall = ['terminal_open', 'terminal_send', 'terminal_signal', 'terminal_close'].includes(exec.name);
    const retainedRuntime = retained ? this.ctx.ptcRuntime : terminalCall ? this.terminalRuntime : undefined;
    const token = await this.acquire(rootID, ownerID, { signal: exec.signal, reentrant: true, persistent: true,
      ...(retainedRuntime ? { retainedAgent: exec.agent, retainedRuntime } : {}) });
    const holder = this.holder(rootID, ownerID);
    const workflow = exec.name === 'workflow';
    if (workflow) this.enterWorkflow(rootID, holder);
    const jobsBefore = new Set(this.ctx.jobs.list(exec.agent.id).map(job => job.id));
    const pool = this.pool(rootID);
    const scope = { handles: new Set(), add(handle) { this.handles.add(handle); pool.processes.add(handle); } };
    const tracksProcesses = !retained;
    if (!tracksProcesses) scope.add = () => {};
    let executed = false;
    try {
      await this.checkProjectWrite?.(rootID);
      if (!holder.scopeRecord) {
        holder.scopeRecord = this.scopes.create(rootID, ownerID);
        holder.scopeID = holder.scopeRecord.id;
        await this.persist();
      }
      scope.record = holder.scopeRecord;
      executed = true;
      return await this.processContext.run(scope, next);
    }
    finally {
      if (scope.record?.poisoned) {
        holder.recovered = true;
        this.onRecovery(rootID, 'unknown');
      }
      if (retained && executed) this.retain(holder, exec.agent, this.ctx.ptcRuntime);
      if (terminalCall && executed) {
        const terminals = this.ctx.get?.('terminals');
        if (terminals?.hasOwnerActivity(exec.agent)) this.retain(holder, exec.agent, this.terminalRuntime);
        else if (holder.retained?.runtimes.has(this.terminalRuntime)) {
          holder.retained.runtimes.delete(this.terminalRuntime);
          if (!holder.retained.runtimes.size) holder.retained = undefined;
        }
      }
      const jobs = this.ctx.jobs.list(exec.agent.id).filter(job => !jobsBefore.has(job.id) && activeJob(job));
      const release = async () => {
        for (const job of jobs) {
          let state = job;
          while (activeJob(state)) state = await this.ctx.jobs.wait(job.id, 30000, exec.agent.id);
        }
        for (const process of scope.handles) {
          await process.waitForExit();
          pool.processes.delete(process);
        }
        if (workflow) holder.workflows--;
        await this.release(rootID, ownerID, token);
      };
      if (!jobs.length && !scope.handles.size) await release();
      else {
        const settlement = { retry: () => {
          settlement.pending ??= release().then(() => { pool.settlements.delete(settlement); }, error => {
            settlement.pending = undefined;
            throw error;
          });
          return settlement.pending;
        } };
        pool.settlements.add(settlement);
        void settlement.retry().catch(error => process.stderr.write(`Workspace process settlement failed: ${error.message}\n`));
      }
    }
  }

  dispose() {
    this.disposed = true;
    clearInterval(this.recoveryTimer);
    this.removeExecute?.();
    this.removeSpawn?.();
    this.removeTerminal?.();
    for (const pool of this.pools.values()) for (const waiter of pool.waiters.splice(0)) {
      waiter.signal?.removeEventListener('abort', waiter.abort);
      waiter.reject(new Error('Workspace write coordinator is closed'));
    }
  }
}
