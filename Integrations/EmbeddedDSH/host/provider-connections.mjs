import { WorkBuddyConnection, workbuddyProvider } from './workbuddy-connection.mjs';

const platforms = new Set(['bigmodel', 'zai']);
const plans = new Set(['coding-plan', 'start-plan']);
const platformMethods = new Set(['beginLogin', 'cancelLogin', 'disconnect', 'refreshModels', 'readQuota', 'refreshQuota']);
const loginHosts = {
  bigmodel: new Set(['zcode.z.ai', 'bigmodel.cn', 'open.bigmodel.cn']),
  zai: new Set(['zcode.z.ai', 'chat.z.ai'])
};
const zcodeRoutes = new Map([
  ['zcode-bigmodel', ['bigmodel', 'coding-plan']], ['zcode-zai', ['zai', 'coding-plan']],
  ['zcode-bigmodel-start-plan', ['bigmodel', 'start-plan']], ['zcode-zai-start-plan', ['zai', 'start-plan']]
]);

function validateStatus(status) {
  for (const account of status.accounts) {
    if (!account.login) continue;
    const url = new URL(account.login.authorizeUrl);
    if (url.protocol !== 'https:' || url.username || url.password || url.port || !loginHosts[account.platform]?.has(url.hostname)) {
      throw new Error('ZCode 登录地址无效，请重新登录。');
    }
  }
  return status;
}

export class ProviderConnections {
  constructor(ctx, settings, changed) {
    this.ctx = ctx;
    this.changed = changed;
    this.workbuddy = new WorkBuddyConnection(ctx, settings, changed);
  }

  start() { this.workbuddy.start(); }
  async dispose() { await this.workbuddy.pending; }
  isProviderPending(id) { return id === workbuddyProvider && this.workbuddy.bindingState === 'pending'; }
  invalidate(provider) { if (!provider || zcodeRoutes.has(provider)) this.readingZcode = undefined; }
  async prepareProvider(id) {
    const route = zcodeRoutes.get(id);
    if (!route) return this.workbuddy.prepareProvider(id);
    const status = await this.zcodeStatus();
    return status.accounts.some(account => account.platform === route[0] && (account.plan ?? 'coding-plan') === route[1]
      && ['ready', 'quota_exhausted'].includes(account.state));
  }

  get zcode() {
    const service = this.ctx.get('zcode');
    if (!service) throw new Error('ZCode 服务暂不可用，请重启工作台。');
    return service;
  }

  zcodeStatus() {
    if (this.readingZcode) return this.readingZcode;
    const request = this.zcode.status().then(validateStatus);
    this.readingZcode = request;
    return request.finally(() => { if (this.readingZcode === request) this.readingZcode = undefined; });
  }

  async status() {
    const [zcode, workbuddy] = await Promise.all([this.zcodeStatus(), this.workbuddy.overview()]);
    return { zcode, workbuddy,
      ...(this.workbuddy.modelError ? { errors: { workbuddy: this.workbuddy.modelError } } : {}) };
  }

  async zcodeAction({ method, platform, plan, key }) {
    if (method === 'status') return this.zcodeStatus();
    if (!platforms.has(platform) || plan !== undefined && !plans.has(plan)) throw new Error('ZCode 平台或套餐无效。');
    this.invalidate();
    let result;
    if (method === 'useApiKey') {
      if (typeof key !== 'string' || !key.trim() || key.length > 4096) throw new Error('请输入有效的 ZCode API Key。');
      result = await this.zcode.useApiKey({ platform, key });
    } else if (platformMethods.has(method)) result = await this.zcode[method](platform, plan);
    else throw new Error('ZCode 操作无效。');
    this.invalidate();
    if (!['beginLogin', 'cancelLogin', 'readQuota', 'refreshQuota'].includes(method)) this.changed();
    return validateStatus(result);
  }

  async call(action, payload) {
    switch (action) {
      case 'connections.status': return this.status();
      case 'connections.zcode': return this.zcodeAction(payload);
      case 'connections.workbuddy': return this.workbuddy.call(payload.request);
      default: throw new Error('模型连接操作无效。');
    }
  }
}
