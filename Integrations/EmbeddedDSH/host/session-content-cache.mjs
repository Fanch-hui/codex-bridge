import { randomUUID } from 'node:crypto';
import { mkdir, open, readdir, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

const maxBytes = 64 * 1024 * 1024;

export class SessionContentCache {
  constructor(home, budget = maxBytes) {
    this.directory = join(home, 'bridge-content-cache');
    this.budget = budget;
    this.entries = new Map();
    this.loading = new Map();
    this.memoryBytes = 0;
    this.removals = new Set();
  }
  async start() {
    await mkdir(this.directory, { recursive: true, mode: 0o700 });
    for (const name of await readdir(this.directory)) {
      if (/^content-[0-9a-f-]{36}\.tmp$/.test(name)) await rm(join(this.directory, name), { force: true });
    }
  }
  async acquire(key, load, signal) {
    while (true) {
      signal?.throwIfAborted();
      let item = this.entries.get(key);
      if (item) {
        this.entries.delete(key);
        this.entries.set(key, item);
        item.readers++;
        return item;
      }
      let work = this.loading.get(key);
      if (!work) {
        const controller = new AbortController();
        work = { controller, waiters: 0, settled: false };
        work.promise = this.load(key, load, controller.signal).then(value => {
          work.settled = true;
          return value;
        }, error => { work.settled = true; throw error; });
        this.loading.set(key, work);
        void work.promise.finally(() => { if (this.loading.get(key) === work) this.loading.delete(key); }).catch(() => {});
      }
      work.waiters++;
      try { item = await this.wait(work.promise, signal); }
      finally {
        work.waiters--;
        if (!work.waiters && !work.settled) {
          if (this.loading.get(key) === work) this.loading.delete(key);
          work.controller.abort();
        }
      }
      if (!item.retired) { item.readers++; return item; }
    }
  }
  wait(promise, signal) {
    if (!signal) return promise;
    signal.throwIfAborted();
    return new Promise((resolve, reject) => {
      const cancel = () => { cleanup(); reject(signal.reason); };
      const cleanup = () => signal.removeEventListener('abort', cancel);
      signal.addEventListener('abort', cancel, { once: true });
      promise.then(value => { cleanup(); resolve(value); }, error => { cleanup(); reject(error); });
      if (signal.aborted) cancel();
    });
  }
  async load(key, load, signal) {
    const text = await load(signal);
    signal.throwIfAborted();
    if (typeof text !== 'string') throw new Error('Session content is unavailable');
    const size = Buffer.byteLength(text);
    const item = { size, readers: 0, retired: false };
    if (size <= this.budget) {
      while (this.memoryBytes + size > this.budget) {
        const oldest = [...this.entries].find(([, entry]) => entry.bytes && !entry.readers);
        if (!oldest) break;
        this.evict(oldest[0]);
      }
    }
    if (size <= this.budget && this.memoryBytes + size <= this.budget) {
      item.bytes = Buffer.from(text);
      this.memoryBytes += size;
    } else {
      const path = join(this.directory, `content-${randomUUID()}.tmp`);
      try {
        await writeFile(path, text, { mode: 0o600, flag: 'wx', signal });
        signal.throwIfAborted();
      } catch (error) { await rm(path, { force: true }); throw error; }
      item.path = path;
      for (const [oldKey, old] of this.entries) if (old.path) this.evict(oldKey);
    }
    this.entries.set(key, item);
    return item;
  }
  evict(key) {
    const item = this.entries.get(key);
    if (!item) return;
    this.entries.delete(key);
    item.retired = true;
    if (item.bytes && !item.readers) this.releaseBytes(item);
    if (item.path && !item.readers) this.remove(item);
  }
  releaseBytes(item) {
    this.memoryBytes -= item.size;
    delete item.bytes;
  }
  remove(item) {
    if (item.removing) return item.removing;
    item.removing = rm(item.path, { force: true });
    this.removals.add(item.removing);
    void item.removing.finally(() => this.removals.delete(item.removing)).catch(error => { this.cleanupError ??= error; });
    return item.removing;
  }
  async release(item) {
    item.readers--;
    if (item.bytes && item.retired && !item.readers) this.releaseBytes(item);
    if (item.path && item.retired && !item.readers) await this.remove(item);
  }
  async read(item, offset, limit) {
    if (offset > item.size) throw new Error('Invalid session content offset');
    const length = Math.min(item.size - offset, limit + 1);
    let bytes;
    if (item.bytes) bytes = item.bytes.subarray(offset, offset + length);
    else {
      const handle = await open(item.path, 'r');
      try {
        bytes = Buffer.alloc(length);
        const result = await handle.read(bytes, 0, length, offset);
        if (result.bytesRead !== length) throw new Error('Session content cache changed');
      } finally { await handle.close(); }
    }
    if (bytes.length && (bytes[0] & 0xc0) === 0x80) throw new Error('Invalid session content offset');
    let end = Math.min(limit, bytes.length);
    while (end < bytes.length && (bytes[end] & 0xc0) === 0x80) end--;
    return { text: bytes.subarray(0, end).toString('utf8'),
      nextOffset: offset + end < item.size ? offset + end : null, totalBytes: item.size };
  }
  async dispose() {
    for (const work of this.loading.values()) work.controller.abort();
    await Promise.allSettled([...this.loading.values()].map(work => work.promise));
    for (const key of this.entries.keys()) this.evict(key);
    await Promise.all([...this.removals]);
    if (this.cleanupError) throw this.cleanupError;
  }
}
