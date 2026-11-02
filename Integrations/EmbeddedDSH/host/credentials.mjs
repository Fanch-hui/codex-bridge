import { CredentialProvider } from '@deepseek-ai/dsh-credentials';

const rpc = () => globalThis[Symbol.for('codex-bridge.rpc')];
const secret = (operation, key, value) => rpc().request('bridge/secret', { operation, key, ...(value === undefined ? {} : { value }) });

export default class BridgeCredentials extends CredentialProvider {
  constructor(ctx) { super(ctx); this.queue = Promise.resolve(); }
  async resolve(ref) {
    if (typeof ref === 'string' && ref.startsWith('BRIDGE_DSH_NOAUTH_')) return { value: 'unused', source: 'bridge' };
    const { value } = await secret('get', `ref/${ref}`);
    return typeof value === 'string' && value ? { value, source: 'bridge' } : undefined;
  }
  async describe(ref) { return { configured: !!(await this.resolve(ref)), writable: true, source: 'bridge' }; }
  async set(ref, value) {
    if (!value) throw new Error('Credential must be nonempty');
    await secret('set', `ref/${ref}`, value);
    this.notifyUpdated(ref);
  }
  async unset(ref) { await secret('delete', `ref/${ref}`); this.notifyUpdated(ref); }
  async readRecord(key) { return (await secret('get', `record/${key}`)).value ?? undefined; }
  async describeRecord(key) {
    const record = await this.readRecord(key);
    return { configured: !!record, writable: true, ...(record ? { kind: record.kind } : {}) };
  }
  async listRecords() {
    const { value } = await secret('get', 'record-index');
    const keys = Array.isArray(value) ? value : [];
    const records = await Promise.all(keys.map(async key => ({ key, record: await this.readRecord(key) })));
    return records.filter(x => x.record).map(x => ({ key: x.key, kind: x.record.kind }));
  }
  exclusive(fn) {
    const result = this.queue.then(fn, fn);
    this.queue = result.catch(() => {});
    return result;
  }
  modifyRecord(key, mutate) {
    return this.exclusive(async () => {
      const current = await this.readRecord(key);
      const next = await mutate(current);
      if (next === undefined) return current;
      const { value } = await secret('get', 'record-index');
      const keys = Array.isArray(value) ? value : [];
      if (!keys.includes(key)) await secret('set', 'record-index', [...keys, key]);
      await secret('set', `record/${key}`, next);
      this.notifyRecordUpdated(key);
      return next;
    });
  }
  deleteRecord(key) {
    return this.exclusive(async () => {
      await secret('delete', `record/${key}`);
      const { value } = await secret('get', 'record-index');
      await secret('set', 'record-index', (Array.isArray(value) ? value : []).filter(k => k !== key));
      this.notifyRecordUpdated(key);
    });
  }
}
