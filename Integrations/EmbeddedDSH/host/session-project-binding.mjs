import { isAbsolute, normalize } from 'node:path';
import { createUserMessage } from '@deepseek-ai/dsh-llm';
import { inboxEvidence } from './inbox-evidence.mjs';

const durableAdmission = Symbol.for('codex-bridge.durable-session-admission');

function identity(payload) {
  if (typeof payload.sessionId !== 'string' || !payload.sessionId ||
      typeof payload.requestId !== 'string' || !payload.requestId) throw new Error('Session and request IDs are required');
}
function matches(message, requestID) {
  return message?.source?.kind === 'bridge-continuation' && message.source.requestId === requestID;
}

export class SessionProjectBinding {
  constructor(ctx, sessions, scopes, schedules) {
    this.ctx = ctx;
    this.sessions = sessions;
    this.scopes = scopes;
    this.schedules = schedules;
    this.bindings = new Map();
    this.continuations = new Map();
  }
  async inspectTarget(id) {
    if (!this.ctx.sessions.get(id)) {
      const persistence = this.ctx.get('sessionPersistence');
      if (!persistence) throw new Error('Session persistence is unavailable');
      if (!await persistence.stat(id)) return null;
    }
    return this.ctx.sessionController.inspect(id);
  }
  async cancel(payload) {
    identity(payload);
    const running = this.bindings.get(payload.targetSessionId)?.promise;
    const continuing = this.continuations.get(payload.targetSessionId)?.promise;
    await this.sessions.stop(payload.sessionId);
    await this.scopes.cancel(payload.sessionId);
    await Promise.allSettled([running, continuing].filter(Boolean));
    const target = await this.inspectTarget(payload.targetSessionId);
    if (!target) return { targetCreated: false };
    if (target.meta.parentSession !== payload.sessionId || target.meta.isSeeded !== true ||
        (payload.cwd && normalize(target.meta.cwd ?? '') !== normalize(payload.cwd)) ||
        !Number.isSafeInteger(target.inheritedEventCount) || target.inheritedEventCount < 1) {
      throw new Error('Project binding target does not match the source');
    }
    await this.sessions.stop(payload.targetSessionId);
    await this.scopes.cancel(payload.targetSessionId);
    return { targetCreated: true, sourceBoundarySeq: target.inheritedEventCount - 1 };
  }
  async bind(payload) {
    identity(payload);
    if (globalThis[durableAdmission] !== true) throw new Error('Project binding requires the bundled session controller');
    if (!this.scopes.isChatOnly(payload.sessionId) || typeof payload.targetSessionId !== 'string' ||
        !payload.targetSessionId || payload.targetSessionId === payload.sessionId ||
        typeof payload.cwd !== 'string' || !isAbsolute(payload.cwd) || payload.scope !== 'project') {
      throw new Error('Invalid project binding');
    }
    const existing = this.bindings.get(payload.targetSessionId);
    const fingerprint = JSON.stringify([payload.sessionId, payload.targetSessionId, payload.cwd, payload.requestId]);
    if (existing) {
      if (existing.fingerprint !== fingerprint) throw new Error('Project binding target is already in use');
      return existing.promise;
    }
    const promise = this.bindOnce(payload);
    this.bindings.set(payload.targetSessionId, { fingerprint, promise });
    try { return await promise; }
    finally { if (this.bindings.get(payload.targetSessionId)?.promise === promise) this.bindings.delete(payload.targetSessionId); }
  }
  async bindOnce(payload) {
    let target = await this.inspectTarget(payload.targetSessionId);
    if (target) return this.existingTarget(payload, target);
    const source = await this.sessions.agent(payload.sessionId);
    const initialRevision = this.sessions.stopGate.revision(payload.sessionId);
    const wasStopped = this.sessions.stopGate.isStopped(payload.sessionId);
    if (wasStopped) await source.whenIdle();
    else await this.sessions.stop(payload.sessionId);
    const stopRevision = initialRevision + (wasStopped ? 0 : 1);
    await this.scopes.cancel(payload.sessionId);
    if (this.sessions.stopGate.revision(payload.sessionId) !== stopRevision) throw new Error('Session was stopped');
    if (!await this.ctx.sessions.flush(source.session)) throw new Error('Session persistence did not acknowledge the binding');
    const observed = await this.ctx.sessionController.inspect(payload.sessionId);
    const boundary = observed.events.at(-1)?.seq;
    if (!Number.isSafeInteger(boundary) || boundary < 0) throw new Error('Session history is not ready to bind');
    const result = await this.ctx.sessionController.fork({ sessionId: payload.sessionId, atSeq: boundary,
      bridgeFork: { sessionId: payload.targetSessionId, cwd: payload.cwd } });
    if (result.sessionId !== payload.targetSessionId) throw new Error('Session binding returned an unexpected identity');
    if (this.sessions.stopGate.revision(payload.sessionId) !== stopRevision) throw new Error('Session was stopped');
    target = await this.ctx.sessionController.inspect(payload.targetSessionId);
    return this.existingTarget(payload, target);
  }
  async existingTarget(payload, target) {
    if (target.meta.parentSession !== payload.sessionId || target.meta.isSeeded !== true ||
        normalize(target.meta.cwd ?? '') !== normalize(payload.cwd) ||
        !Number.isSafeInteger(target.inheritedEventCount) || target.inheritedEventCount < 1) {
      throw new Error('Project binding target does not match the source');
    }
    await this.scopes.set(payload.targetSessionId, 'project');
    await this.schedules.migrate(payload.sessionId, payload.targetSessionId);
    await this.scopes.cancel(payload.sessionId);
    return { sessionId: payload.targetSessionId, sourceBoundarySeq: target.inheritedEventCount - 1 };
  }
  async continue(payload) {
    identity(payload);
    if (typeof payload.sourceSessionId !== 'string' || !payload.sourceSessionId || this.scopes.isChatOnly(payload.sessionId)) {
      throw new Error('Invalid project continuation');
    }
    const running = this.continuations.get(payload.sessionId);
    if (running) {
      if (running.requestID !== payload.requestId || running.sourceSessionID !== payload.sourceSessionId) {
        throw new Error('A different project continuation is already running');
      }
      return running.promise;
    }
    const promise = this.continueOnce(payload);
    this.continuations.set(payload.sessionId, { requestID: payload.requestId, sourceSessionID: payload.sourceSessionId, promise });
    try { return await promise; }
    finally { if (this.continuations.get(payload.sessionId)?.promise === promise) this.continuations.delete(payload.sessionId); }
  }
  async continueOnce(payload) {
    const agent = await this.sessions.agent(payload.sessionId);
    if (agent.session.header.parentSession !== payload.sourceSessionId) throw new Error('Project continuation source does not match');
    const queued = [...agent.inbox.nextTurn, ...agent.inbox.nextStep].some(message => matches(message, payload.requestId));
    const evidence = inboxEvidence(agent.session.snapshotEvents(), message => matches(message, payload.requestId));
    const recoverClaim = !queued && evidence.state === 'claimed' && !!evidence.message && agent.status === 'idle';
    if (!queued && !recoverClaim && evidence.state !== 'missing') {
      if (this.sessions.stopGate.isStopped(payload.sessionId)) throw new Error('Session was stopped');
      await this.schedules.releaseMigration(payload.sourceSessionId, payload.sessionId);
      return { accepted: true, pending: false };
    }
    if (this.sessions.stopGate.isStopped(payload.sessionId)) throw new Error('Session was stopped');
    const revision = this.sessions.stopGate.revision(payload.sessionId);
    const { group, generation } = await this.sessions.begin(payload.sessionId, agent);
    try {
      if (!queued) {
        const message = recoverClaim ? evidence.message : createUserMessage({
          source: { kind: 'bridge-continuation', requestId: payload.requestId, sourceSessionId: payload.sourceSessionId },
          content: [{ type: 'text', text: '继续处理先前用户的请求。已选择项目文件夹，已完成的步骤保持不变。' }]
        });
        agent.inbox.splice(recoverClaim ? evidence.target : 'next-turn', Infinity, 0, [message]);
      }
      if (!await this.ctx.sessions.flush(agent.session)) throw new Error('Session persistence did not acknowledge the continuation');
      if (this.sessions.stopGate.revision(payload.sessionId) === revision && !this.sessions.stopGate.isStopped(payload.sessionId)) {
        await this.schedules.releaseMigration(payload.sourceSessionId, payload.sessionId);
        if (this.sessions.stopGate.revision(payload.sessionId) === revision &&
            !this.sessions.stopGate.isStopped(payload.sessionId) && agent.inbox.hasPending && agent.status === 'idle') agent.wakeDriver();
      }
      setImmediate(() => void this.sessions.settle(payload.sessionId, agent, group, generation));
      return { accepted: true, pending: true };
    } catch (error) {
      setImmediate(() => void this.sessions.settle(payload.sessionId, agent, group, generation));
      throw error;
    }
  }
}
