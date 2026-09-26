import { randomUUID } from 'node:crypto';
import { HostError, requireValue, object, identifier } from './validation.mjs';

export class RPCPeer {
  constructor(input, output, handler, onClose = async () => {}) {
    this.input = input; this.output = output; this.handler = handler; this.onClose = onClose;
    this.pending = new Map(); this.active = new Set(); this.closed = false;
    this.buffer = Buffer.alloc(0); this.maximum = 16 * 1024 * 1024;
    this.onData = bytes => this.receive(bytes);
    input.on('data', this.onData);
    input.once('end', () => { void this.close(); });
    input.once('error', () => { void this.close(); });
    output.once('error', () => { void this.close(); });
  }
  send(value) {
    requireValue(!this.closed, 'transport_closed');
    const bytes = Buffer.from(JSON.stringify({ jsonrpc: '2.0', ...value }) + '\n');
    requireValue(bytes.length <= this.maximum && this.output.writableLength < 4 * this.maximum,
      'transport_overflow');
    this.output.write(bytes);
  }
  notify(method, params) { this.send({ method, params }); }
  request(method, params, signal, timeout = 300000) {
    requireValue(!this.closed && this.pending.size < 32 && !signal?.aborted, 'interaction_cancelled');
    const id = 'host-' + randomUUID();
    return new Promise((resolve, reject) => {
      const abort = () => {
        if (!this.pending.has(id)) return;
        this.pending.delete(id); clearTimeout(timer); signal?.removeEventListener('abort', abort);
        reject(new HostError('interaction_cancelled'));
      };
      const timer = setTimeout(abort, timeout);
      const finish = (error, result) => {
        clearTimeout(timer); signal?.removeEventListener('abort', abort);
        if (error) reject(error); else resolve(result);
      };
      this.pending.set(id, finish);
      signal?.addEventListener('abort', abort, { once: true });
      if (signal?.aborted) { abort(); return; }
      try { this.send({ id, method, params }); }
      catch (error) { this.pending.delete(id); finish(error); }
    });
  }
  receive(bytes) {
    if (this.closed) return;
    try {
      this.buffer = Buffer.concat([this.buffer, bytes]);
      let end;
      while ((end = this.buffer.indexOf(10)) >= 0) {
        const line = this.buffer.subarray(0, end); this.buffer = this.buffer.subarray(end + 1);
        requireValue(line.length <= this.maximum, 'oversized_frame');
        if (line.length > 0) this.dispatch(object(JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(line))));
      }
      requireValue(this.buffer.length <= this.maximum, 'oversized_frame');
    } catch { void this.close(); }
  }
  dispatch(value) {
    requireValue(value.jsonrpc === '2.0');
    const validID = typeof value.id === 'string' ? value.id.length > 0 && value.id.length <= 256
      : Number.isSafeInteger(value.id);
    requireValue(validID);
    if (value.method === undefined) {
      requireValue((value.result !== undefined) !== (value.error !== undefined));
      const pending = this.pending.get(value.id);
      if (!pending) return;
      this.pending.delete(value.id);
      pending(value.error ? new HostError('interaction_rejected') : null, value.result);
      return;
    }
    identifier(value.method);
    requireValue(!this.active.has(value.id) && this.active.size < 64, 'duplicate_request');
    this.active.add(value.id);
    Promise.resolve().then(() => this.handler(value.method, object(value.params ?? {})))
      .then(result => { if (!this.closed) this.send({ id: value.id, result: result ?? {} }); })
      .catch(error => {
        if (!this.closed) this.send({ id: value.id, error: { code: -32000,
          message: error instanceof HostError ? error.code : 'qoder_host_error' } });
      }).finally(() => this.active.delete(value.id));
  }
  async close() {
    if (this.closed) return;
    this.closed = true; this.input.off('data', this.onData); this.input.pause(); this.buffer = Buffer.alloc(0);
    for (const finish of this.pending.values()) finish(new HostError('transport_closed'));
    this.pending.clear();
    await this.onClose();
  }
}
