import { createInterface } from 'node:readline';

export class Rpc {
  constructor(input = process.stdin, output = process.stdout) {
    this.output = output;
    this.pending = new Map();
    this.incoming = new Map();
    this.nextID = 0;
    this.lines = createInterface({ input, crlfDelay: Infinity });
    this.lines.on('line', line => void this.receive(line));
    this.lines.on('close', () => this.onClose?.());
  }

  send(message) { this.output.write(`${JSON.stringify(message)}\n`); }
  notify(method, params) { this.send({ jsonrpc: '2.0', method, params }); }
  request(method, params) {
    const id = `node:${++this.nextID}`;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.send({ jsonrpc: '2.0', id, method, params });
    });
  }

  async receive(line) {
    let message;
    try { message = JSON.parse(line); } catch { return; }
    if (message.method === '$/cancelRequest') {
      this.incoming.get(message.params?.id)?.abort();
      return;
    }
    if (!message.method) {
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      if (message.error) pending.reject(new Error(message.error.message));
      else pending.resolve(message.result);
      return;
    }
    if (message.id === undefined) return;
    const controller = new AbortController();
    this.incoming.set(message.id, controller);
    try {
      const result = await this.onRequest(message.method, message.params, controller.signal);
      this.send({ jsonrpc: '2.0', id: message.id, result: result ?? {} });
    } catch (error) {
      this.send({ jsonrpc: '2.0', id: message.id, error: { code: -32000, message: String(error?.message ?? error) } });
    } finally { this.incoming.delete(message.id); }
  }
}
