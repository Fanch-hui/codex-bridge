import { createHash, randomUUID } from 'node:crypto';
import { contentForEvent } from './presentation.mjs';
import { readEvent } from './session-content.mjs';

const hash = value => createHash('sha256').update(JSON.stringify(value)).digest('hex');
const maxCursors = 128, maxCursorBytes = 4 * 1024 * 1024, cursorLifetime = 10 * 60 * 1000;

export class SessionSearch {
  constructor(ctx, sessions) {
    this.ctx = ctx;
    this.sessions = sessions;
    this.cursors = new Map();
    this.cursorBytes = 0;
  }
  cursor(state) {
    const bytes = Buffer.byteLength(JSON.stringify(state));
    if (bytes > maxCursorBytes) throw new Error('Search cursor exceeds the resource budget');
    while (this.cursors.size >= maxCursors || this.cursorBytes + bytes > maxCursorBytes) {
      const oldest = this.cursors.keys().next().value;
      this.cursorBytes -= this.cursors.get(oldest).bytes;
      this.cursors.delete(oldest);
    }
    const id = randomUUID();
    this.cursors.set(id, { state, bytes, expires: Date.now() + cursorLifetime });
    this.cursorBytes += bytes;
    return `v1.${id}`;
  }
  resume(cursor) {
    if (typeof cursor !== 'string' || !/^v1\.[0-9a-f-]{36}$/.test(cursor)) throw new Error('Invalid session search cursor');
    const id = cursor.slice(3), row = this.cursors.get(id);
    if (!row || row.expires <= Date.now()) {
      if (row) { this.cursors.delete(id); this.cursorBytes -= row.bytes; }
      throw new Error('Search results expired; search again');
    }
    this.cursors.delete(id);
    this.cursors.set(id, row);
    return row.state;
  }
  async titles(ids, signal) {
    const { titles, titleSeqs } = this.sessions;
    const missing = ids.filter(id => !titles.has(id) || titles.get(id) && !titleSeqs.has(id));
    if (!missing.length) return;
    let observations;
    try { observations = await this.ctx.sessionQuery.readTitleSnapshots(missing, signal); }
    finally {
      this.ctx.sessionQuery.bridgeReleaseObservations?.(missing);
      this.ctx.get?.('sessionPersistence')?.bridgeReleaseReadCache?.(missing);
    }
    for (const row of observations) {
      if (row.status === 'rejected') throw row.reason;
      const snapshot = row.value.title;
      titles.set(row.sessionId, snapshot?.title ?? null);
      if (Number.isSafeInteger(snapshot?.eventSeq)) titleSeqs.set(row.sessionId, snapshot.eventSeq);
      else titleSeqs.delete(row.sessionId);
    }
  }
  async search(payload, signal) {
    if (typeof payload.query !== 'string' || !payload.query.trim() || payload.query.length > 256 ||
        !Array.isArray(payload.sessionIDs) || payload.sessionIDs.length > 4096 ||
        payload.sessionIDs.some(id => typeof id !== 'string' || !id)) throw new Error('Invalid session search');
    const limit = payload.limit ?? 20;
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 20) throw new Error('Invalid session search page');
    const ids = [...new Set(payload.sessionIDs)].sort(), query = payload.query.trim();
    if (!ids.length) return { items: [], hasMore: false };
    await this.titles(ids, signal);
    const normalized = query.normalize('NFKC').toLowerCase();
    const matches = ids.filter(id => this.sessions.titles.get(id)?.normalize('NFKC').toLowerCase().includes(normalized))
      .map(id => ({ sessionId: id, seq: this.sessions.titleSeqs.get(id) ?? 0,
        title: this.sessions.titles.get(id), excerpt: [...this.sessions.titles.get(id)].slice(0, 240).join(''), matchKind: 'title' }));
    const identity = hash([query, ids]), titleHash = hash(matches);
    const state = payload.cursor === undefined ? { identity, titleHash, phase: 'titles', offset: 0 } : this.resume(payload.cursor);
    if (state.identity !== identity || state.titleHash !== titleHash) throw new Error('Search results changed; search again');
    const matched = new Set(matches.map(item => item.sessionId));
    const messageIDs = ids.filter(id => !matched.has(id));
    if (state.phase === 'titles' && state.offset < matches.length) {
      const items = matches.slice(state.offset, state.offset + limit);
      const offset = state.offset + items.length;
      const hasMore = offset < matches.length || messageIDs.length > 0;
      return { items, hasMore, ...(hasMore ? { nextCursor: this.cursor({ identity, titleHash,
        phase: offset < matches.length ? 'titles' : 'messages', offset }) } : {}) };
    }
    if (!messageIDs.length) return { items: [], hasMore: false };
    if (state.buffer?.length) return this.messagePage(state.buffer, state.nativeCursor, limit, identity, titleHash);
    const result = await this.ctx.sessionQuery.searchSessions({ query, limit: 20,
      sessionFilters: [{ kind: 'id', values: messageIDs }],
      ...(state.nativeCursor ? { cursor: state.nativeCursor } : {}),
      eventFilters: [{ kind: 'type', values: ['user/message', 'assistant/message'] }, { kind: 'surface', values: ['current'] }]
    }, { signal });
    const allowed = new Set(messageIDs);
    const candidates = result.items.filter(hit => allowed.has(hit.header?.id) && hit.bestMatch?.sessionId === hit.header.id &&
      hit.bestMatch.surface === 'current' && Number.isSafeInteger(hit.bestMatch.seq));
    const items = new Array(candidates.length);
    let index = 0;
    await Promise.all(Array.from({ length: Math.min(2, candidates.length) }, async () => {
      while (index < candidates.length) {
        const i = index++, hit = candidates[i];
        const event = await readEvent(this.ctx, hit.header.id, hit.bestMatch.seq, signal);
        if (!event || event.seq !== hit.bestMatch.seq || contentForEvent(event, 'message.text') === null) continue;
        const title = this.sessions.titles.get(hit.header.id);
        items[i] = { sessionId: hit.header.id, seq: hit.bestMatch.seq,
          ...(title ? { title } : {}), excerpt: [...String(hit.bestMatch.snippet ?? '')].slice(0, 240).join('') };
      }
    }));
    return this.messagePage(items.filter(Boolean), result.nextCursor, limit, identity, titleHash);
  }
  messagePage(items, nativeCursor, limit, identity, titleHash) {
    const shown = items.slice(0, limit), buffer = items.slice(limit);
    const hasMore = buffer.length > 0 || !!nativeCursor;
    return { items: shown, hasMore, ...(hasMore ? { nextCursor: this.cursor({ identity, titleHash,
      phase: 'messages', buffer, ...(nativeCursor ? { nativeCursor } : {}) }) } : {}) };
  }
}
