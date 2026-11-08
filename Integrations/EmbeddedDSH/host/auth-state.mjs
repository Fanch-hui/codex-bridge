import { setTimeout as delay } from 'node:timers/promises';

const availabilityValues = new Set(['ready', 'unavailable', 'usage-limited']);

function presentation(status, error) {
  const authenticated = status?.authenticated === true;
  const value = {
    authenticated,
    signingIn: status?.signingIn === true,
    planEnabled: status?.planEnabled === true,
    availability: availabilityValues.has(status?.availability) ? status.availability : 'ready',
    modelsReady: Array.isArray(status?.models) && status.models.length > 0
  };
  if (error) value.error = error;
  else if (status?.error) {
    if (authenticated && status.availability === 'usage-limited') {
      value.error = 'ChatGPT 额度已达上限，额度恢复后可继续对话。';
    } else {
      value.error = authenticated && status.availability !== 'ready'
        ? '读取 ChatGPT 模型失败，请重试。' : 'ChatGPT 登录失败，请重试。';
    }
  }
  return value;
}

export class AuthState {
  constructor(service, emit, { intervalMs = 750, loginTimeoutMs = 305000, refreshTimeoutMs = 25000 } = {}) {
    this.service = service;
    this.emit = emit;
    this.intervalMs = intervalMs;
    this.loginTimeoutMs = loginTimeoutMs;
    this.refreshTimeoutMs = refreshTimeoutMs;
    this.controller = null;
  }

  async snapshot() { return presentation(await this.service.status()); }

  publish(status, error) { this.emit(presentation(status, error)); }
  get isWatching() { return this.controller !== null; }

  start(status) {
    this.stop();
    this.publish(status);
    if (!status.signingIn) return;
    const controller = new AbortController();
    this.controller = controller;
    void this.watch(status, controller.signal).finally(() => {
      if (this.controller === controller) this.controller = null;
    });
  }

  stop() {
    this.controller?.abort();
    this.controller = null;
  }

  async watch(initial, signal) {
    let current = initial;
    let refreshStarted;
    const loginDeadline = performance.now() + this.loginTimeoutMs;
    try {
      while (!signal.aborted) {
        await delay(this.intervalMs, undefined, { signal, ref: false });
        current = await this.service.status();
        if (signal.aborted) return;
        const now = performance.now();
        if (current.signingIn) {
          if (now < loginDeadline) continue;
          this.publish({ ...current, signingIn: false }, 'ChatGPT 登录超时，请重试。');
          return;
        }
        if (!current.authenticated || !current.planEnabled || current.error || current.availability !== 'ready'
          || (Array.isArray(current.models) && current.models.length > 0)) {
          this.publish(current);
          return;
        }
        refreshStarted ??= now;
        if (now - refreshStarted >= this.refreshTimeoutMs) {
          this.publish(current, 'ChatGPT 模型目录暂不可用，请刷新后重试。');
          return;
        }
      }
    } catch {
      if (!signal.aborted) {
        this.publish({ ...current, signingIn: false, availability: 'unavailable' }, '读取 ChatGPT 登录状态失败，请重试。');
      }
    }
  }
}
