import { randomUUID } from 'node:crypto';
import { present, presentHistory, presentProjections } from './presentation.mjs';

const allowed = new Set(['$events', 'session/control', 'session/follow', 'workspace/follow', 'remoteAccess/follow', 'job/list', 'job/follow']);
const maxBytes = 2 * 1024 * 1024;
const maxFrameBytes = 1024 * 1024;

class Uplink {
  constructor() { this.items = []; this.closed = false; this.wake = undefined; }
  send(type, item) {
    if (this.closed) throw new Error('Stream uplink has ended');
    if (type === 'end') this.closed = true;
    else if (type === 'item' && this.items.length < 64 && Buffer.byteLength(JSON.stringify(item ?? null)) <= 65536) this.items.push(item);
    else throw new Error('Invalid or full stream uplink');
    this.wake?.();
  }
  async *[Symbol.asyncIterator]() {
    while (!this.closed || this.items.length) {
      if (this.items.length) { yield this.items.shift(); continue; }
      await new Promise(resolve => { this.wake = resolve; });
      this.wake = undefined;
    }
  }
  close() { this.closed = true; this.wake?.(); }
}

function boundedFrame(endpoint, value, state) {
  if (endpoint === 'job/list') return { ...value, jobs: value.jobs.filter(job => job.owner === state.sessionID) };
  if (endpoint !== 'session/follow') return value;
  if (value.type === 'event') return present(value);
  if (value.type !== 'snapshot') return present(value);
  const history = presentHistory(value.records, 700 * 1024);
  const { projections } = presentProjections(value.projections, 128 * 1024);
  return { ...value, header: present(value.header), records: history.records,
    hasMore: value.hasMore || history.truncated, projections,
    ...(value.assistantStream ? { assistantStream: present(value.assistantStream) } : {}) };
}

export class ClientStreams {
  constructor(ctx, peer) {
    this.ctx = ctx;
    this.peer = peer;
    this.generation = randomUUID();
    this.sequence = 0;
    this.ack = 0;
    this.frames = [];
    this.bytes = 0;
    this.streams = new Map();
    this.waiters = new Set();
  }
  wake() { for (const wake of this.waiters) wake(); }
  reset() {
    for (const state of this.streams.values()) { state.abort.abort(); state.uplink.close(); }
    this.streams.clear();
    this.frames = [];
    this.bytes = 0;
    this.sequence = 0;
    this.ack = 0;
    this.generation = randomUUID();
    this.wake();
  }
  async open({ streamID, endpoint, payload }) {
    if (typeof streamID !== 'string' || !streamID || streamID.length > 128 || this.streams.has(streamID)) throw new Error('Invalid stream identity');
    if (!allowed.has(endpoint) || this.streams.size >= 32) throw new Error('Stream endpoint is unavailable');
    const state = { abort: new AbortController(), uplink: new Uplink(), generation: this.generation };
    if (endpoint === 'job/list' || endpoint === 'job/follow') {
      const request = payload?.args?.request;
      if (!request || !this.isAllowedSession(request.sessionId)) throw new Error('Job session is unavailable');
      state.sessionID = request.sessionId;
      if (endpoint === 'job/follow' && this.ctx.jobs.get(request.jobId, request.sessionId).owner !== request.sessionId) {
        throw new Error('Job is not owned by the session');
      }
    }
    this.streams.set(streamID, state);
    try {
      const source = await this.ctx.typertGateway.wireStream.open(endpoint, payload, state.uplink, this.peer, state.abort.signal);
      if (state.abort.signal.aborted || state.generation !== this.generation) throw new Error('Stream scope changed while opening');
      void this.pump(streamID, endpoint, state, source);
      return { generation: this.generation };
    } catch (error) {
      if (this.streams.get(streamID) === state) this.streams.delete(streamID);
      state.uplink.close();
      throw error;
    }
  }
  async pump(streamID, endpoint, state, source) {
    try {
      for await (const value of source) {
        if (endpoint === '$events' && value?.event === 'goal/activation-changed' &&
            !this.isAllowedSession(value.args?.[0]?.sessionId)) continue;
        await this.enqueue({ streamID, type: 'item', value: boundedFrame(endpoint, value, state) }, state);
      }
      if (!state.abort.signal.aborted) await this.enqueue({ streamID, type: 'end' }, state);
    } catch (error) {
      if (!state.abort.signal.aborted) await this.enqueue({ streamID, type: 'error', error: this.ctx.typertGateway.wireStream.failure(error) }, state);
    } finally {
      state.uplink.close();
      if (this.streams.get(streamID) === state) this.streams.delete(streamID);
    }
  }
  async enqueue(frame, state) {
    const bytes = Buffer.byteLength(JSON.stringify(frame));
    if (bytes > maxFrameBytes) throw new Error('DSH stream frame exceeds the presentation budget');
    while (!state.abort.signal.aborted && (this.frames.length >= 512 || this.bytes + bytes > maxBytes)) await this.wait(state.abort.signal, 30000);
    if (state.abort.signal.aborted || state.generation !== this.generation) return;
    this.frames.push({ ...frame, sequence: ++this.sequence, bytes });
    this.bytes += bytes;
    this.wake();
  }
  send({ streamID, type, item }) {
    const state = this.streams.get(streamID);
    if (!state) throw new Error('Stream is no longer active');
    state.uplink.send(type, item);
    return {};
  }
  close({ streamID }) {
    const state = this.streams.get(streamID);
    if (state) { state.abort.abort(); state.uplink.close(); this.streams.delete(streamID); this.wake(); }
    return {};
  }
  async poll({ afterSequence = 0, timeoutMs = 1000, generation: requestedGeneration }, signal) {
    if (!Number.isSafeInteger(afterSequence) || afterSequence < 0) throw new Error('Invalid stream cursor');
    const generation = this.generation;
    if (requestedGeneration !== undefined && requestedGeneration !== generation) return { generation, frames: [] };
    if (afterSequence > this.sequence) {
      if (requestedGeneration === undefined) return { generation, frames: [] };
      throw new Error('Invalid stream cursor');
    }
    if (afterSequence < this.ack) throw new Error('Stream cursor is no longer available');
    this.ack = afterSequence;
    while (this.frames.length && this.frames[0].sequence <= afterSequence) this.bytes -= this.frames.shift().bytes;
    this.wake();
    if (!this.frames.length && timeoutMs > 0 && !signal?.aborted) await this.wait(signal, Math.min(timeoutMs, 1000));
    if (generation !== this.generation) return { generation: this.generation, frames: [] };
    const frames = [];
    let bytes = 0;
    for (const frame of this.frames) {
      if (frames.length >= 128 || bytes + frame.bytes > maxFrameBytes) break;
      bytes += frame.bytes;
      const { bytes: _, ...wire } = frame;
      frames.push(wire);
    }
    return { generation: this.generation, frames };
  }
  wait(signal, milliseconds) {
    return new Promise(resolve => {
      const wake = () => { clearTimeout(timer); this.waiters.delete(wake); signal?.removeEventListener('abort', wake); resolve(); };
      const timer = setTimeout(wake, milliseconds);
      this.waiters.add(wake);
      signal?.addEventListener('abort', wake, { once: true });
      if (signal?.aborted) wake();
    });
  }
}
