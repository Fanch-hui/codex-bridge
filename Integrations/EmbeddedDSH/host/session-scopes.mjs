import { readFile, rename, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

const conversationTools = new Set(['ask_user_question', 'todo_write', 'web_search', 'web_fetch']);

export class SessionScopes {
  constructor(ctx, home, emit) {
    this.ctx = ctx;
    this.path = join(home, 'bridge-chat-only-sessions.json');
    this.pendingPath = join(home, 'bridge-workspace-requests.json');
    this.emit = emit;
    this.chatOnly = new Set();
    this.pending = new Map();
    this.pendingRequests = new Map();
    this.presentations = new WeakMap();
    this.queue = Promise.resolve();
    this.pendingQueue = Promise.resolve();
  }
  async start() {
    try {
      const rows = JSON.parse(await readFile(this.path, 'utf8'));
      if (!Array.isArray(rows) || rows.some(id => typeof id !== 'string' || !id)) throw new Error('Invalid session scope index');
      this.chatOnly = new Set(rows);
    } catch (error) { if (error.code !== 'ENOENT') throw error; }
    try {
      const requests = JSON.parse(await readFile(this.pendingPath, 'utf8'));
      if (!Array.isArray(requests) || requests.some(row => typeof row.sessionId !== 'string' || typeof row.toolCallId !== 'string')) {
        throw new Error('Invalid workspace request index');
      }
      for (const request of requests) if (this.chatOnly.has(request.sessionId)) this.pendingRequests.set(request.sessionId, request);
    } catch (error) { if (error.code !== 'ENOENT') throw error; }
    this.removeGuard = this.ctx.tools.guard(exec => this.blocked(exec) ? 'A project folder is required for this tool' : undefined);
    this.removePreExecute = this.ctx.on('tools/pre-execute', (exec, next) => this.preExecute(exec, next),
      { global: true, prepend: true });
  }
  persistPending() {
    const task = this.pendingQueue.then(async () => {
      const temporary = `${this.pendingPath}.tmp`;
      await writeFile(temporary, `${JSON.stringify([...this.pendingRequests.values()])}\n`, { mode: 0o600 });
      await rename(temporary, this.pendingPath);
    });
    this.pendingQueue = task.catch(() => {});
    return task;
  }
  items() {
    return [...this.pendingRequests.values()].map(payload => ({ sessionID: payload.sessionId, type: 'workspace', payload }));
  }
  isChatOnly(sessionID) { return this.chatOnly.has(sessionID); }
  blocked(exec) {
    return !!exec.agent && this.isChatOnly(exec.agent.session.id) && !conversationTools.has(exec.name);
  }
  async set(sessionID, scope) {
    if (typeof sessionID !== 'string' || !sessionID || !['chatOnly', 'project'].includes(scope)) {
      throw new Error('A valid session scope is required');
    }
    const task = this.queue.then(async () => {
      if (scope === 'project' && this.chatOnly.has(sessionID)) {
        throw new Error('A chat-only session must be bound through a new project session');
      }
      if (scope === 'chatOnly' && !this.chatOnly.has(sessionID)) {
        this.chatOnly.add(sessionID);
        try {
          const temporary = `${this.path}.tmp`;
          await writeFile(temporary, `${JSON.stringify([...this.chatOnly])}\n`, { mode: 0o600 });
          await rename(temporary, this.path);
        } catch (error) { this.chatOnly.delete(sessionID); throw error; }
      }
      return { sessionId: sessionID, scope };
    });
    this.queue = task.catch(() => {});
    return task;
  }
  prepareAgent(agent) {
    if (!this.isChatOnly(agent.session.id) || this.presentations.has(agent)) return;
    if (this.ctx.tools.modeFor(agent) === 'native') { this.presentations.set(agent, null); return; }
    this.presentations.set(agent, agent.ctx.tools.presentAs('native'));
  }
  async preExecute(exec, next) {
    if (!this.blocked(exec)) return next();
    if (exec.signal.aborted) return { kind: 'cancel' };
    const sessionID = exec.agent.session.id;
    let pending = this.pending.get(sessionID);
    if (!pending) {
      pending = new Set();
      this.pending.set(sessionID, pending);
      const source = exec.agent.session.snapshotEvents().findLast(event => event.type === 'user/message' && event.data?.source?.kind === 'user')?.data?.source;
      const request = { sessionId: sessionID, toolCallId: exec.callId,
        ...(source?.rpcId ? { requestId: source.rpcId } : {}), message: '选择文件夹以继续使用本地工具。' };
      this.pendingRequests.set(sessionID, request);
      try { await this.persistPending(); }
      catch (error) { this.pendingRequests.delete(sessionID); this.pending.delete(sessionID); throw error; }
      if (this.pending.get(sessionID) !== pending || exec.signal.aborted) {
        if (this.pending.get(sessionID) === pending) this.pending.delete(sessionID);
        return { kind: 'cancel' };
      }
      this.emit(sessionID, 'workspace.required', request);
    }
    return new Promise(resolve => {
      const finish = () => {
        exec.signal.removeEventListener('abort', finish);
        pending.delete(finish);
        if (!pending.size && this.pending.get(sessionID) === pending) this.pending.delete(sessionID);
        resolve({ kind: 'cancel' });
      };
      pending.add(finish);
      exec.signal.addEventListener('abort', finish, { once: true });
      if (exec.signal.aborted) finish();
    });
  }
  async clearPending(sessionID, pending) {
    if (pending && this.pending.get(sessionID) !== pending) return;
    this.pending.delete(sessionID);
    if (this.pendingRequests.delete(sessionID)) await this.persistPending();
  }
  async cancel(sessionID) {
    await Promise.all([...(this.pending.get(sessionID) ?? [])].map(finish => finish()));
    await this.clearPending(sessionID);
  }
  dispose() {
    for (const callbacks of this.pending.values()) for (const finish of callbacks) void finish();
    this.removePreExecute?.();
    this.removeGuard?.();
  }
}
