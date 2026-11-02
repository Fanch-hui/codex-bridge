import { readFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { writeFileAtomic } from '@deepseek-ai/dsh-atomic-write';

const timedOut = Symbol('timed out');

function deadline(promise, milliseconds) {
  let timer;
  return Promise.race([
    promise,
    new Promise(resolve => { timer = setTimeout(resolve, milliseconds, timedOut); timer.unref(); })
  ]).finally(() => clearTimeout(timer));
}

export class ModelSelectionProvenance {
  constructor(ctx) { this.ctx = ctx; }

  editor() {
    const editor = this.ctx.get('configEditor');
    if (!editor) throw new Error('DSH profile configuration is unavailable');
    return editor;
  }

  markerPath(editor) { return join(dirname(editor.documentPath), 'bridge-model-selection.json'); }

  async markerExists(editor) {
    try {
      if (JSON.parse(await readFile(this.markerPath(editor), 'utf8')) !== true) {
        throw new Error('Invalid DSH model selection marker');
      }
      return true;
    } catch (error) {
      if (error.code === 'ENOENT') return false;
      throw error;
    }
  }

  async isExplicit() {
    const editor = this.editor();
    if (await this.markerExists(editor)) return true;
    const row = editor.configuration().find(item => item.entry.options.id === 'agent-default-model'
      && item.entry.options.name === '@deepseek-ai/dsh-agent-default-model');
    if (!row) throw new Error('DSH default model configuration is unavailable');
    return ['provider', 'model', 'reasoningEffort'].some(key => Object.hasOwn(row.override, key));
  }

  async markExplicit() {
    const editor = this.editor();
    if (await this.markerExists(editor)) return;
    await writeFileAtomic(this.markerPath(editor), 'true\n', { mode: 0o600 });
  }
}

export class ModelCatalog {
  constructor(ctx, emit, { timeoutMs = 2500, defaultIsExplicit = () => true, modelDefaults = async () => ({}) } = {}) {
    this.ctx = ctx;
    this.emit = emit;
    this.timeoutMs = timeoutMs;
    this.defaultIsExplicit = defaultIsExplicit;
    this.modelDefaults = modelDefaults;
    this.generation = 0;
    this.pending = new Map();
    this.cached = new Map();
    this.settled = new Map();
    this.disposed = false;
  }

  invalidate() {
    this.generation++;
    this.pending.clear();
    this.cached.clear();
    this.settled.clear();
  }

  dispose() { this.disposed = true; this.invalidate(); }

  async list({ refresh = false } = {}) {
    while (!this.disposed) {
      const generation = this.generation;
      const providers = this.ctx.llm.listProviders();
      const results = await Promise.all(providers.map(provider => this.withDeadline(provider, refresh)));
      const defaultIsExplicit = await this.defaultIsExplicit();
      const defaults = await this.modelDefaults();
      if (generation !== this.generation) continue;
      const groups = results.flatMap(result => result.group?.models.length ? [result.group] : []).map(group => ({
        ...group, models: group.models.map(model => {
          const effort = defaults[group.id]?.[model.id];
          return effort && model.reasoning?.efforts.some(item => item.id === effort)
            ? { ...model, reasoning: { ...model.reasoning, defaultEffort: effort } } : model;
        })
      }));
      return {
        default: { ...this.ctx.agentDefaultModel.currentSelection() },
        defaultIsExplicit,
        routableProviders: groups.map(group => group.id),
        groups,
        failures: results.flatMap(result => result.failure ? [result.failure] : [])
      };
    }
    throw new Error('Model catalog is closed');
  }

  async withDeadline(provider, refresh) {
    let entry = this.pending.get(provider.id);
    const completed = this.settled.get(provider.id);
    if (!entry && completed && !refresh) return this.withPrevious(provider.id, completed);
    if (!entry) entry = this.begin(provider);
    const result = await deadline(entry.promise, this.timeoutMs);
    if (result !== timedOut) {
      return this.withPrevious(provider.id, result);
    }
    entry.timedOut = true;
    return this.cached.get(provider.id) ?? {
      failure: { id: provider.id, name: provider.name, message: '模型目录响应较慢，请稍后重试。' }
    };
  }

  withPrevious(providerID, result) {
    const previous = this.cached.get(providerID);
    return result.failure && previous ? { ...previous, failure: result.failure } : result;
  }

  begin(provider) {
    const generation = this.generation;
    const entry = { timedOut: false };
    entry.promise = this.read(provider).then(result => {
      if (!this.disposed && this.generation === generation && this.pending.get(provider.id) === entry) {
        if (result.group) this.cached.set(provider.id, result);
        this.settled.set(provider.id, result);
        this.pending.delete(provider.id);
        if (entry.timedOut) this.emit(provider.id);
      }
      return result;
    });
    this.pending.set(provider.id, entry);
    return entry;
  }

  async read(provider) {
    try {
      if (provider.id === 'chatgpt-siwc') await this.prepareChatGPT();
      const models = await this.ctx.llm.listModels(provider.id);
      const entries = await Promise.all(models.map(async model => {
        const resolved = await this.ctx.llm.resolveModelInfo(provider.id, model.id);
        const reasoning = resolved.reasoning && {
          efforts: resolved.reasoning.efforts.map(effort => ({
            id: effort.id, name: effort.name, ...(effort.description === undefined ? {} : { description: effort.description })
          })),
          ...(resolved.reasoning.defaultEffort === undefined ? {} : { defaultEffort: resolved.reasoning.defaultEffort })
        };
        return { id: model.id, name: model.name, ...(model.description === undefined ? {} : { description: model.description }),
          ...(reasoning === undefined ? {} : { reasoning }) };
      }));
      return { group: { id: provider.id, name: provider.name, models: entries } };
    } catch (error) {
      return { failure: { id: provider.id, name: provider.name, message: error instanceof Error ? error.message : String(error) } };
    }
  }

  async prepareChatGPT() {
    let status = await this.ctx.chatgptSiwc.status();
    if (!status.authenticated || !status.planEnabled) throw new Error('请先连接 ChatGPT。');
    if (status.models?.length) return;
    if (status.signingIn) throw new Error('正在连接 ChatGPT。');
    status = await this.ctx.chatgptSiwc.refreshModels();
    if (status.availability !== 'ready' || status.error) throw new Error('ChatGPT 模型目录暂不可用，请刷新后重试。');
  }
}
