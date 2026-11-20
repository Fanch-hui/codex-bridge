import { AuthState } from './auth-state.mjs';
import { ConfigurationActivation } from './configuration-activation.mjs';
import { ModelCatalog, ModelSelectionProvenance } from './model-catalog.mjs';
import { ProviderConnections } from './provider-connections.mjs';
import { ProviderStreams } from './provider-streams.mjs';
import { ModelSettings } from './settings.mjs';
import { SharedProviderCalls } from './shared-provider-calls.mjs';
import { providerSessionSymbol } from './provider-session.mjs';
import { validateSettingsWrite } from './client-settings.mjs';
import { GatewayChat } from './gateway-chat.mjs';
import { LlmError } from '@deepseek-ai/dsh-llm';

async function gatewayResult(operation) {
  try { return await operation(); }
  catch (error) {
    if (!(error instanceof LlmError)) throw error;
    const failure = error.failure;
    return { failure: { code: failure.code, message: failure.message,
      ...(failure.status === undefined ? {} : { status: failure.status }),
      ...(failure.providerRetryAfterMs === undefined ? {} : { retryAfter: failure.providerRetryAfterMs }) } };
  }
}

export class ProviderActions {
  constructor(ctx, rpc, home) {
    this.ctx = ctx;
    this.emit = (type, payload) => rpc.notify('bridge/event', { type, payload });
    this.activation = new ConfigurationActivation(home, (_id, type, payload) => this.emit(type, payload),
      'bridge-provider-configuration-activation.json');
    this.settings = new ModelSettings(ctx);
    this.selection = new ModelSelectionProvenance(ctx);
    this.connections = new ProviderConnections(ctx, this.settings, id => this.changed(id));
    this.catalog = new ModelCatalog(ctx, id => this.emit('models.changed', { providerID: id }), {
      defaultIsExplicit: () => this.selection.isExplicit(), modelDefaults: () => this.settings.modelDefaults(),
      prepareProvider: id => this.connections.prepareProvider(id),
      providerPending: id => this.connections.isProviderPending(id)
    });
    this.auth = new AuthState(ctx.chatgptSiwc, state => {
      if (!state.signingIn) this.catalog.invalidate();
      this.emit('auth.changed', state);
    });
    this.streams = new ProviderStreams(ctx);
    this.gateway = new GatewayChat(ctx);
    this.shared = new SharedProviderCalls(ctx.llm, { session: globalThis[providerSessionSymbol] });
    this.listeners = [
      ctx.on('llm/adapters-updated', () => this.changed(), { global: true }),
      ctx.on('llm/models-updated', id => { this.connections.invalidate(id); this.changed(id); }, { global: true })
    ];
  }

  changed(id) {
    this.catalog.invalidate();
    this.emit('models.changed', { providerID: id ?? '' });
  }

  async start() { await this.activation.start(); this.connections.start(); }

  async call(action, payload = {}, signal) {
    const ctx = this.ctx;
    if (action === 'provider.client.rpc') return this.clientRpc(payload);
    if (action.startsWith('provider.')) return this.shared.call(action, payload, signal);
    if (action.startsWith('connections.')) return this.connections.call(action, payload);
    switch (action) {
      case 'status': return { ready: true, engineVersion: '0.2.2-rc.3', providerOnly: true };
      case 'configuration.status': return { models: this.activation.get('models') };
      case 'runtime.applyWhenIdle': {
        await this.activation.operations.get('models');
        if (this.activation.get('models').status !== 'applied') throw new Error('模型配置尚未生效，请检查并重新保存。');
        return { applied: true };
      }
      case 'models.list': return this.catalog.list({ refresh: payload.refresh === true, priorityProvider: payload.priorityProvider });
      case 'models.discover': return { models: await ctx.llm.discoverModels('llm-pi-ai', {
        ...(payload.provider ? { provider: payload.provider } : {}), baseURL: payload.baseURL,
        api: payload.protocol === 'responses' ? 'openai-responses' : 'openai-completions',
        ...(payload.apiKey ? { apiKey: payload.apiKey } : {})
      }, signal) };
      case 'settings.get': return { ...await this.settings.get(), activation: this.activation.get('models') };
      case 'settings.save': return this.updateModels(() => this.settings.save(payload));
      case 'settings.remove': return this.updateModels(() => this.settings.remove(payload.id));
      case 'auth.status': return { chatgpt: await this.auth.snapshot() };
      case 'auth.begin': return this.beginAuth(() => ctx.chatgptSiwc.beginSignIn());
      case 'auth.addAccount': return this.beginAuth(() => ctx.chatgptSiwc.addAccount());
      case 'auth.cancel': return this.finishAuth(() => ctx.chatgptSiwc.cancelSignIn());
      case 'auth.signOut': return this.finishAuth(() => ctx.chatgptSiwc.signOut());
      case 'auth.switchAccount': return this.finishAuth(() => ctx.chatgptSiwc.switchAccount(payload.accountId));
      case 'auth.removeAccount': return this.finishAuth(() => ctx.chatgptSiwc.removeAccount(payload.accountId));
      case 'auth.refreshModels': return this.refreshAuth();
      case 'auth.setBackgroundAllowed': {
        if (typeof payload.allowed !== 'boolean') throw new Error('Invalid background access choice.');
        const status = await ctx.chatgptSiwc.setBackgroundAllowed(payload.allowed);
        this.auth.publish(status);
        return status;
      }
      case 'model.stream.open':
        if (payload.options?.sessionId !== undefined || payload.sessionHeader !== undefined) {
          throw new Error('External model requests cannot use a workbench session.');
        }
        return this.streams.open(payload);
      case 'model.stream.next': return this.streams.next(payload);
      case 'model.stream.cancel': return this.streams.cancel(payload);
      case 'gateway.stream.open': return gatewayResult(() => this.gateway.open(payload, signal));
      case 'gateway.stream.next': return gatewayResult(() => this.gateway.next(payload));
      case 'gateway.stream.cancel': return this.gateway.cancel(payload);
      default: throw new Error(`Unknown provider action: ${action}`);
    }
  }

  async clientRpc({ endpoint, payload }) {
    const args = payload?.args ?? {};
    const controller = this.ctx.settingsController;
    if (endpoint === 'settings/describe') return { ok: true, value: controller.describe() };
    if (['settings/mutate', 'settings/update', 'settings/replace'].includes(endpoint)) {
      validateSettingsWrite(controller, endpoint, args);
      const method = endpoint.slice('settings/'.length);
      const value = method === 'mutate' ? args.ops : method === 'update' ? args.patch : args.section;
      return { ok: true, value: await controller[method](args.ns, value, args.expectedRevision) };
    }
    const credentials = this.ctx.get('credentialsController');
    if (endpoint === 'credentials/describe') return { ok: true, value: await credentials.describe(args.refs) };
    if (endpoint === 'credentials/set') { await credentials.set(args.ref, args.value); return { ok: true }; }
    if (endpoint === 'credentials/unset') { await credentials.unset(args.ref); return { ok: true }; }
    throw new Error('Provider client endpoint is unavailable.');
  }

  async updateModels(operation) {
    const result = await this.activation.run('models', operation);
    this.catalog.invalidate();
    return { ...result, activation: this.activation.get('models') };
  }

  async beginAuth(operation) {
    this.auth.stop();
    const status = await operation();
    this.auth.start(status);
    return status;
  }

  async finishAuth(operation) {
    this.auth.stop();
    const status = await operation();
    this.auth.publish(status);
    return status;
  }

  async refreshAuth() {
    const status = await this.ctx.chatgptSiwc.refreshModels();
    if (!this.auth.isWatching) this.auth.publish(status);
    return status;
  }

  async dispose() {
    this.auth.stop();
    this.catalog.dispose();
    for (const remove of this.listeners) remove();
    await this.streams.dispose();
    await this.gateway.dispose();
    await this.shared.dispose();
    await this.connections.dispose();
  }
}
