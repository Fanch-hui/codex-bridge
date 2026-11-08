import { createHash } from 'node:crypto';
import { readFile, rename, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { pluginApplication } from './configuration-activation.mjs';

const terminal = new Set(['completed', 'failed', 'cancelled', 'unknown']);
const fingerprint = spec => createHash('sha256').update(spec).digest('hex');

export class PluginOperations {
  constructor(ctx, home, activation, notify) {
    this.ctx = ctx;
    this.path = join(home, 'bridge-plugin-operations.json');
    this.activation = activation;
    this.notify = notify;
    this.rows = new Map();
    this.starts = new Map();
    this.started = new Set();
    this.queue = Promise.resolve();
  }
  async start() {
    try {
      const rows = JSON.parse(await readFile(this.path, 'utf8'));
      if (!Array.isArray(rows) || rows.some(row => typeof row.requestId !== 'string' ||
          !/^[a-f0-9]{64}$/.test(row.fingerprint) || typeof row.status !== 'string')) throw new Error('Invalid plugin operation index');
      for (const row of rows) {
        if (!terminal.has(row.status)) row.status = 'unknown';
        this.rows.set(row.requestId, row);
      }
      await this.persist();
    } catch (error) { if (error.code !== 'ENOENT') throw error; }
    this.removeListener = this.ctx.on('plugin-manager/install-state', event => {
      if (!this.rows.has(event.requestId)) return;
      const status = event.phase === 'applying' ? 'applying' : 'installing';
      void this.update(event.requestId, { status }).catch(error => process.stderr.write(`Plugin status could not be saved: ${error.message}\n`));
    }, { global: true });
  }
  snapshot(id) {
    const row = this.rows.get(id);
    if (!row) return { requestId: id, status: 'unknown' };
    return { requestId: id, status: row.status, ...(row.result ? { result: row.result } : {}),
      ...(row.error ? { error: row.error } : {}) };
  }
  activeCount() { return [...this.rows.values()].filter(row => !terminal.has(row.status)).length; }
  recoverable() {
    return [...this.rows.values()].filter(row => !row.dismissed && !['completed', 'failed', 'cancelled'].includes(row.status))
      .slice(-100).reverse().map(row => this.snapshot(row.requestId));
  }
  async begin({ spec, requestId }) {
    if (typeof spec !== 'string' || !spec.trim() || spec.length > 16384 ||
        typeof requestId !== 'string' || !requestId || requestId.length > 256) throw new Error('Invalid plugin installation request');
    const digest = fingerprint(spec);
    const running = this.starts.get(requestId);
    if (running) {
      if (running.fingerprint !== digest) throw new Error('Plugin request ID was already used for another installation');
      return running.promise;
    }
    const promise = this.beginOnce(spec, requestId, digest);
    this.starts.set(requestId, { fingerprint: digest, promise });
    try { return await promise; }
    finally { if (this.starts.get(requestId)?.promise === promise) this.starts.delete(requestId); }
  }
  async beginOnce(spec, requestId, digest) {
    const existing = this.rows.get(requestId);
    if (existing) {
      if (existing.fingerprint !== digest) throw new Error('Plugin request ID was already used for another installation');
      return this.snapshot(requestId);
    }
    this.rows.set(requestId, { requestId, fingerprint: digest, status: 'installing' });
    try { await this.persist(); }
    catch (error) { this.rows.delete(requestId); throw error; }
    this.notify(undefined, 'plugin.install', this.snapshot(requestId));
    void this.install(spec, requestId);
    return this.snapshot(requestId);
  }
  async install(spec, requestId) {
    try {
      const result = await this.activation.run('plugins', () => {
        if (this.rows.get(requestId)?.status === 'cancelled') return { application: 'cancelled', changed: false };
        this.started.add(requestId);
        return this.ctx.pluginManager.installBundle(spec, { requestId });
      }, pluginApplication);
      const status = result.application === 'cancelled' ? 'cancelled' :
        ['failed', 'overridden'].includes(result.application) ? 'failed' : 'completed';
      const summary = { application: result.application, changed: !!result.changed,
        ...(result.restartReason ? { restartReason: result.restartReason } : {}),
        ...(result.error?.code ? { error: { code: result.error.code } } : {}) };
      await this.update(requestId, { status, result: summary,
        ...(status === 'failed' ? { error: '插件安装失败，请检查插件详情。' } : {}) });
    } catch (error) {
      await this.update(requestId, { status: 'failed', error: '插件安装失败，请重试。' })
        .catch(failure => process.stderr.write(`Plugin status could not be saved: ${failure.message}\n`));
    } finally { this.started.delete(requestId); }
  }
  async cancel(requestId) {
    if (typeof requestId !== 'string' || !requestId) throw new Error('Plugin request ID is required');
    if (this.starts.has(requestId)) await this.starts.get(requestId).promise;
    const row = this.rows.get(requestId);
    if (row && !terminal.has(row.status) && !this.started.has(requestId)) {
      await this.update(requestId, { status: 'cancelled' });
      return { status: 'cancelled' };
    }
    const result = await this.ctx.pluginManager.cancelInstall(requestId);
    if (result.status === 'cancelled' && this.rows.has(requestId)) await this.update(requestId, { status: 'cancelled' });
    return result;
  }
  async dismiss(requestId) {
    if (typeof requestId !== 'string' || !requestId) throw new Error('Plugin request ID is required');
    const row = this.rows.get(requestId);
    if (!row) return { dismissed: false };
    if (!terminal.has(row.status)) throw new Error('Plugin installation is still active');
    if (row.dismissed) return { dismissed: true };
    row.dismissed = true;
    try { await this.persist(); }
    catch (error) { delete row.dismissed; throw error; }
    return { dismissed: true };
  }
  async update(id, change) {
    const row = this.rows.get(id);
    if (!row || terminal.has(row.status)) return;
    Object.assign(row, change);
    await this.persist();
    this.notify(undefined, 'plugin.install', this.snapshot(id));
  }
  persist() {
    const task = this.queue.then(async () => {
      const temporary = `${this.path}.tmp`;
      await writeFile(temporary, `${JSON.stringify([...this.rows.values()])}\n`, { mode: 0o600 });
      await rename(temporary, this.path);
    });
    this.queue = task.catch(() => {});
    return task;
  }
  async dispose() { this.removeListener?.(); await this.queue; }
}
