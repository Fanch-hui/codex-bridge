import { resolve } from 'node:path';
import { Rpc } from './rpc.mjs';
import { startEngine } from './engine.mjs';
import { Actions } from './actions.mjs';

const homeIndex = process.argv.indexOf('--home');
if (homeIndex < 0 || !process.argv[homeIndex + 1]) throw new Error('--home is required');
const protocolWrite = process.stdout.write.bind(process.stdout);
process.stdout.write = (...args) => process.stderr.write(...args);
const rpc = new Rpc(process.stdin, { write: text => protocolWrite(text) });
globalThis[Symbol.for('codex-bridge.rpc')] = rpc;
let engine;
const home = resolve(process.argv[homeIndex + 1]);
const ready = startEngine(home).then(async value => {
  engine = value;
  for (const name of ['sessionController', 'sessionSkillCatalog', 'settingsController', 'chatgptSiwc',
    'credentials', 'llm', 'tools', 'subagents', 'sandboxPolicy', 'permissionPresets', 'jobs', 'userQuestions',
    'clientModules', 'connection', 'remoteAccess', 'typertGateway', 'workspaceRegistry', 'workspaceController']) {
    if (!value.ctx.get(name)) throw new Error(`Required DSH service is unavailable: ${name}`);
  }
  const actions = new Actions(value.ctx, rpc, home);
  await actions.activation.start();
  await actions.pluginOperations.start();
  await actions.clientEvents.start();
  await actions.sessions.start();
  await actions.contentCache.start();
  await actions.scopes.start();
  await actions.scheduleOperations.start();
  await actions.persistedQuestions.start();
  await actions.mcp.start();
  await actions.bridgeAgents.start();
  await actions.activity.start();
  await actions.verifyRestartedPlugins();
  return actions;
});
rpc.onRequest = async (method, params, signal) => {
  if (method !== 'bridge/call') throw new Error(`Unknown method: ${method}`);
  const actions = await ready;
  if (params?.action === 'runtime.shutdown') {
    await actions.dispose();
    setImmediate(() => void engine.shutdown.shutdown(0));
    return {};
  }
  return actions.call(params?.action, params?.payload, signal);
};
rpc.onClose = () => { void ready.then(async actions => { await actions.dispose(); return engine.shutdown.shutdown(0); }).catch(() => {}); };
ready.catch(error => { process.stderr.write(`DSH startup failed: ${error.stack ?? error}\n`); process.exitCode = 1; });
