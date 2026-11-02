import { createHash } from 'node:crypto';
import { readFile, rename, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

const pauseSupport = Symbol.for('codex-bridge.schedule-pause-support');
const digest = value => createHash('sha256').update(value).digest('hex');
const canonical = value => {
  if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
  if (value && typeof value === 'object') return `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${canonical(value[key])}`).join(',')}}`;
  return JSON.stringify(value);
};

export class ScheduleOperations {
  constructor(ctx, sessions, home) {
    this.ctx = ctx;
    this.sessions = sessions;
    this.path = join(home, 'bridge-schedule-operations.json');
    this.pauses = new Map();
    this.creates = new Map();
    this.migrations = new Map();
    this.held = new Set();
    this.running = new Map();
    this.queue = Promise.resolve();
  }
  async start() {
    try {
      const data = JSON.parse(await readFile(this.path, 'utf8'));
      if (!Array.isArray(data.pauses) || !Array.isArray(data.creates)) throw new Error('Invalid schedule operation index');
      this.pauses = new Map(data.pauses.map(row => [row.id, row]));
      this.creates = new Map(data.creates.map(row => [row.key, row]));
      if (data.migrations !== undefined && !Array.isArray(data.migrations)) throw new Error('Invalid schedule migration index');
      this.migrations = new Map((data.migrations ?? []).map(row => [row.sourceSessionId, row]));
      for (const migration of this.migrations.values()) {
        if (migration.state === 'held') for (const id of migration.ids) this.held.add(id);
      }
    } catch (error) { if (error.code !== 'ENOENT') throw error; }
  }
  persist() {
    const task = this.queue.then(async () => {
      const temporary = `${this.path}.tmp`;
      await writeFile(temporary, `${JSON.stringify({ pauses: [...this.pauses.values()], creates: [...this.creates.values()],
        migrations: [...this.migrations.values()] })}\n`, { mode: 0o600 });
      await rename(temporary, this.path);
    });
    this.queue = task.catch(() => {});
    return task;
  }
  isPaused(id) { return this.held.has(id) || this.pauses.get(id)?.paused === true; }
  async migrate(sourceSessionId, targetSessionId) {
    this.requirePauseSupport();
    return this.ctx.schedule.serialize(async () => {
      const table = (await this.ctx.schedule.getDomain()).table('tasks');
      let migration = this.migrations.get(sourceSessionId);
      if (migration && migration.targetSessionId !== targetSessionId) throw new Error('Schedule migration target changed');
      if (!migration) {
        migration = { sourceSessionId, targetSessionId, ids: [], state: 'held' };
        this.migrations.set(sourceSessionId, migration);
      }
      if (migration.state === 'released') return;
      const ids = new Set(migration.ids);
      for (const [id, task] of table.entries()) if (task.sessionId === sourceSessionId) ids.add(id);
      migration.ids = [...ids];
      for (const id of ids) this.held.add(id);
      await this.persist();
      for (const id of ids) {
        const task = table.get(id);
        if (!task) continue;
        if (task.sessionId === sourceSessionId) await table.put(id, { ...task, sessionId: targetSessionId });
        else if (task.sessionId !== targetSessionId) throw new Error('Schedule migration ownership changed');
        const pause = this.pauses.get(id);
        if (pause?.sessionId === sourceSessionId) pause.sessionId = targetSessionId;
      }
      await this.persist();
      this.changed();
    });
  }
  async releaseMigration(sourceSessionId, targetSessionId) {
    return this.ctx.schedule.serialize(async () => {
      const migration = this.migrations.get(sourceSessionId);
      if (!migration || migration.targetSessionId !== targetSessionId) throw new Error('Schedule migration is unavailable');
      if (migration.state === 'released') return;
      migration.state = 'released';
      try { await this.persist(); } catch (error) { migration.state = 'held'; throw error; }
      for (const id of migration.ids) this.held.delete(id);
      this.changed();
    });
  }
  decorate(row) {
    const state = this.pauses.get(row.id);
    if (!state) return row;
    return { ...row, ...(state.paused ? { status: 'paused' } : {}),
      ...(state.missedAt ? { missedAt: state.missedAt } : {}) };
  }
  async task(sessionId, id) {
    if (typeof sessionId !== 'string' || !sessionId || typeof id !== 'string' || !id) throw new Error('Schedule and session are required');
    const table = (await this.ctx.schedule.getDomain()).table('tasks');
    const task = table.get(id);
    if (!task || task.sessionId !== sessionId) throw new Error('Schedule is unavailable');
    return { table, task };
  }
  requirePauseSupport() {
    if (globalThis[pauseSupport] !== true) throw new Error('Schedule pause is unavailable in this engine');
  }
  async pause({ sessionId, id }) {
    this.requirePauseSupport();
    return this.ctx.schedule.serialize(async () => {
      const { task } = await this.task(sessionId, id);
      if (task.status !== 'active') throw new Error('Schedule has ended');
      const previous = this.pauses.get(id);
      this.pauses.set(id, { ...previous, id, sessionId, paused: true });
      try { await this.persist(); }
      catch (error) { previous ? this.pauses.set(id, previous) : this.pauses.delete(id); throw error; }
      this.changed();
      return this.decorate({ ...task.record, status: task.status });
    });
  }
  async resume({ sessionId, id }) {
    this.requirePauseSupport();
    return this.ctx.schedule.serialize(async () => {
      const { table, task } = await this.task(sessionId, id);
      let current = task;
      const state = this.pauses.get(id);
      if (!state?.paused || task.status !== 'active') return this.decorate({ ...task.record, status: task.status });
      const now = Date.now();
      if (Date.parse(task.record.scheduledAt) <= now) {
        if (!state.missedAt) {
          state.missedAt = task.record.scheduledAt;
          try { await this.persist(); } catch (error) { delete state.missedAt; throw error; }
        }
        if (!this.types.isRecurringScheduleRecord(task.record)) return this.decorate({ ...task.record, status: task.status });
        const next = this.types.resolveRecurringOccurrence(task.record, now).nextScheduledAt;
        if (!next) throw new Error('No further occurrence is available');
        current = { ...task, record: { ...task.record, scheduledAt: next } };
        await table.put(id, current);
      }
      state.paused = false;
      try { await this.persist(); } catch (error) { state.paused = true; throw error; }
      this.changed();
      return this.decorate({ ...current.record, status: current.status });
    });
  }
  async catchUp({ sessionId, id, requestId }) {
    this.requirePauseSupport();
    if (typeof requestId !== 'string' || !requestId) throw new Error('Catch-up request ID is required');
    const decision = await this.ctx.schedule.serialize(async () => {
      const { task } = await this.task(sessionId, id);
      const state = this.pauses.get(id);
      if (!state?.missedAt && state?.lastCatchUpRequestId === requestId) return { completed: true };
      if (!state?.missedAt) throw new Error('No missed occurrence is available');
      if (state.catchUpRequestId && state.catchUpRequestId !== requestId) throw new Error('A catch-up request already exists');
      state.catchUpRequestId = requestId;
      await this.persist();
      return { prompt: task.record.prompt };
    });
    if (decision.completed) return { accepted: true };
    await this.sessions.prompt({ sessionId, requestId, text: decision.prompt, mode: 'queue' });
    return this.ctx.schedule.serialize(async () => {
      const { table, task } = await this.task(sessionId, id);
      const state = this.pauses.get(id);
      if (state?.catchUpRequestId === requestId) {
        if (state.paused && !this.types.isRecurringScheduleRecord(task.record)) {
          await table.put(id, { ...task, status: 'inactive' });
          state.paused = false;
        }
        state.lastCatchUpRequestId = requestId;
        delete state.missedAt;
        delete state.catchUpRequestId;
        await this.persist();
        this.changed();
      }
      return { accepted: true };
    });
  }
  async discardMissed({ sessionId, id }) {
    this.requirePauseSupport();
    return this.ctx.schedule.serialize(async () => {
      const { table, task } = await this.task(sessionId, id);
      const state = this.pauses.get(id);
      if (!state?.missedAt) return { discarded: false };
      if (state.catchUpRequestId) throw new Error('A catch-up request is still being checked');
      const previous = { ...state };
      if (state.paused && !this.types.isRecurringScheduleRecord(task.record)) {
        await table.put(id, { ...task, status: 'inactive' });
        state.paused = false;
      }
      delete state.missedAt;
      try { await this.persist(); } catch (error) { this.pauses.set(id, previous); throw error; }
      this.changed();
      return { discarded: true };
    });
  }
  changed() { this.ctx.schedule.emitChanged(); this.ctx.schedule.runtime?.requestDrive(); }
  record(id, prompt, title, change) {
    const names = { at: ['createAtScheduleRecord', 'at'], every: ['createEveryScheduleRecord', 'every_seconds'],
      daily: ['createDailyScheduleRecord', 'daily'], weekly: ['createWeeklyScheduleRecord', 'weekly'],
      cron: ['createCronScheduleRecord', 'cron'] };
    const selected = names[change?.kind];
    if (!selected || typeof prompt !== 'string' || typeof title !== 'string') throw new Error('Invalid schedule');
    return this.types[selected[0]](id, prompt, change[selected[1]], Date.now(), title);
  }
  async create(input) {
    const { sessionId, requestId, title, prompt, change } = input;
    if (typeof sessionId !== 'string' || !sessionId || typeof requestId !== 'string' || !requestId || requestId.length > 256) {
      throw new Error('Schedule session and request IDs are required');
    }
    const key = JSON.stringify([sessionId, requestId]);
    const fingerprint = digest(canonical({ sessionId, title, prompt, change }));
    const running = this.running.get(key);
    if (running) {
      if (running.fingerprint !== fingerprint) throw new Error('Schedule request ID was reused with different input');
      return running.promise;
    }
    const promise = this.createOnce(input, key, fingerprint);
    this.running.set(key, { fingerprint, promise });
    try { return await promise; } finally { if (this.running.get(key)?.promise === promise) this.running.delete(key); }
  }
  async createOnce(input, key, fingerprint) {
    const existing = this.creates.get(key);
    if (existing) {
      if (existing.fingerprint !== fingerprint) throw new Error('Schedule request ID was reused with different input');
      return this.createStatus(input, true);
    }
    if (await this.sessions.rootID(input.sessionId) !== input.sessionId) throw new Error('A child session cannot receive reminders');
    const id = `schedule-${digest(key)}`;
    const record = this.record(id, input.prompt, input.title, input.change);
    const row = { key, id, sessionId: input.sessionId, fingerprint, state: 'prepared' };
    await this.ctx.schedule.serialize(async () => {
      if (this.migrations.has(input.sessionId)) throw new Error('The session is being bound to a project');
      const table = (await this.ctx.schedule.getDomain()).table('tasks');
      if (table.get(id)) throw new Error('Schedule identity already exists');
      this.creates.set(key, row);
      try { await this.persist(); } catch (error) { this.creates.delete(key); throw error; }
      await table.put(id, { sessionId: input.sessionId, record, status: 'active',
        deliveryHistory: { records: [], earlierRecordsUnavailable: false } });
      row.state = 'accepted';
      await this.persist();
      this.changed();
    });
    return { state: 'accepted', id, record };
  }
  async createStatus({ sessionId, requestId }, includeRunning = false) {
    const key = JSON.stringify([sessionId, requestId]);
    if (!includeRunning && this.running.has(key)) return { state: 'unknown' };
    const row = this.creates.get(key);
    if (!row) return { state: 'notFound' };
    const task = (await this.ctx.schedule.getDomain()).table('tasks').get(row.id);
    const migratedSession = this.migrations.get(sessionId)?.targetSessionId;
    if (task && (task.sessionId === sessionId || task.sessionId === migratedSession) || row.state === 'accepted') {
      return { state: 'accepted', id: row.id, ...(task ? { record: task.record } : {}) };
    }
    return { state: 'unknown', id: row.id };
  }
}
