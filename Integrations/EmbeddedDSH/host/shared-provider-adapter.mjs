import { randomUUID } from 'node:crypto';
import { LlmAdapter, LlmError } from '@deepseek-ai/dsh-llm';

// One instance represents one underlying provider adapter, preserving DSH's
// replay ownership rule when several provider routes share the same adapter.
export class SharedProviderAdapter extends LlmAdapter {
  constructor({ group, routes, call, imagePolicy, sessionHeader }) {
    super();
    this.group = group;
    this.call = call;
    this.imagePolicy = imagePolicy;
    this.sessionHeader = sessionHeader;
    this.setRoutes(routes);
  }

  setRoutes(routes) {
    const next = new Map();
    for (const route of routes) {
      if (typeof route.id !== 'string' || !route.id || typeof route.name !== 'string' || !route.name || next.has(route.id)) {
        throw new Error('Invalid shared provider route.');
      }
      next.set(route.id, { ...route });
    }
    this.routes = next;
  }

  route(provider) {
    const route = this.routes.get(provider);
    if (!route) throw new Error('Provider route is unavailable.');
    return route;
  }

  providerInfo(provider) {
    const route = this.route(provider);
    return { id: route.id, name: route.name };
  }

  providerRetryPolicy(provider) { return this.route(provider).retryPolicy; }

  async invoke(action, payload, signal) {
    const result = await this.call(action, payload, signal);
    if (result?.$providerFailure) throw LlmError.fromFailure(result.$providerFailure);
    return result;
  }

  imageRequestTarget(provider, model, image) {
    this.route(provider);
    if (!this.imagePolicy) throw new Error('Provider image projection is unavailable.');
    return this.imagePolicy.imageRequestTarget(provider, model, image);
  }

  imageRequestPricing(provider, model) {
    this.route(provider);
    if (!this.imagePolicy) throw new Error('Provider image pricing is unavailable.');
    return this.imagePolicy.imageRequestPricing(provider, model);
  }

  listModels(provider) {
    this.route(provider);
    return this.invoke('provider.listModels', { group: this.group, provider });
  }

  resolveModel(provider, model, signal) {
    this.route(provider);
    return this.invoke('provider.resolveModel', { group: this.group, provider, model }, signal);
  }

  async prepareCall(provider, model, signal) {
    this.route(provider);
    signal?.throwIfAborted();
    const prepared = await this.invoke('provider.prepare', { group: this.group, provider, model }, signal);
    const release = () => this.invoke('provider.release', { handle: prepared.handle });
    if (signal?.aborted) {
      await release();
      throw signal.reason;
    }
    let dispatched = false;
    let releasePromise;
    const releaseOnce = () => releasePromise ??= release();
    const abort = () => { if (!dispatched) void releaseOnce().catch(() => {}); };
    signal?.addEventListener('abort', abort, { once: true });
    if (signal?.aborted) abort();
    return {
      model: prepared.model,
      stream: options => {
        if (dispatched) throw new Error('A prepared provider call can only be dispatched once.');
        dispatched = true;
        signal?.removeEventListener('abort', abort);
        return this.streamPrepared(prepared.handle, options, releaseOnce, signal);
      }
    };
  }

  async *streamPrepared(handle, options, release, preparedSignal) {
    const signal = options.signal && preparedSignal
      ? AbortSignal.any([options.signal, preparedSignal]) : options.signal ?? preparedSignal;
    const { signal: _signal, ...input } = options;
    const id = randomUUID();
    let opened;
    let cancelling;
    let finished = false;
    const cancel = () => cancelling ??= (async () => {
      try { await opened; } catch { await release(); return; }
      await this.invoke('provider.stream.cancel', { id });
    })();
    const abort = () => { void cancel().catch(() => {}); };
    try {
      signal?.throwIfAborted();
      const sessionHeader = input.sessionId === undefined ? undefined : this.sessionHeader?.(input.sessionId);
      if (input.sessionId !== undefined && !sessionHeader) throw new Error('Workbench session header is unavailable.');
      opened = this.invoke('provider.stream.open', { id, handle, options: input,
        ...(sessionHeader ? { sessionHeader } : {}) });
      signal?.addEventListener('abort', abort, { once: true });
      if (signal?.aborted) abort();
      await opened;
      signal?.throwIfAborted();
      for (;;) {
        let result;
        try { result = await this.invoke('provider.stream.next', { id }); }
        catch (error) { if (signal?.aborted) throw signal.reason; throw error; }
        signal?.throwIfAborted();
        if (result.done) throw new Error('Provider stream ended without a finish event.');
        if (!result.chunk || typeof result.chunk.type !== 'string') throw new Error('Invalid provider stream chunk.');
        if (result.chunk.type === 'finish') finished = true;
        yield result.chunk;
        if (finished) return;
      }
    } finally {
      signal?.removeEventListener('abort', abort);
      if (opened) {
        if (!finished) await cancel();
        else if (cancelling) await cancelling;
      } else {
        await release();
      }
    }
  }
}
