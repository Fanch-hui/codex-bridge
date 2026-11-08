import { createHash } from 'node:crypto';
import { readFile, rename, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

function key(sessionID, requestID) { return JSON.stringify([sessionID, requestID]); }

export function promptFingerprint(payload) {
  return createHash('sha256').update(JSON.stringify({
    mode: payload.mode ?? 'queue',
    clientTimeZone: payload.clientTimeZone ?? null,
    content: payload.content ?? [{ type: 'text', text: payload.text }]
  })).digest('hex');
}

// This index contains no prompt text; the engine's session log remains authoritative.
export class PromptReceipts {
  constructor(home) {
    this.path = join(home, 'bridge-prompt-receipts.json');
    this.rows = new Map();
    this.queue = Promise.resolve();
  }
  async start() {
    try {
      const rows = JSON.parse(await readFile(this.path, 'utf8'));
      if (!Array.isArray(rows) || rows.some(row => !row || typeof row.sessionID !== 'string' ||
          typeof row.requestID !== 'string' || !/^[a-f0-9]{64}$/.test(row.fingerprint) ||
          !['admitting', 'accepted'].includes(row.state) || typeof row.durable !== 'boolean')) {
        throw new Error('Invalid prompt receipt index');
      }
      this.rows = new Map(rows.map(row => [key(row.sessionID, row.requestID), row]));
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
  }
  get(sessionID, requestID) { return this.rows.get(key(sessionID, requestID)); }
  async register(sessionID, requestID, fingerprint, durable) {
    return this.mutate(() => {
      const existing = this.get(sessionID, requestID);
      if (existing) {
        if (existing.fingerprint !== fingerprint) throw new Error('Request ID was already used for different content');
        return { ...existing, existing: true };
      }
      const row = { sessionID, requestID, fingerprint, durable, state: 'admitting' };
      this.rows.set(key(sessionID, requestID), row);
      return { ...row, existing: false };
    });
  }
  async accept(sessionID, requestID) {
    await this.mutate(() => {
      const row = this.get(sessionID, requestID);
      if (!row) throw new Error('Prompt admission was not registered');
      row.state = 'accepted';
    });
  }
  async mutate(change) {
    const task = this.queue.then(async () => {
      const previous = new Map([...this.rows].map(([id, row]) => [id, { ...row }]));
      try {
        const result = change();
        const temporary = `${this.path}.tmp`;
        await writeFile(temporary, `${JSON.stringify([...this.rows.values()])}\n`, { mode: 0o600 });
        await rename(temporary, this.path);
        return result;
      } catch (error) {
        this.rows = previous;
        throw error;
      }
    });
    this.queue = task.catch(() => {});
    return task;
  }
}
