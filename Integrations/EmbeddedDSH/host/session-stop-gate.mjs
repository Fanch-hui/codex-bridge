import { readFile, rename, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

export class SessionStopGate {
  constructor(home) {
    this.path = join(home, 'bridge-stopped-sessions.json');
    this.stopped = new Set();
    this.revisions = new Map();
    this.queue = Promise.resolve();
  }
  async start() {
    try {
      const stored = JSON.parse(await readFile(this.path, 'utf8'));
      if (!Array.isArray(stored) || stored.some(id => typeof id !== 'string')) throw new Error('Invalid stopped session list');
      this.stopped = new Set(stored);
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
  }
  revision(id) { return this.revisions.get(id) ?? 0; }
  isStopped(id) { return this.stopped.has(id); }
  async stop(id) {
    this.revisions.set(id, this.revision(id) + 1);
    this.stopped.add(id);
    await this.persist();
  }
  async resume(id, revision) {
    if (this.revision(id) !== revision) throw new Error('Session was stopped');
    if (!this.stopped.delete(id)) return;
    try { await this.persist(); }
    catch (error) { this.stopped.add(id); throw error; }
  }
  async persist() {
    const contents = `${JSON.stringify([...this.stopped])}\n`;
    const task = this.queue.then(async () => {
      const temporary = `${this.path}.tmp`;
      await writeFile(temporary, contents, { mode: 0o600 });
      await rename(temporary, this.path);
    });
    this.queue = task.catch(() => {});
    await task;
  }
}
