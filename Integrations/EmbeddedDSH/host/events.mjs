import { randomUUID } from 'node:crypto';
import { present, presentEvent } from './presentation.mjs';

export class Events {
  constructor(ctx, rpc) {
    this.rpc = rpc;
    this.cursor = 0;
    this.items = [];
    this.bytes = 0;
    this.pending = new Map();
    this.waiters = new Set();
    ctx.on('session/event', (session, event) => this.emit(session.id, event.type, event.data, event.seq, event.surfaceOp), { global: true });
    ctx.on('agent/assistant-stream', ({ agent, frame }) => this.emit(agent.session.id, 'assistant-stream', frame), { global: true });
    ctx.on('agent/status', ({ agent, status }) => this.emit(agent.session.id, 'status', { status }), { global: true });
    ctx.on('approval/request', request => this.ask('approval', request), { global: true });
    ctx.on('user-questions/request', request => this.ask('question', request), { global: true });
  }
  emit(sessionID, type, payload, seq, surfaceOp) {
    const projected = presentEvent({ type, data: payload ?? {}, ...(Number.isSafeInteger(seq) ? { seq } : {}),
      ...(surfaceOp === undefined ? {} : { surfaceOp }) });
    const event = { sessionID, type, payload: projected.data, ...(Number.isSafeInteger(seq) ? { seq } : {}),
      ...(surfaceOp === undefined ? {} : { surfaceOp: present(surfaceOp) }),
      ...(projected.truncatedFields ? { truncatedFields: projected.truncatedFields } : {}) };
    const entry = { cursor: ++this.cursor, ...event };
    entry.bytes = Buffer.byteLength(JSON.stringify(entry));
    this.bytes += entry.bytes;
    this.items.push(entry);
    while (this.items.length > 2000 || this.bytes > 8 * 1024 * 1024) this.bytes -= this.items.shift().bytes;
    this.rpc.notify('bridge/event', event);
    for (const wake of this.waiters) wake();
  }
  ask(type, request) {
    const requestId = randomUUID();
    const sessionID = request.agent?.session?.id;
    const payload = type === 'approval'
      ? { requestId, toolName: request.toolName, ...(request.callId ? { callId: request.callId } : {}), ...(request.reason ? { reason: request.reason } : {}) }
      : { requestId, questions: request.questions, ...(request.wait?.callId ? { callId: request.wait.callId } : {}) };
    return new Promise((resolve, reject) => {
      const abort = () => {
        this.pending.delete(requestId);
        if (type === 'approval') resolve('cancelled');
        else reject(request.signal?.reason ?? new Error('Question cancelled'));
      };
      this.pending.set(requestId, { type, sessionID, payload, resolve, abort, signal: request.signal });
      request.signal?.addEventListener('abort', abort, { once: true });
      if (request.signal?.aborted) abort();
      else this.emit(sessionID, type, payload);
    });
  }
  answer(type, payload) {
    const item = this.pending.get(payload.requestId);
    if (!item || item.type !== type) throw new Error('Request is no longer pending');
    if (type === 'approval' && !['allowed-once', 'rejected'].includes(payload.outcome)) throw new Error('Invalid approval outcome');
    this.pending.delete(payload.requestId);
    item.signal?.removeEventListener('abort', item.abort);
    item.resolve(type === 'approval' ? payload.outcome : { answers: payload.answers });
    return { accepted: true };
  }
  async poll({ after = 0, timeoutMs = 0 }, signal) {
    const reset = after > this.cursor || after < (this.items[0]?.cursor ?? this.cursor + 1) - 1;
    if (!reset && after >= this.cursor && timeoutMs > 0 && !signal.aborted) {
      await new Promise(resolve => {
        const wake = () => { clearTimeout(timer); this.waiters.delete(wake); signal.removeEventListener('abort', wake); resolve(); };
        const timer = setTimeout(wake, Math.min(timeoutMs, 30000));
        this.waiters.add(wake);
        signal.addEventListener('abort', wake, { once: true });
      });
    }
    return { events: this.items.filter(item => reset || item.cursor > after).map(({ bytes, ...item }) => item), cursor: this.cursor, reset,
      pending: [...this.pending.values()].map(({ sessionID, type, payload }) => ({ sessionID, type, payload })) };
  }
}
