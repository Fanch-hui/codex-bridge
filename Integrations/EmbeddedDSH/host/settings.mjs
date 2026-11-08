import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { writeFileAtomic } from '@deepseek-ai/dsh-atomic-write';

const refFor = id => `BRIDGE_DSH_${createHash('sha256').update(id).digest('hex').slice(0, 24).toUpperCase()}`;
const noAuthRefFor = id => `BRIDGE_DSH_NOAUTH_${createHash('sha256').update(id).digest('hex').slice(0, 24).toUpperCase()}`;
const routeFor = id => `bridge-${createHash('sha256').update(id).digest('hex').slice(0, 20)}`;
const effortIDs = new Set(['off', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max']);

export class ModelSettings {
  constructor(ctx) { this.ctx = ctx; this.pending = Promise.resolve(); }
  serialize(operation) {
    const result = this.pending.then(operation);
    this.pending = result.catch(() => {});
    return result;
  }
  defaultsPath() {
    const editor = this.ctx.get('configEditor');
    if (!editor) throw new Error('DSH profile configuration is unavailable');
    return join(dirname(editor.documentPath), 'bridge-model-defaults.json');
  }
  async modelDefaults() {
    try {
      const value = JSON.parse(await readFile(this.defaultsPath(), 'utf8'));
      if (!value || Array.isArray(value) || typeof value !== 'object') throw new Error('Invalid model defaults');
      return value;
    } catch (error) {
      if (error.code === 'ENOENT') return {};
      throw error;
    }
  }
  async writeDefaults(value) { await writeFileAtomic(this.defaultsPath(), JSON.stringify(value) + '\n', { mode: 0o600 }); }
  namespace() {
    const item = this.ctx.settingsController.describe().namespaces.find(x => x.ns === 'llm-pi-ai');
    if (!item) throw new Error('DSH model settings are unavailable');
    return item;
  }
  async get() {
    const providers = this.namespace().value.providers ?? {};
    const defaults = await this.modelDefaults();
    const connections = await Promise.all(Object.entries(providers)
      .filter(([id]) => id.startsWith('bridge-'))
      .map(async ([id, config]) => ({
        id, name: config.displayName ?? id, baseURL: config.baseURL,
        protocol: config.api === 'openai-responses' ? 'responses' : 'chat-completions',
        models: (config.models ?? []).map(model => ({ ...model,
          ...(defaults[id]?.[model.id] ? { defaultReasoningEffort: defaults[id][model.id] } : {})
        })), hasApiKey: config.apiKeyEnv && !config.apiKeyEnv.startsWith('BRIDGE_DSH_NOAUTH_')
          ? !!(await this.ctx.credentials.resolve(config.apiKeyEnv)) : false
      })));
    return { connections, chatgpt: await this.ctx.chatgptSiwc.status() };
  }
  save(input) { return this.serialize(() => this.saveConnection(input)); }
  async saveConnection(input) {
    if (!input.name?.trim() || !input.baseURL || !Array.isArray(input.models)) {
      throw new Error('Name, base URL and a model list are required');
    }
    const url = new URL(input.baseURL);
    if (!['https:', 'http:'].includes(url.protocol) || url.username || url.password || url.search || url.hash) throw new Error('Invalid API URL');
    if (!['chat-completions', 'responses'].includes(input.protocol)) throw new Error('Invalid API protocol');
    const id = input.id?.startsWith('bridge-') ? input.id : routeFor(input.id || input.name);
    const oldConfig = this.namespace().value.providers?.[id];
    const oldDefaults = await this.modelDefaults();
    const previousModels = new Map((oldConfig?.models ?? []).map(model => [model.id, model]));
    const modelDefaults = {};
    const models = input.models.map(model => {
      if (typeof model.id !== 'string' || !model.id.trim()) throw new Error('Invalid model ID');
      const previousModel = previousModels.get(model.id);
      const efforts = Object.hasOwn(model, 'reasoningEfforts') ? model.reasoningEfforts : previousModel?.reasoningEfforts;
      if (efforts !== undefined && efforts !== false && (!efforts || Array.isArray(efforts) || typeof efforts !== 'object'
        || !Object.keys(efforts).some(level => level !== 'off')
        || Object.entries(efforts).some(([level, wire]) => !effortIDs.has(level)
          || wire === null && level !== 'off' || wire !== null && (typeof wire !== 'string' || !wire)))) {
        throw new Error('Invalid model reasoning efforts');
      }
      const previousDefault = Object.hasOwn(oldDefaults[id] ?? {}, model.id) ? oldDefaults[id][model.id] : null;
      const defaultEffort = Object.hasOwn(model, 'defaultReasoningEffort') ? model.defaultReasoningEffort
        : efforts && Object.hasOwn(efforts, previousDefault) ? previousDefault : null;
      if (defaultEffort) {
        if (!efforts || !Object.hasOwn(efforts, defaultEffort)) throw new Error('Default reasoning effort is not supported by the model');
        Object.defineProperty(modelDefaults, model.id, { value: defaultEffort, enumerable: true });
      }
      return { id: model.id, ...((model.name ?? previousModel?.name) ? { name: model.name ?? previousModel.name } : {}),
        ...(model.contextWindow ? { contextWindow: model.contextWindow } : {}),
        ...(efforts === undefined ? {} : { reasoningEfforts: efforts }) };
    });
    const key = refFor(id);
    const previous = await this.ctx.credentials.resolve(key);
    if (input.apiKey) await this.ctx.credentials.set(key, input.apiKey);
    const config = {
      displayName: input.name, apiKeyEnv: input.apiKey || previous ? key : noAuthRefFor(id), baseURL: input.baseURL,
      api: input.protocol === 'responses' ? 'openai-responses' : 'openai-completions',
      models
    };
    const nextDefaults = { ...oldDefaults, [id]: modelDefaults };
    try {
      await this.ctx.settingsController.mutate('llm-pi-ai', [{ op: 'set', path: ['providers', id], value: config }]);
      try { await this.writeDefaults(nextDefaults); }
      catch (error) {
        const operation = oldConfig ? { op: 'set', path: ['providers', id], value: oldConfig } : { op: 'unset', path: ['providers', id] };
        await this.ctx.settingsController.mutate('llm-pi-ai', [operation]);
        throw error;
      }
    }
    catch (error) {
      if (input.apiKey) {
        if (previous) await this.ctx.credentials.set(key, previous.value);
        else await this.ctx.credentials.unset(key);
      }
      throw error;
    }
    return { ...(await this.get()), savedConnectionID: id };
  }
  remove(id) { return this.serialize(() => this.removeConnection(id)); }
  async removeConnection(id) {
    if (!id?.startsWith('bridge-')) throw new Error('Unknown model connection');
    await this.ctx.settingsController.mutate('llm-pi-ai', [{ op: 'unset', path: ['providers', id] }]);
    await this.ctx.credentials.unset(refFor(id));
    const defaults = await this.modelDefaults();
    if (Object.hasOwn(defaults, id)) { delete defaults[id]; await this.writeDefaults(defaults); }
    return this.get();
  }
}
