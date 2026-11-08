import { resolve } from 'node:path';
import { Rpc } from './rpc.mjs';
import { startEngine } from './engine.mjs';
import { Actions } from './actions.mjs';
import { startActions, callWhenReady } from './startup.mjs';
import { ContextPolicy, contextPolicySymbol } from './context-policy.mjs';

const homeIndex = process.argv.indexOf('--home');
if (homeIndex < 0 || !process.argv[homeIndex + 1]) throw new Error('--home is required');
const protocolWrite = process.stdout.write.bind(process.stdout);
process.stdout.write = (...args) => process.stderr.write(...args);
const rpc = new Rpc(process.stdin, { write: text => protocolWrite(text) });
globalThis[Symbol.for('codex-bridge.rpc')] = rpc;
let engine;
const home = resolve(process.argv[homeIndex + 1]);
const contextPolicy = new ContextPolicy(undefined, home, () => {});
const startup = contextPolicy.start().then(() => {
  globalThis[contextPolicySymbol] = contextPolicy;
  return startEngine(home);
}).then(value => {
  engine = value;
  for (const name of ['sessionController', 'sessionSkillCatalog', 'settingsController', 'chatgptSiwc',
    'credentials', 'llm', 'tools', 'subagents', 'sandboxPolicy', 'permissionPresets', 'jobs', 'userQuestions',
    'clientModules', 'connection', 'remoteAccess', 'typertGateway', 'workspaceRegistry', 'workspaceController',
    'zcode', 'workbuddyManager']) {
    if (!value.ctx.get(name)) throw new Error(`Required DSH service is unavailable: ${name}`);
  }
  return startActions(new Actions(value.ctx, rpc, home, contextPolicy));
});
const ready = startup.then(state => state.complete);
rpc.onRequest = async (method, params, signal) => {
  if (method !== 'bridge/call') throw new Error(`Unknown method: ${method}`);
  if (params?.action === 'runtime.shutdown') {
    const actions = await ready;
    signal?.throwIfAborted();
    await actions.dispose();
    setImmediate(() => void engine.shutdown.shutdown(0));
    return {};
  }
  return callWhenReady(await startup, params?.action, params?.payload, signal);
};
rpc.onClose = () => { void ready.then(async actions => { await actions.dispose(); return engine.shutdown.shutdown(0); }).catch(() => {}); };
ready.catch(error => {
  process.stderr.write(`DSH startup failed: ${error.stack ?? error}\n`);
  process.exitCode = 1;
  void startup.then(state => state.initial).then(actions => {
    actions.events.emit(undefined, 'runtime.failed', { message: '工作台初始化失败，请重启。' });
  }).catch(() => {});
});
