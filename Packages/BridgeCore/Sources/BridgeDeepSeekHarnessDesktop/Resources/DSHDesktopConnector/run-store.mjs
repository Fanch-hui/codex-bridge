import { readFile, writeFile, rename } from 'node:fs/promises';

export class RunStore {
  constructor(file) { this.file = file; this.runs = new Map(); this.writes = Promise.resolve(); }
  async load() {
    try {
      const values = JSON.parse(await readFile(this.file, 'utf8'));
      this.runs = new Map(values.map(item => [item.requestID, item]));
    } catch (error) { if (error.code !== 'ENOENT') throw error; }
  }
  get(requestID) { return this.runs.get(requestID); }
  save() {
    const value = JSON.stringify([...this.runs.values()]);
    const task = this.writes.then(async () => {
      await writeFile(`${this.file}.tmp`, value, { mode: 0o600 });
      await rename(`${this.file}.tmp`, this.file);
    });
    this.writes = task.catch(() => {});
    return task;
  }
}
