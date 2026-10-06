import { realpath } from 'node:fs/promises';
import path from 'node:path';
import { historyMessages } from './history.mjs';
import { fault } from './errors.mjs';
import { defaults, flattenCatalog, decodeModel, saveDefaults } from './models.mjs';

export class NativeServices {
  constructor(ctx) { this.ctx = ctx; this.historyWindows = new Map(); }
  async catalog() {
    const catalog = await this.ctx.sessionController.modelCatalog();
    if (!catalog.groups.length && catalog.failures.length) throw fault('native_model_catalog_unavailable', catalog.failures.map(item => item.message).join('; '));
    return { models: flattenCatalog(catalog), defaults: defaults(this.ctx.agentDefaultModel.currentSelection()) };
  }
  defaults() { return defaults(this.ctx.agentDefaultModel.currentSelection()); }
  setDefaults(params) { return saveDefaults(this.ctx, params); }
  async summary(sessionID) {
    const { items } = await this.ctx.sessionController.list({}, new AbortController().signal);
    return items.find(item => item.sessionId === sessionID);
  }
  async list(projectPath) {
    const { items } = await this.ctx.sessionController.list({}, new AbortController().signal);
    const canonical = value => process.platform === 'win32' ? path.normalize(value).toLowerCase() : path.normalize(value);
    const mapped = await Promise.all(items.map(async item => {
      if (!item.cwd) return undefined;
      try { return canonical(await realpath(item.cwd)) === canonical(projectPath) ? item : undefined; } catch { return undefined; }
    }));
    return mapped.filter(Boolean).map(item => ({
      sessionID: item.sessionId, cwd: item.cwd, title: item.projections?.title?.title ?? item.projections?.title ?? 'DSH 会话',
      updatedAt: new Date(item.updatedAt).toISOString(), status: item.running ? 'running' : 'idle',
    }));
  }
  async snapshot(sessionID, maxMessages = 1000) {
    const controller = new AbortController();
    const iterator = this.ctx.sessionController.follow({ address: { kind: 'session', sessionId: sessionID }, maxMessages }, controller.signal)[Symbol.asyncIterator]();
    try {
      const { value } = await iterator.next();
      if (value?.type !== 'snapshot') throw fault('native_history_invalid', 'Native session stream did not return a snapshot');
      return value;
    } finally { controller.abort(); await iterator.return?.(); }
  }
  async records(sessionID) {
    const opening = await this.snapshot(sessionID);
    let records = opening.records;
    let hasMore = opening.hasMore;
    while (hasMore) {
      const beforeSeq = (records[0]?.event ?? records[0])?.seq;
      if (beforeSeq === undefined) throw fault('native_history_invalid', 'Native history cursor is missing');
      const page = await this.ctx.sessionController.page({ address: { kind: 'session', sessionId: sessionID }, throughSeq: opening.cursor, beforeSeq, maxMessages: 1000 }, new AbortController().signal);
      if (!page.records.length) break;
      records = [...page.records, ...records];
      hasMore = page.hasMore;
    }
    return { header: opening.header, cursor: opening.cursor, records };
  }
  async read(sessionID, offset = 0, limit = 50) {
    if (!Number.isSafeInteger(offset) || offset < 0 || !Number.isSafeInteger(limit) || limit < 1 || limit > 200) throw fault('invalid_request', 'Invalid native history page');
    const key = `${sessionID}:${limit}`;
    let window;
    let page;
    if (offset === 0) {
      const opening = await this.snapshot(sessionID, limit);
      window = { header: opening.header, throughSeq: opening.cursor, offsets: new Set() };
      this.historyWindows.set(key, window);
      page = opening;
    } else {
      window = this.historyWindows.get(key);
      if (!window || !window.offsets.has(offset)) throw fault('native_history_cursor_expired', 'Reload the first native history page');
      page = await this.ctx.sessionController.page({ address: { kind: 'session', sessionId: sessionID }, throughSeq: window.throughSeq, beforeSeq: offset - 1, maxMessages: limit }, new AbortController().signal);
    }
    const messages = historyMessages(page.records);
    const firstSeq = (page.records[0]?.event ?? page.records[0])?.seq;
    if (page.hasMore && firstSeq !== undefined) window.offsets.add(firstSeq + 1);
    return { sessionID, cwd: window.header.cwd, messages, ...(page.hasMore && firstSeq !== undefined ? { nextOffset: firstSeq + 1 } : {}) };
  }
  async create(root, sessionID) {
    const workspace = await this.ctx.workspaceController.create({ path: root });
    const workspaceID = workspace.workspace?.id ?? workspace.id;
    return this.ctx.sessionController.create({ ...(workspaceID ? { workspaceId: workspaceID } : { cwd: root }), ...(sessionID ? { sessionId: sessionID } : {}) });
  }
  async selectModel(sessionID, params) {
    const selected = decodeModel(params.modelID);
    const result = await this.ctx.sessionController.selectModel({ sessionId: sessionID, ...selected, ...(params.effort == null || params.effort === '' ? {} : { reasoningEffort: params.effort }) });
    try { await saveDefaults(this.ctx, defaults(result.selected)); }
    catch (error) {
      throw fault('desktop_default_save_failed', `DSH 会话 ${sessionID} 的模型已更新；桌面默认保存未确认：${error.message}`);
    }
    return result.selected;
  }
  prompt(sessionID, requestID, text, mode = 'queue') {
    return this.ctx.sessionController.prompt({ sessionId: sessionID, requestId: requestID, mode, content: [{ type: 'text', text }] }, new AbortController().signal);
  }
  rename(sessionID, title) { return this.ctx.sessionController.rename({ sessionId: sessionID, title }); }
  agent(sessionID) { return this.ctx.agents.get(sessionID); }
  cancel(sessionID) { return this.ctx.sessionController.cancel({ sessionId: sessionID }); }
}
