import { randomUUID } from 'node:crypto';
import { setTimeout as delay } from 'node:timers/promises';

export class ClientEventResponder {
  constructor(ctx) {
    this.ctx = ctx;
    this.abort = new AbortController();
  }
  async start() {
    const stream = await this.open();
    this.done = this.supervise(stream).catch(error => {
      if (!this.abort.signal.aborted) process.stderr.write(`DSH event forwarding failed: ${error.message}\n`);
    });
  }
  async open() {
    const peer = this.ctx.connection.createPeer({ principal: { kind: 'owner' }, interactions: 'answer' });
    this.peer = peer;
    try {
      const source = await this.ctx.typertGateway.wireStream.open('$events', { args: {} },
        { async *[Symbol.asyncIterator]() {} }, peer, this.abort.signal);
      const iterator = source[Symbol.asyncIterator]();
      const first = await iterator.next();
      if (first.done || first.value.type !== 'ready') throw new Error('Missing DSH event stream handshake');
      return { iterator, clientId: first.value.clientId, peer };
    } catch (error) { await peer.dispose(); throw error; }
  }
  async supervise(stream) {
    while (!this.abort.signal.aborted) {
      try {
        await this.consume(stream);
        if (!this.abort.signal.aborted) throw new Error('DSH event stream ended');
      } catch (error) {
        if (!this.abort.signal.aborted) process.stderr.write(`DSH event forwarding failed: ${error.message}\n`);
      } finally { await stream.peer.dispose(); }
      while (!this.abort.signal.aborted) {
        try {
          await delay(250, undefined, { signal: this.abort.signal });
          stream = await this.open();
          break;
        } catch (error) {
          if (!this.abort.signal.aborted) process.stderr.write(`DSH event stream reconnect failed: ${error.message}\n`);
        }
      }
    }
  }
  async consume({ iterator, clientId, peer }) {
    for await (const frame of { [Symbol.asyncIterator]: () => iterator }) {
      if (frame.type !== 'waterfall') continue;
      const rpcId = randomUUID();
      const message = { type: 'client-request', rpcId, method: '$events/result', payload: {
        args: { clientId, eventId: frame.eventId, outcome: { kind: 'next' } }
      } };
      const request = new Request('https://bridge.invalid/api/$events/result', {
        method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(message), signal: this.abort.signal
      });
      const response = await this.ctx.connection.createSharedFetchHandler('/api').fetch(request, peer);
      if (!response.ok) throw new Error(`DSH event response failed (${response.status})`);
      const envelope = await response.json();
      if (!envelope.result.ok) throw new Error(envelope.result.error.message);
    }
  }
  dispose() { this.abort.abort(); void this.peer?.dispose(); }
}
