import { contentForEvent } from './presentation.mjs';

const fields = new Set(['message.text', 'reasoning', 'tool.input', 'tool.output']);

export async function readEvent(ctx, sessionId, seq, signal) {
  signal?.throwIfAborted();
  const live = ctx.sessions?.get(sessionId);
  if (live) return live.snapshotEvents(seq, seq + 1)[0];
  const persistence = ctx.get?.('sessionPersistence');
  try {
    if (typeof persistence?.bridgeReadEvent === 'function') return await persistence.bridgeReadEvent(sessionId, seq, signal);
    return (await ctx.sessionQuery.readEvent({ sessionId, seq, before: 0, after: 0 }, signal)).target;
  } finally { ctx.sessionQuery?.bridgeReleaseObservations?.([sessionId]); }
}

export async function sessionContent(ctx, payload, signal, cache) {
  if (typeof payload.sessionId !== 'string' || !payload.sessionId || !Number.isSafeInteger(payload.seq) || payload.seq < 0 ||
      !fields.has(payload.field)) throw new Error('Invalid session content request');
  const offset = payload.offset ?? 0, limit = payload.limit ?? 65536;
  if (!Number.isSafeInteger(offset) || offset < 0 || !Number.isSafeInteger(limit) || limit < 4 || limit > 65536) {
    throw new Error('Invalid session content range');
  }
  const key = JSON.stringify([payload.sessionId, payload.seq, payload.field]);
  const item = await cache.acquire(key, async loadSignal => {
    const event = await readEvent(ctx, payload.sessionId, payload.seq, loadSignal);
    if (!event || event.seq !== payload.seq) throw new Error('Session content is unavailable');
    const text = contentForEvent(event, payload.field);
    if (text === null) throw new Error('Session content is unavailable');
    return text;
  }, signal);
  try {
    signal?.throwIfAborted();
    return await cache.read(item, offset, limit);
  } finally { await cache.release(item); }
}
