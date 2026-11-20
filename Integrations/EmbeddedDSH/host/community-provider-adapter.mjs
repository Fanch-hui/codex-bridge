import { PiAiAdapter } from '@deepseek-ai/dsh-llm-pi-ai';
import { LlmAdapter, resolveImageAttachmentAccess, resolveRetryPolicy } from '@deepseek-ai/dsh-llm';
import { requestImageDimensions } from '@deepseek-ai/dsh-attachment';
import { openAICompletionsApi } from '@earendil-works/pi-ai/api/openai-completions.lazy';

const api = openAICompletionsApi();
const noCost = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 };
const retryPolicy = resolveRetryPolicy({ mode: 'normal', maxRetries: 0 }, 'community provider');
// The service gateway owns request deadlines for these routes.
const gatewayStreamIdleTimeoutMs = 2 ** 31 - 1;

export class CommunityProviderAdapter extends LlmAdapter {
  constructor(ctx, call, routes) {
    super();
    this.ctx = ctx;
    this.call = call;
    this.setRoutes(routes);
  }

  setRoutes(routes) {
    this.routes = new Map(routes.map(route => [route.id, route]));
  }

  route(provider) {
    const route = this.routes.get(provider);
    if (!route) throw new Error('Community provider is unavailable.');
    return route;
  }

  model(provider, id) {
    const model = this.route(provider).models.find(item => item.id === id);
    if (!model) throw new Error('Community model is unavailable.');
    return model;
  }

  providerInfo(provider) {
    const route = this.route(provider);
    return { id: provider, name: route.name };
  }

  providerRetryPolicy(provider) {
    this.route(provider);
    return retryPolicy;
  }

  listModels(provider) {
    return Promise.resolve(this.route(provider).models.map(model => this.modelInfo(provider, model)));
  }

  resolveModel(provider, id) {
    return Promise.resolve(this.modelInfo(provider, this.model(provider, id)));
  }

  modelInfo(provider, model) {
    return { provider, id: model.id, name: model.name,
      inputModalities: model.images ? ['text', 'image'] : ['text'],
      ...(model.contextWindow ? { context: { contextWindow: model.contextWindow } } : {}),
      ...(model.maxTokens ? { defaultMaxTokens: model.maxTokens } : {}) };
  }

  async prepareCall(provider, id, signal) {
    signal?.throwIfAborted();
    const model = this.model(provider, id);
    const route = this.route(provider);
    const endpoint = await this.call('community.gateway.endpoint', {}, signal);
    signal?.throwIfAborted();
    const descriptor = { id, name: model.name, provider, api: 'openai-completions',
      baseUrl: endpoint.baseURL, reasoning: false,
      input: model.images ? ['text', 'image'] : ['text'], cost: noCost,
      contextWindow: model.contextWindow ?? 1000000, maxTokens: model.maxTokens ?? 128000 };
    const piProvider = {
      id: provider, name: route.name, baseUrl: endpoint.baseURL,
      auth: { apiKey: { name: route.name, resolve: ({ credential }) => Promise.resolve({
        auth: credential?.key ? { apiKey: credential.key } : {}, source: route.name }) } },
      getModels: () => [descriptor],
      stream: (...args) => api.stream(...args),
      streamSimple: (model, context, options) => api.streamSimple(model, context, {
        ...options,
        onPayload: async (body, descriptor) => {
          const projected = await options.onPayload?.(body, descriptor) ?? body;
          if (options.maxTokens === undefined) {
            delete projected.max_tokens;
            delete projected.max_completion_tokens;
          }
          return projected;
        }
      })
    };
    const profile = { piProvider, displayName: route.name, modelErrors: new Map(),
      configuredMaxTokens: new Map(model.maxTokens ? [[id, model.maxTokens]] : []),
      streamIdleTimeoutMs: gatewayStreamIdleTimeoutMs, maxRequestImageBytes: 20971520, maxRequestImages: 50,
      imageOffloadCountQuantum: 10, requestImagePixelBudget: 4194304, requestImageMaxBytes: 1048576 };
    const profiles = new Map([[provider, profile]]);
    const adapter = new PiAiAdapter({
      profiles: () => profiles,
      resolveApiKey: async () => endpoint.token,
      auth: {},
      resolveAttachments: () => this.ctx.get('attachments'),
      resolveImageAccess: (attachments, ref) => resolveImageAttachmentAccess(
        attachments, hostPath => this.ctx.get('fs')?.processPathFromHostPath(hostPath), ref)
    });
    const prepared = await adapter.prepareCall(provider, id, signal);
    return { model: this.modelInfo(provider, model),
      stream: options => prepared.stream({ ...options, bridgeExternal: true }) };
  }

  imageRequestTarget(provider, id, image) {
    this.model(provider, id);
    return { ...requestImageDimensions(image.width, image.height, 4194304), maxBytes: 1048576 };
  }
}
