import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { writeFileAtomic } from '@deepseek-ai/dsh-atomic-write';
import { inspectSession } from './session-inspection.mjs';

export const contextPolicySymbol = Symbol.for('codex-bridge.context-policy');
export const defaultContextPolicy = Object.freeze({ contextWindow: 372000, autoCompactAt: 353000 });

function validID(id) { return typeof id === 'string' && id.length > 0 && id.length <= 512 && !/[\u0000-\u001f]/.test(id); }
function service(ctx, name) { return typeof ctx?.get === 'function' ? ctx.get(name) : ctx?.[name]; }
function validatePolicy(policy) {
  if (!policy || typeof policy !== 'object' || Array.isArray(policy) ||
      Object.keys(policy).sort().join(',') !== 'autoCompactAt,contextWindow' ||
      !Number.isSafeInteger(policy.contextWindow) || policy.contextWindow < 4096 || policy.contextWindow > 10000000 ||
      !Number.isSafeInteger(policy.autoCompactAt) || policy.autoCompactAt < 1024 || policy.autoCompactAt >= policy.contextWindow) {
    throw new Error('Invalid context policy');
  }
  return { contextWindow: policy.contextWindow, autoCompactAt: policy.autoCompactAt };
}

function effectivePolicy(policy, modelWindow, maxTokens) {
  if (!Number.isSafeInteger(modelWindow) || modelWindow < 2) return { effective: { ...policy } };
  const reserve = Number.isSafeInteger(maxTokens) && maxTokens > 0
    ? Math.min(maxTokens, Math.floor(modelWindow / 2)) : Math.min(19000, Math.floor(modelWindow / 2));
  const effective = { contextWindow: Math.min(policy.contextWindow, modelWindow),
    autoCompactAt: Math.min(policy.autoCompactAt, modelWindow - reserve) };
  return { effective, modelContextWindow: modelWindow,
    limitedByModel: effective.contextWindow !== policy.contextWindow || effective.autoCompactAt !== policy.autoCompactAt };
}

export class ContextPolicy {
  constructor(ctx, home, emit) {
    this.ctx = ctx;
    this.path = join(home, 'bridge-context-policy.json');
    this.emit = emit;
    this.state = { revision: 0, defaults: { ...defaultContextPolicy }, overrides: new Map(), aliases: new Map(), targets: new Set() };
    this.queue = Promise.resolve();
    this.steps = new WeakMap();
    this.models = new Map();
  }
  attach(ctx, emit) { this.ctx = ctx; this.emit = emit; }
  start() { return this.startup ??= this.load(); }
  async load() {
    try {
      const data = JSON.parse(await readFile(this.path, 'utf8'));
      if (!data || data.version !== 1 || !Number.isSafeInteger(data.revision) || data.revision < 0 ||
          !Array.isArray(data.overrides) || !Array.isArray(data.aliases)) throw new Error('Invalid context policy store');
      const overrides = new Map(), aliases = new Map();
      for (const row of data.overrides) {
        if (!Array.isArray(row) || row.length !== 2 || !validID(row[0]) || overrides.has(row[0])) throw new Error('Invalid context policy overrides');
        overrides.set(row[0], validatePolicy(row[1]));
      }
      for (const row of data.aliases) {
        if (!Array.isArray(row) || row.length !== 2 || !validID(row[0]) || !validID(row[1]) || aliases.has(row[0])) throw new Error('Invalid context policy aliases');
        aliases.set(row[0], row[1]);
      }
      this.state = { revision: data.revision, defaults: validatePolicy(data.defaults), overrides, aliases, targets: new Set(aliases.values()) };
    } catch (error) { if (error.code !== 'ENOENT') throw error; }
  }
  async mutate(change) {
    const task = this.queue.then(async () => {
      const next = { revision: this.state.revision, defaults: { ...this.state.defaults }, overrides: new Map(this.state.overrides),
        aliases: new Map(this.state.aliases), targets: new Set(this.state.targets) };
      const changed = change(next);
      if (!changed) return false;
      const serialized = { version: 1, revision: next.revision, defaults: next.defaults, overrides: [...next.overrides], aliases: [...next.aliases] };
      await writeFileAtomic(this.path, `${JSON.stringify(serialized)}\n`, { mode: 0o600, dirMode: 0o700 });
      this.state = next;
      return true;
    });
    this.queue = task.catch(() => {});
    return task;
  }
  async bind({ sessionId, contextSessionId }) {
    if (!validID(sessionId) || !validID(contextSessionId)) throw new Error('Invalid context session binding');
    await this.mutate(next => {
      if (next.aliases.get(sessionId) === contextSessionId) return false;
      next.aliases.set(sessionId, contextSessionId);
      next.targets = new Set(next.aliases.values());
      return true;
    });
    return { sessionId, contextSessionId };
  }
  liveSession(id, ctx = this.ctx) { return service(ctx, 'sessions')?.get(id) ?? service(ctx, 'agents')?.get(id)?.session; }
  logicalID(id, header, ctx = this.ctx) {
    const seen = new Set();
    while (id) {
      if (seen.has(id)) throw new Error('Invalid context session lineage');
      seen.add(id);
      const alias = this.state.aliases.get(id);
      if (alias) return alias;
      if (this.state.targets.has(id)) return id;
      const meta = header ?? this.liveSession(id, ctx)?.header;
      if (meta?.origin !== 'subagent' || !meta.parentSession) return id;
      id = meta.parentSession;
      header = undefined;
    }
    return id;
  }
  async resolveID(id, header, signal) {
    const seen = new Set();
    while (id) {
      if (seen.has(id)) throw new Error('Invalid context session lineage');
      seen.add(id);
      const alias = this.state.aliases.get(id);
      if (alias) return alias;
      if (this.state.targets.has(id)) return id;
      let meta = header ?? this.liveSession(id)?.header;
      if (!meta && this.ctx.sessionQuery) {
        try { meta = (await inspectSession(this.ctx, id, signal)).meta; }
        catch (error) { if (!['session/not-found', 'ENOENT'].includes(error.code)) throw error; }
      }
      if (meta?.origin !== 'subagent' || !meta.parentSession) return id;
      id = meta.parentSession;
      header = undefined;
    }
    return id;
  }
  view(id, modelWindow, maxTokens, modelSelection) {
    const override = id ? this.state.overrides.get(id) : undefined;
    const defaults = { ...this.state.defaults };
    return { revision: this.state.revision, defaults, override: override ? { ...override } : null,
      ...effectivePolicy(override ?? defaults, modelWindow, maxTokens), source: override ? 'session' : 'global',
      ...(modelSelection?.provider && modelSelection?.model ? { modelSelection: { provider: modelSelection.provider, model: modelSelection.model } } : {}) };
  }
  async get({ sessionId } = {}, signal) {
    if (sessionId === undefined) return this.view();
    if (!validID(sessionId)) throw new Error('Invalid context session');
    const id = await this.resolveID(sessionId, undefined, signal);
    signal?.throwIfAborted();
    const agent = this.ctx.agents?.get(sessionId);
    let selection = agent?.model.current();
    if (!agent && this.ctx.sessionController) {
      const projections = await this.ctx.sessionController.projections({ sessionId }, signal ?? new AbortController().signal);
      selection = projections?.values?.modelSelection?.next ?? undefined;
    }
    let model = this.models.get(sessionId);
    for (let attempt = 0; attempt < 2 && selection?.provider && selection?.model; attempt++) {
      const requested = selection;
      if (model?.provider !== requested.provider || model?.model !== requested.model) model = undefined;
      try {
        const info = await this.ctx.llm.resolveModelInfo(requested.provider, requested.model, signal);
        model = { provider: requested.provider, model: requested.model,
          contextWindow: info.context?.contextWindow, maxTokens: info.defaultMaxTokens };
      } catch (error) {
        if (signal?.aborted) throw signal.reason;
        process.stderr.write('DSH model context capacity is unavailable.\n');
      }
      selection = agent?.model.current() ?? selection;
      if (selection?.provider === requested.provider && selection?.model === requested.model) {
        if (model) this.models.set(sessionId, model);
        break;
      }
      model = undefined;
    }
    return this.view(id, model?.contextWindow, model?.maxTokens, selection);
  }
  async set({ sessionId, policy }) {
    if (sessionId !== undefined && !validID(sessionId)) throw new Error('Invalid context session');
    if (policy !== null) policy = validatePolicy(policy);
    const id = sessionId === undefined ? undefined : await this.resolveID(sessionId);
    const changed = await this.mutate(next => {
      if (next.revision === Number.MAX_SAFE_INTEGER) throw new Error('Context policy revision exhausted');
      if (id === undefined) next.defaults = policy ?? { ...defaultContextPolicy };
      else {
        const key = next.aliases.get(sessionId) ?? next.aliases.get(id) ?? id;
        if (policy === null) next.overrides.delete(key);
        else next.overrides.set(key, policy);
      }
      next.revision++;
      return true;
    });
    if (changed) this.emit(sessionId, 'context.changed', { revision: this.state.revision, ...(sessionId ? { sessionId } : {}) });
    return this.get({ sessionId });
  }
  beginStep(agent, pending = []) {
    const context = this.ctx ?? agent.ctx;
    const id = this.logicalID(agent.session.id, agent.session.header, context);
    const view = this.view(id);
    const meter = service(context, 'tokenMeter');
    const pendingTokens = pending.reduce((total, message) => total + meter.estimateMessage(message), 0);
    this.steps.set(agent, { id, revision: view.revision, defaults: view.defaults, override: view.override,
      source: view.source, pendingTokens });
  }
  modelChanged(sessionId) {
    this.models.delete(sessionId);
    this.emit(sessionId, 'context.changed', { sessionId, revision: this.state.revision });
  }
  step(agent, modelWindow, maxTokens, route) {
    if (!this.steps.has(agent)) this.beginStep(agent);
    const snapshot = this.steps.get(agent);
    const selection = route ?? agent.model?.current?.();
    const previous = this.models.get(agent.session.id);
    if (maxTokens === undefined && previous?.contextWindow === modelWindow &&
        previous?.provider === selection?.provider && previous?.model === selection?.model) maxTokens = previous.maxTokens;
    const result = { revision: snapshot.revision, defaults: snapshot.defaults, override: snapshot.override,
      source: snapshot.source, pendingTokens: snapshot.pendingTokens,
      ...effectivePolicy(snapshot.override ?? snapshot.defaults, modelWindow, maxTokens) };
    if (Number.isSafeInteger(modelWindow)) {
      const model = { provider: selection?.provider, model: selection?.model, contextWindow: modelWindow, maxTokens };
      this.models.set(agent.session.id, model);
      if (previous?.contextWindow !== model.contextWindow || previous?.maxTokens !== model.maxTokens ||
          previous?.provider !== model.provider || previous?.model !== model.model) {
        this.emit(agent.session.id, 'context.changed', { sessionId: agent.session.id, revision: this.state.revision });
      }
    }
    return result;
  }
  async projections(sessionId, baseline, header, signal) {
    const id = await this.resolveID(sessionId, header, signal);
    const model = this.models.get(sessionId);
    const selection = this.ctx.agents?.get(sessionId)?.model.current() ?? baseline?.values?.modelSelection?.next;
    const applicable = !selection || (model?.provider === selection.provider && model?.model === selection.model) ? model : undefined;
    const view = this.view(id, applicable?.contextWindow, applicable?.maxTokens, selection);
    const values = baseline?.values ?? {};
    return { ...baseline, values: { ...values, contextPolicy: view,
      contextPressure: { ...(values.contextPressure ?? {}), contextWindow: view.effective.contextWindow } } };
  }
}
