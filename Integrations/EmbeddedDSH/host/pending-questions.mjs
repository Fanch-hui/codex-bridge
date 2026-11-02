import { readFile, rename, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

const relevantEvents = new Set(['request/header', 'tool/call', 'tool/result', 'tool/ptc-dispatch', 'user/message', 'turn/end']);

export class PendingQuestions {
  constructor(ctx, home, notify) {
    this.ctx = ctx;
    this.path = join(home, 'bridge-pending-questions.json');
    this.notify = notify;
    this.rows = new Map();
    this.revisions = new Map();
    this.queued = new Set();
    this.active = 0;
    this.persistQueue = Promise.resolve();
    this.closed = false;
    this.abort = new AbortController();
  }
  async start() {
    try {
      const rows = JSON.parse(await readFile(this.path, 'utf8'));
      if (!Array.isArray(rows) || rows.some(row => typeof row.sessionID !== 'string' ||
          typeof row.callId !== 'string' || !Array.isArray(row.questions))) throw new Error('Invalid pending question index');
      for (const row of rows) this.rows.set(this.key(row.sessionID, row.callId), row);
    } catch (error) {
      if (error.code !== 'ENOENT') process.stderr.write(`Pending question index could not be read: ${error.message}\n`);
    }
    this.removeListener = this.ctx.on('session/event', (session, event) => {
      if (relevantEvents.has(event.type)) this.schedule(session.id);
    }, { global: true });
    void this.rebuild().catch(error => process.stderr.write(`Pending question index rebuild failed: ${error.message}\n`));
  }
  key(sessionID, callId) { return JSON.stringify([sessionID, callId]); }
  requestID(row) { return `dsh-question:${row.sessionID}:${row.callId}`; }
  items() {
    return [...this.rows.values()].map(row => ({ sessionID: row.sessionID, type: 'question',
      payload: { requestId: this.requestID(row), callId: row.callId, questions: row.questions } }));
  }
  find(requestID) { return [...this.rows.values()].find(row => this.requestID(row) === requestID); }
  remove(sessionID, callId) {
    if (!this.rows.delete(this.key(sessionID, callId))) return;
    this.revisions.set(sessionID, (this.revisions.get(sessionID) ?? 0) + 1);
    void this.persist().catch(() => {});
    this.notify(sessionID, 'pending.changed', {});
  }
  async rebuild() {
    const sessions = await this.ctx.sessionController.list({}, this.abort.signal);
    const ids = new Set(sessions.items.map(row => row.sessionId));
    for (const row of this.rows.values()) if (!ids.has(row.sessionID)) this.rows.delete(this.key(row.sessionID, row.callId));
    for (const id of ids) this.schedule(id);
    await this.persist();
  }
  schedule(id) {
    if (this.closed) return;
    this.revisions.set(id, (this.revisions.get(id) ?? 0) + 1);
    this.queued.add(id);
    this.pump();
  }
  pump() {
    while (!this.closed && this.active < 2 && this.queued.size) {
      const id = this.queued.values().next().value;
      this.queued.delete(id);
      const revision = this.revisions.get(id);
      this.active++;
      void this.refresh(id, revision).catch(error => process.stderr.write(`Pending question lookup failed: ${error.message}\n`))
        .finally(() => { this.active--; this.pump(); });
    }
  }
  async refresh(sessionID, revision) {
    let projection;
    try { projection = await this.ctx.sessionController.projections({ sessionId: sessionID }, this.abort.signal); }
    finally {
      this.ctx.sessionQuery?.bridgeReleaseObservations?.([sessionID]);
      this.ctx.get?.('sessionPersistence')?.bridgeReleaseReadCache?.([sessionID]);
    }
    if (this.closed || this.revisions.get(sessionID) !== revision) return;
    const items = (projection?.values?.userQuestions?.active ?? []).filter(question => question.state === 'continued')
      .map(question => ({ sessionID, callId: question.callId, questions: question.questions }));
    const before = [...this.rows.values()].filter(row => row.sessionID === sessionID);
    if (JSON.stringify(before) === JSON.stringify(items)) return;
    for (const row of before) this.rows.delete(this.key(sessionID, row.callId));
    for (const row of items) this.rows.set(this.key(sessionID, row.callId), row);
    await this.persist();
    this.notify(sessionID, 'pending.changed', {});
  }
  persist() {
    const task = this.persistQueue.then(async () => {
      const temporary = `${this.path}.tmp`;
      await writeFile(temporary, `${JSON.stringify([...this.rows.values()])}\n`, { mode: 0o600 });
      await rename(temporary, this.path);
    });
    this.persistQueue = task.catch(error => process.stderr.write(`Pending question index could not be saved: ${error.message}\n`));
    return task;
  }
  async dispose() {
    this.closed = true;
    this.abort.abort();
    this.removeListener?.();
    await this.persistQueue;
  }
}
