import { WebError } from '@deepseek-ai/dsh-web';

export const name = 'bridge-search';
export const inject = ['web'];

export function apply(ctx) {
  const rpc = globalThis[Symbol.for('codex-bridge.rpc')];
  ctx.web.registerSearchProvider({
    id: name,
    title: 'Codex Bridge',
    available: () => true,
    async ready() {
      try {
        const { provider } = await rpc.request('bridge/workbenchSearch', { operation: 'settings' });
        return typeof provider === 'string';
      } catch {
        ctx.logger.warn('Unable to read workbench search settings');
        return false;
      }
    },
    async search({ query }, signal) {
      try {
        const { results } = await rpc.request('bridge/workbenchSearch', { operation: 'search', query }, signal);
        const sources = results.map(({ title, url, description }) => ({ title, url, snippet: description }));
        return { sources, truncated: false };
      } catch (error) {
        signal?.throwIfAborted();
        throw new WebError(error.message, 'WEB_PROVIDER_FAILED');
      }
    }
  });
}
