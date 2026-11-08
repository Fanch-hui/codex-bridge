import { readFile, rename, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

const categories = ['models', 'mcp', 'plugins'];
const initial = () => ({ desiredRevision: 0, appliedRevision: 0, status: 'applied', restartRequired: false });

export class ConfigurationActivation {
  constructor(home, notify) {
    this.path = join(home, 'bridge-configuration-activation.json');
    this.notify = notify;
    this.categories = Object.fromEntries(categories.map(name => [name, initial()]));
    this.queue = Promise.resolve();
    this.operations = new Map();
  }
  async start() {
    try {
      const saved = JSON.parse(await readFile(this.path, 'utf8'));
      for (const name of categories) {
        const row = saved[name];
        if (!row || !Number.isSafeInteger(row.desiredRevision) || !Number.isSafeInteger(row.appliedRevision) ||
            !['applied', 'applying', 'restart-required', 'failed', 'unknown'].includes(row.status)) throw new Error('Invalid configuration state');
        this.categories[name] = { ...row };
        if (row.status === 'applying') Object.assign(this.categories[name], {
          status: 'unknown', restartRequired: false, error: '上次配置操作中断，请检查当前设置。'
        });
      }
      await this.persist();
    } catch (error) { if (error.code !== 'ENOENT') throw error; }
  }
  get(name) { return { ...this.categories[name] }; }
  snapshot() { return Object.fromEntries(categories.map(name => [name, this.get(name)])); }
  async completeRestart(name, status) {
    const current = this.categories[name];
    if (current?.status !== 'restart-required' && !(current?.status === 'unknown' && current.verificationPending)) return;
    await this.update(name, row => {
      row.status = status;
      row.restartRequired = false;
      if (status === 'applied') { row.appliedRevision = row.desiredRevision; delete row.error; }
      else row.error = status === 'failed' ? '配置加载失败，请检查详情。' : '无法确认配置是否已生效。';
      if (status === 'unknown') row.verificationPending = true;
      else delete row.verificationPending;
    });
  }
  run(name, operation, classify = () => 'applied') {
    if (!categories.includes(name)) throw new Error('Unknown configuration category');
    const previous = this.operations.get(name) ?? Promise.resolve();
    const task = previous.catch(() => {}).then(async () => {
      await this.update(name, row => {
        row.desiredRevision++; row.status = 'applying'; row.restartRequired = false; delete row.error; delete row.verificationPending;
      });
      try {
        const value = await operation();
        const status = classify(value);
        await this.update(name, row => {
          row.status = status;
          row.restartRequired = status === 'restart-required';
          if (status === 'applied') row.appliedRevision = row.desiredRevision;
          if (status === 'failed') row.error = '配置未生效，请检查详情。';
        });
        return value;
      } catch (error) {
        await this.update(name, row => {
          row.status = 'failed'; row.restartRequired = false; row.error = '配置应用失败，请重试。';
        });
        throw error;
      }
    });
    this.operations.set(name, task);
    return task.finally(() => { if (this.operations.get(name) === task) this.operations.delete(name); });
  }
  async update(name, change) {
    change(this.categories[name]);
    await this.persist();
    this.notify(undefined, 'configuration.changed', { category: name, activation: this.get(name) });
  }
  persist() {
    const task = this.queue.then(async () => {
      const temporary = `${this.path}.tmp`;
      await writeFile(temporary, `${JSON.stringify(this.categories)}\n`, { mode: 0o600 });
      await rename(temporary, this.path);
    });
    this.queue = task.catch(() => {});
    return task;
  }
}

export function pluginApplication(result) {
  if (result?.application === 'restart-required') return 'restart-required';
  if (result?.application === 'cancelled' && !result.changed) return 'applied';
  if (['failed', 'overridden', 'cancelled'].includes(result?.application)) return 'failed';
  return 'applied';
}
