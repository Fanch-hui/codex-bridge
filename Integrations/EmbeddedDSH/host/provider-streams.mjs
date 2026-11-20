export class ProviderStreams {
  constructor(ctx) { this.ctx = ctx; this.streams = new Map(); }

  open({ id, options }) {
    if (typeof id !== 'string' || !id || this.streams.has(id) || !options || typeof options !== 'object'
        || typeof options.provider !== 'string' || typeof options.model !== 'string' || !Array.isArray(options.messages)) {
      throw new Error('Invalid model stream request');
    }
    const controller = new AbortController();
    const iterator = this.ctx.llm.stream({ ...options, signal: controller.signal })[Symbol.asyncIterator]();
    this.streams.set(id, { controller, iterator });
    return { id };
  }

  async next({ id }) {
    const stream = this.streams.get(id);
    if (!stream) throw new Error('Model stream is unavailable');
    if (stream.stopping || stream.cleanup) throw new Error('Model stream is closing');
    if (stream.pending) throw new Error('Model stream already has a pending read');
    const pending = Promise.resolve().then(() => stream.iterator.next());
    stream.pending = pending;
    let result;
    try {
      result = await pending;
    } catch (error) {
      try { await this.finish(id, stream); }
      catch (cleanup) { throw new AggregateError([error, cleanup], 'Model stream and cleanup failed'); }
      throw error;
    } finally {
      stream.pending = undefined;
    }
    if (result.done || result.value?.type === 'finish') await this.finish(id, stream, result.done);
    return result.done ? { done: true } : { done: false, chunk: result.value };
  }

  finish(id, stream, done = false) {
    if (!stream.cleanup) {
      stream.cleanup = (async () => {
        try { if (!done) await stream.iterator.return?.(); }
        finally { if (this.streams.get(id) === stream) this.streams.delete(id); }
      })();
    }
    return stream.cleanup;
  }

  async cancel({ id }) {
    const stream = this.streams.get(id);
    if (!stream) return { cancelled: false };
    stream.stopping = true;
    stream.controller.abort();
    let failure;
    try {
      if (stream.pending) await stream.pending;
    } catch (error) {
      if (error !== stream.controller.signal.reason && error?.name !== 'AbortError' && error?.code !== 'ABORT_ERR') failure = error;
    }
    try { await this.finish(id, stream); }
    catch (cleanup) {
      if (failure) throw new AggregateError([failure, cleanup], 'Model stream and cleanup failed');
      throw cleanup;
    }
    if (failure) throw failure;
    return { cancelled: true };
  }

  async dispose() {
    const results = await Promise.allSettled([...this.streams.keys()].map(id => this.cancel({ id })));
    const errors = results.filter(result => result.status === 'rejected').map(result => result.reason);
    if (errors.length === 1) throw errors[0];
    if (errors.length) throw new AggregateError(errors, 'Model stream cleanup failed');
  }
}
