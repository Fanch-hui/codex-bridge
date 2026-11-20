import { AsyncLocalStorage } from 'node:async_hooks';

export const providerSessionSymbol = Symbol.for('codex-bridge.provider-session');

export class ProviderSession {
  constructor(rpc) { this.rpc = rpc; this.scope = new AsyncLocalStorage(); }

  header(id) {
    const current = this.scope.getStore();
    return current?.sessionID === id ? current.header : undefined;
  }

  async confirmedResponses(options, context) {
    const current = this.scope.getStore();
    if (!current || current.sessionID !== options.sessionId) throw new Error('Provider session is unavailable.');
    const { signal, ...input } = options;
    const result = await this.rpc.request('bridge/providerSession', {
      action: 'confirmedResponses', streamID: current.streamID, sessionID: current.sessionID, options: input, context
    }, signal);
    if (!Array.isArray(result.ids) || result.ids.some(id => typeof id !== 'string')) {
      throw new Error('Invalid provider session confirmation.');
    }
    return new Set(result.ids);
  }

  run(scope, operation) { return this.scope.run(scope, operation); }
}
