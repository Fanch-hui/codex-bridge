import { randomUUID } from 'node:crypto';
import { HarnessError, LlmError } from '@deepseek-ai/dsh-llm';
import { ProviderStreams } from './provider-streams.mjs';
import { imagePolicySnapshot } from './provider-image-policy.mjs';

const preparedCall = Symbol('shared-provider-prepared-call');

// This adapter boundary is intentionally separate from the provider host's normal
// llm.stream entry: the workbench already owns its own DSH middleware pipeline.
export class SharedProviderCalls {
  constructor(llm, { registration = id => llm.registration(id), prepareLifetimeMs = 60_000, session } = {}) {
    this.llm = llm;
    this.registration = registration;
    this.prepareLifetimeMs = prepareLifetimeMs;
    this.session = session;
    this.adapterIDs = new WeakMap();
    this.prepared = new Map();
    this.streams = new ProviderStreams({ llm: { stream(options) {
      const { [preparedCall]: entry, signal, ...input } = options;
      const stream = entry.value.stream({ ...input, signal: AbortSignal.any([entry.controller.signal, signal]) });
      if (!entry.scope || !session) return stream;
      return { [Symbol.asyncIterator]() {
        const iterator = stream[Symbol.asyncIterator]();
        return {
          next: value => session.run(entry.scope, () => iterator.next(value)),
          return: value => session.run(entry.scope, () => iterator.return?.(value) ?? { done: true }),
          throw: error => session.run(entry.scope, () => iterator.throw(error))
        };
      } };
    } } });
    this.revision = 0;
  }

  adapterID(adapter) {
    let id = this.adapterIDs.get(adapter);
    if (!id) this.adapterIDs.set(adapter, id = randomUUID());
    return id;
  }

  snapshot() {
    const groups = new Map();
    for (const provider of this.llm.listProviders()) {
      const registration = this.registration(provider.id);
      const group = this.adapterID(registration.adapter);
      let routes = groups.get(group);
      if (!routes) groups.set(group, routes = { adapter: registration.adapter, routes: [] });
      routes.routes.push({ ...provider, retryPolicy: registration.retryPolicy });
    }
    return { revision: ++this.revision, groups: [...groups].map(([id, group]) => ({ id, routes: group.routes,
      imagePolicy: imagePolicySnapshot(group.adapter, group.routes) })),
      configurableProviders: this.llm.listConfigurableProviders?.() ?? [] };
  }

  route({ group, provider }) {
    const registration = this.registration(provider);
    if (!registration || this.adapterID(registration.adapter) !== group) {
      throw new Error('Provider route changed; refresh the model catalog.');
    }
    return registration;
  }

  async listModels(input) {
    const registration = this.route(input);
    const result = await this.llm.listModels(input.provider);
    if (this.route(input).adapter !== registration.adapter) throw new Error('Provider route changed.');
    return result;
  }

  async resolveModel(input, signal) {
    const registration = this.route(input);
    const result = await this.llm.resolveModelInfo(input.provider, input.model, signal);
    if (this.route(input).adapter !== registration.adapter) throw new Error('Provider route changed.');
    return result;
  }

  async prepare(input, signal) {
    const registration = this.route(input);
    const controller = new AbortController();
    const abort = () => controller.abort(signal.reason);
    if (signal?.aborted) throw signal.reason;
    signal?.addEventListener('abort', abort, { once: true });
    try {
      const value = await registration.adapter.prepareCall(input.provider, input.model, controller.signal);
      controller.signal.throwIfAborted();
      if (!value || typeof value.stream !== 'function' || value.model?.provider !== input.provider ||
          value.model?.id !== input.model || typeof value.model.name !== 'string') {
        throw new Error('Provider returned invalid prepared model.');
      }
      const handle = randomUUID();
      const entry = { value, controller, group: input.group, provider: input.provider, model: input.model };
      entry.timer = setTimeout(() => this.release({ handle }), this.prepareLifetimeMs);
      entry.timer.unref();
      this.prepared.set(handle, entry);
      return { handle, model: value.model };
    } catch (error) {
      controller.abort();
      throw error;
    } finally {
      signal?.removeEventListener('abort', abort);
    }
  }

  release({ handle }) {
    const entry = this.prepared.get(handle);
    if (!entry) return { released: false };
    this.prepared.delete(handle);
    clearTimeout(entry.timer);
    entry.controller.abort();
    return { released: true };
  }

  open({ id, handle, options, sessionHeader }) {
    const entry = this.prepared.get(handle);
    if (!entry || options?.provider !== entry.provider || options?.model !== entry.model) {
      throw new Error('Prepared provider call is unavailable.');
    }
    if (options.sessionId !== undefined) {
      if (typeof options.sessionId !== 'string' || !options.sessionId || !sessionHeader || typeof sessionHeader !== 'object') {
        throw new Error('Workbench session header is unavailable.');
      }
      entry.scope = { streamID: id, sessionID: options.sessionId, header: sessionHeader };
    } else if (sessionHeader !== undefined) throw new Error('Unexpected workbench session header.');
    const result = this.streams.open({ id, options: { ...options, [preparedCall]: entry } });
    this.prepared.delete(handle);
    clearTimeout(entry.timer);
    return result;
  }

  async call(action, payload = {}, signal) {
    try {
      switch (action) {
        case 'provider.snapshot': return this.snapshot();
        case 'provider.listModels': return await this.listModels(payload);
        case 'provider.resolveModel': return await this.resolveModel(payload, signal);
        case 'provider.prepare': return await this.prepare(payload, signal);
        case 'provider.release': return this.release(payload);
        case 'provider.stream.open': return this.open(payload);
        case 'provider.stream.next': return await this.streams.next(payload);
        case 'provider.stream.cancel': return await this.streams.cancel(payload);
        default: throw new Error(`Unknown shared provider action: ${action}`);
      }
    } catch (error) {
      if (error instanceof LlmError) return { $providerFailure: error.failure };
      if (error instanceof HarnessError) return { $providerFailure: { message: error.message, code: error.code } };
      throw error;
    }
  }

  async dispose() {
    for (const handle of this.prepared.keys()) this.release({ handle });
    await this.streams.dispose();
  }
}
