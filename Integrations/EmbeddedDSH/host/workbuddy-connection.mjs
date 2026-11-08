import { createHash } from 'node:crypto';

export const workbuddyProvider = 'workbuddy-manager-session';
const referencePattern = /^WORKBUDDY_MANAGER_BRIDGE_[A-F0-9]{32}$/;
const fileID = file => `workbuddy-${createHash('sha256').update(file).digest('hex').slice(0, 32)}.json`;
const accountActions = new Set(['accountDisabled', 'accountDelete', 'accountRefresh', 'accountCheckin']);
const modelActions = new Set(['authDesktop', 'authKey', 'accountDisabled', 'accountDelete', 'accountRefresh', 'gatewayOptions', 'sync']);

function loginURL(value) {
  const url = new URL(value);
  if (url.protocol !== 'https:' || url.username || url.password || url.port) throw new Error('WorkBuddy 登录地址无效，请重新登录。');
  return url.href;
}

function gatewayURL(value) {
  const address = new URL(value);
  if (address.protocol !== 'http:' || address.hostname !== '127.0.0.1' || address.username || address.password
    || address.search || address.hash) throw new Error('WorkBuddy 本机模型连接无效。');
  address.pathname = `${address.pathname.replace(/\/+$/, '').replace(/\/v1$/, '')}/v1`;
  return address.href.replace(/\/$/, '');
}

function publicAccount(account) {
  return { ...account, file: fileID(account.file),
    ...(account.source === 'key' && /^API Key \(/.test(account.nickname) ? { nickname: 'WorkBuddy API Key' } : {}) };
}

function publicResult(result) {
  return { ...result,
    ...(result?.account ? { account: publicAccount(result.account) } : {}),
    ...(Array.isArray(result?.results) ? { results: result.results.map(row => ({ ...row, file: fileID(row.file) })) } : {}) };
}

function mergeModels(previous, discovered) {
  const existing = new Map((previous ?? []).map(model => [model.id, model]));
  return discovered.map(model => {
    const old = existing.get(model.id);
    return old ? { ...model, ...old } : model;
  });
}

export class WorkBuddyConnection {
  constructor(ctx, settings, changed) {
    this.ctx = ctx;
    this.settings = settings;
    this.changed = changed;
    this.pending = Promise.resolve();
    this.modelError = undefined;
  }

  get service() {
    const service = this.ctx.get('workbuddyManager');
    if (!service) throw new Error('WorkBuddy 服务暂不可用，请重启工作台。');
    return service;
  }

  serialize(operation) {
    const task = this.pending.then(operation);
    this.pending = task.catch(() => {});
    return task;
  }

  start() {
    let resolveBinding;
    this.bindingReady = new Promise(resolve => { resolveBinding = resolve; });
    this.bindingState = 'pending';
    const finishBinding = bound => {
      if (this.bindingState !== 'pending') return;
      this.bindingState = bound ? 'ready' : 'unavailable';
      resolveBinding(bound);
    };
    this.restored = this.serialize(async () => {
      const provider = this.settings.namespace().value.providers?.[workbuddyProvider];
      const overview = await this.service.manage({ action: 'overview' });
      if (!provider && !overview.accounts.length) {
        finishBinding(false);
        this.changed(workbuddyProvider);
        return;
      }
      await this.updateModels(overview, () => {
        this.modelError = undefined;
        finishBinding(true);
        this.changed(workbuddyProvider);
      });
      finishBinding(false);
      this.changed(workbuddyProvider);
    }).catch(() => {
      this.modelError = 'WorkBuddy 模型连接恢复失败，请同步模型。';
      finishBinding(false);
      this.changed(workbuddyProvider);
    });
  }

  async prepareProvider(provider) {
    if (provider !== workbuddyProvider) return;
    const bound = await this.bindingReady;
    const overview = await this.service.manage({ action: 'overview' });
    if (!overview.poolAvailable) throw new Error('请先连接可用的 WorkBuddy 账号。');
    if (bound === false && this.modelError) throw new Error(this.modelError);
    const configured = this.settings.namespace().value.providers?.[workbuddyProvider];
    if (!configured || configured.baseURL !== gatewayURL(overview.gatewayURL)) {
      throw new Error('WorkBuddy 模型连接需要同步，请在模型连接中重试。');
    }
  }

  async overview() {
    const value = await this.service.manage({ action: 'overview' });
    return { ...value, accounts: value.accounts.map(publicAccount) };
  }

  call(input) {
    return this.serialize(async () => {
      if (!input || typeof input !== 'object' || Array.isArray(input)) throw new Error('WorkBuddy 管理请求无效。');
      const request = { ...input };
      if (accountActions.has(request.action) && request.file !== undefined) {
        const current = await this.service.manage({ action: 'overview' });
        const account = current.accounts.find(item => fileID(item.file) === request.file);
        if (!account) throw new Error('WorkBuddy 账号已变化，请刷新后重试。');
        request.file = account.file;
      }
      if (request.action === 'authKey' && !request.nickname?.trim()) request.nickname = 'WorkBuddy API Key';
      const result = request.action === 'sync' ? {} : await this.service.manage(request);
      if (request.action === 'authStart') result.authUrl = loginURL(result.authUrl);
      const overview = await this.service.manage({ action: 'overview' });
      if (modelActions.has(request.action) || request.action === 'authPoll' && result.status === 'success') {
        try { if (await this.updateModels(overview)) this.modelError = undefined; }
        catch { this.modelError = '账号设置已保存，WorkBuddy 模型同步失败，请检查账号和模型筛选后重试。'; }
        this.changed(workbuddyProvider);
      }
      return { result: publicResult(result), overview: { ...overview, accounts: overview.accounts.map(publicAccount) },
        ...(this.modelError ? { modelError: this.modelError } : {}) };
    });
  }

  async updateModels(overview, onBindingReady = () => {}) {
    if (!overview.poolAvailable) {
      this.modelError = '请先连接可用的 WorkBuddy 账号。';
      return false;
    }
    const bridge = await this.service.manage({ action: 'bridge' });
    if (!referencePattern.test(bridge.ref) || !bridge.models?.length) {
      throw new Error('WorkBuddy 本机模型连接无效。');
    }
    const baseURL = gatewayURL(bridge.url);
    await this.saveModels(baseURL, bridge.ref, bridge.models);
    onBindingReady();
    const discovered = await this.ctx.llm.discoverModels('llm-pi-ai', {
      provider: workbuddyProvider, baseURL, api: 'openai-completions'
    });
    const models = discovered.filter(model => typeof model.id === 'string' && model.id).map(model => ({
      id: model.id, ...(model.name ? { name: model.name } : {}),
      ...(model.contextWindow ? { contextWindow: model.contextWindow } : {}),
      ...(model.maxTokens ? { maxTokens: model.maxTokens } : {}),
      ...(model.inputModalities?.length ? { input: model.inputModalities } : {})
    }));
    if (!models.length) throw new Error('WorkBuddy 没有返回可用模型。');
    await this.saveModels(baseURL, bridge.ref, models);
    return true;
  }

  async saveModels(baseURL, reference, discovered) {
    await this.settings.serialize(async () => {
      const namespace = this.settings.namespace();
      const current = namespace.value.providers?.[workbuddyProvider];
      if (current && !referencePattern.test(current.apiKeyEnv)) throw new Error('WorkBuddy 模型连接标识已被占用。');
      const models = mergeModels(current?.models, discovered);
      const fields = { baseURL, api: 'openai-completions', apiKeyEnv: reference, models };
      const operations = current ? Object.entries(fields).filter(([key, value]) =>
        JSON.stringify(current[key]) !== JSON.stringify(value)).map(([key, value]) => ({
          op: 'set', path: ['providers', workbuddyProvider, key], value
        })) : [{ op: 'set', path: ['providers', workbuddyProvider], value: {
          displayName: 'WorkBuddy 账号池', ...fields, defaultContextWindow: 131072, defaultMaxTokens: 32768
        } }];
      if (operations.length) await this.ctx.settingsController.mutate('llm-pi-ai', operations, namespace.revision);
    });
  }
}
