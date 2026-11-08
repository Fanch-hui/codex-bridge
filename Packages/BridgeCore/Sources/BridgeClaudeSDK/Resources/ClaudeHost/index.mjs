import { RPCPeer } from './rpc.mjs';
import { ClaudeSession } from './session.mjs';
import { HostError, requireValue } from './validation.mjs';
import { validateConfiguration } from './configuration.mjs';
import { inspectCLI, sdkVersion } from './sdk.mjs';

let peer;
const emit = value => peer.notify('claude/event', value);
const ask = (method, params, signal) => peer.request(method, params, signal, 0);
const session = new ClaudeSession(emit, ask);

async function probe(value, catalog = false) {
  const query = new ClaudeSession(() => {}, async () => { throw new HostError('interaction_unavailable'); });
  try {
    return await query.open({ ...value, resume: false, mode: 'workspace-write', networkAllowed: true,
      autoApprove: false, mcpServers: {}, selectedSkills: [] }, { probe: true, catalog });
  } finally { await query.close(); }
}

const handlers = {
  'claude/auth': async value => ({ revision: 1, sdkVersion,
    ...await inspectCLI(validateConfiguration(value, { task: false })) }),
  'claude/probe': value => probe(value),
  'claude/catalog': value => probe(value, true),
  'claude/start': value => session.open(value),
  'claude/input': value => session.dispatchInput(value),
  'claude/interrupt': value => session.interrupt(value.continuation),
  'claude/close': async () => { await session.close(); return { closed: true }; },
};

peer = new RPCPeer(process.stdin, process.stdout, async (method, params) => {
  requireValue(Object.hasOwn(handlers, method), 'unknown_host_method');
  return handlers[method](params);
}, () => session.close());
process.once('SIGTERM', () => { void peer.close().finally(() => process.exit(0)); });
process.once('SIGINT', () => { void peer.close().finally(() => process.exit(0)); });
process.on('unhandledRejection', () => { void peer.close().finally(() => { process.exitCode = 1; }); });
