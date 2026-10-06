import z from '@deepseek-ai/schemastery';
import { Service } from '@deepseek-ai/cordis';
import { createConnector } from './connector.mjs';

export const inject = ['credentials', 'sessionController', 'workspaceController', 'agentDefaultModel', 'agents', 'llm', 'connection', 'profileContext'];
export const Config = z.object({ descriptorPath: z.string().required() });
export async function apply(ctx, config) {
  const connector = await createConnector(ctx, config);
  ctx.effect(() => () => connector.close());
  new class extends Service { constructor() { super(ctx, 'codexBridgeDesktop'); Object.assign(this, connector); } }();
  // The shared API carrier applies native Client authentication before exact Fetch routes.
  const unregister = ctx.connection.fetch.register({
    path: '/api/codex-bridge-desktop', methods: ['POST'], requestBody: 'buffered',
    async fetch(request) {
      let message;
      try { message = await request.json(); }
      catch { return new Response('Invalid request', { status: 400 }); }
      if (message.type !== 'client-request' || typeof message.rpcId !== 'string' || message.method !== 'codex-bridge-desktop') return new Response('Invalid envelope', { status: 400 });
      let result;
      try { result = { ok: true, value: await connector.clientRpc(message.payload?.method, message.payload?.params ?? {}, request.signal) }; }
      catch (error) { result = { ok: false, error: { code: error.code ?? 'connector_failed', message: error.message, details: {} } }; }
      return Response.json({ type: 'server-response', rpcId: message.rpcId, result });
    },
  });
  ctx.effect(() => () => unregister());
}
