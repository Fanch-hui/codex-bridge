import { resolve } from 'node:path';
import { Rpc } from './rpc.mjs';
import { startEngine } from './engine.mjs';
import { Actions } from './actions.mjs';
import { startActions, callWhenReady } from './startup.mjs';
import { ContextPolicy, contextPolicySymbol } from './context-policy.mjs';
import { startProviderEngine } from './provider-engine.mjs';
import { ProviderActions } from './provider-actions.mjs';
import { acquireProviderRuntime } from './provider-runtime-lock.mjs';
import { ProviderSession, providerSessionSymbol } from './provider-session.mjs';
import { SharedProviderRegistry } from './shared-provider-registry.mjs';

const homeIndex = process.argv.indexOf('--home');
if (homeIndex < 0 || !process.argv[homeIndex + 1]) throw new Error('--home is required');
const protocolWrite = process.stdout.write.bind(process.stdout);
process.stdout.write = (...args) => process.stderr.write(...args);
const rpc = new Rpc(process.stdin, { write: text => protocolWrite(text) });
globalThis[Symbol.for('codex-bridge.rpc')] = rpc;
let engine;
const home = resolve(process.argv[homeIndex + 1]);
const providerOnly = process.argv.includes('--providers-only');
const sharedProviders = process.argv.includes('--shared-providers');
if (providerOnly && sharedProviders) throw new Error('Provider and workbench runtime roles are mutually exclusive');
if (providerOnly) globalThis[providerSessionSymbol] = new ProviderSession(rpc);
let releaseRuntime;
const startup = acquireProviderRuntime(home, sharedProviders ? 'shared-workbench' : 'provider').then(async release => {
  releaseRuntime = release;
  if (providerOnly) {
    engine = await startProviderEngine(home);
    for (const name of ['llm', 'sessions', 'attachments', 'settingsController', 'agentDefaultModel',
      'chatgptSiwc', 'credentials', 'zcode', 'workbuddyManager']) {
      if (!engine.ctx.get(name)) throw new Error(`Required provider service is unavailable: ${name}`);
    }
    const actions = new ProviderActions(engine.ctx, rpc, home);
    await actions.start();
    return { initial: Promise.resolve(actions), complete: Promise.resolve(actions) };
  }
  const contextPolicy = new ContextPolicy(undefined, home, () => {});
  await contextPolicy.start();
  globalThis[contextPolicySymbol] = contextPolicy;
  const value = await startEngine(home, { sharedProviders });
  engine = value;
  for (const name of ['sessionController', 'sessionSkillCatalog', 'settingsController',
    'credentials', 'llm', 'tools', 'subagents', 'sandboxPolicy', 'permissionPresets', 'jobs', 'userQuestions',
    'clientModules', 'connection', 'remoteAccess', 'typertGateway', 'workspaceRegistry', 'workspaceController',
    ...sharedProviders ? [] : ['chatgptSiwc', 'zcode', 'workbuddyManager']]) {
    if (!value.ctx.get(name)) throw new Error(`Required DSH service is unavailable: ${name}`);
  }
  const providers = sharedProviders ? new SharedProviderRegistry(value.ctx, rpc) : undefined;
  if (providers) await providers.refresh();
  return startActions(new Actions(value.ctx, rpc, home, contextPolicy, providers));
}).catch(async error => {
  try { if (engine) await engine.shutdown.shutdown(1); }
  finally { await releaseRuntime?.(); }
  throw error;
});
const ready = startup.then(state => state.complete);
let closing;
let disposingActions;
function disposeActions() {
  return disposingActions ??= ready.then(actions => actions.dispose());
}
function shutdown() {
  return closing ??= (async () => {
    try {
      await disposeActions();
    } finally {
      try { if (engine) await engine.shutdown.shutdown(0); }
      finally { await releaseRuntime?.(); }
    }
  })();
}
rpc.onRequest = async (method, params, signal) => {
  if (method !== 'bridge/call') throw new Error(`Unknown method: ${method}`);
  if (params?.action === 'runtime.shutdown') {
    await ready;
    signal?.throwIfAborted();
    await disposeActions();
    setImmediate(() => void shutdown().catch(error => process.stderr.write(`DSH shutdown failed: ${error.message}\n`)));
    return {};
  }
  return callWhenReady(await startup, params?.action, params?.payload, signal);
};
rpc.onClose = () => { void shutdown().catch(error => process.stderr.write(`DSH shutdown failed: ${error.message}\n`)); };
ready.catch(error => {
  process.stderr.write(`DSH startup failed: ${error.stack ?? error}\n`);
  process.exitCode = 1;
  void startup.then(state => state.initial).then(actions => {
    actions.events?.emit(undefined, 'runtime.failed', { message: '工作台初始化失败，请重启。' });
  }).catch(() => {});
});
