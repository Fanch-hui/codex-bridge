import { RPCPeer } from './rpc.mjs';
import { QoderSession } from './session.mjs';
import { manageNativeHistory } from './native-history.mjs';
import { loadSDK, sdkLifecycle } from './sdk.mjs';
import { queryAccountScope } from './account-scope.mjs';
import { validateConfiguration } from './session.mjs';
import { HostError, requireValue } from './validation.mjs';

let peer;
const session = new QoderSession(value => { if (!peer.closed) peer.notify('qoder/event', value); },
  (method, params, signal) => peer.request(method, params, signal, 0));
const handlers = {
  'qoder/open': value => session.open(value),
  'qoder/account_scope': async value => {
    const config = validateConfiguration(value);
    const { sdk } = await loadSDK(config);
    return sdkLifecycle.using(sdk, async () => ({ digest: await queryAccountScope(sdk, config) }));
  },
  'qoder/input': value => session.dispatchInput(value),
  'qoder/interrupt': value => session.interrupt(value.continuation),
  'qoder/history': value => session.history(value),
  'qoder/native_history': async value => {
    const config = validateConfiguration(value);
    requireValue(config.expectedAccountScope, 'session_account_mismatch');
    const loaded = await loadSDK(config);
    return sdkLifecycle.using(loaded.sdk, async () => {
      const current = await queryAccountScope(loaded.sdk, config);
      requireValue(current === config.expectedAccountScope, 'session_account_mismatch');
      return manageNativeHistory(value, async () => loaded);
    });
  },
  'qoder/usage': () => session.usage(),
  'qoder/close': async () => { await session.close(); return { closed: true }; },
};
async function closeHost() {
  const lifecycle = sdkLifecycle.close().then(() => null, error => error);
  let sessionError;
  try { await session.close(); } catch (error) { sessionError = error; }
  const lifecycleError = await lifecycle;
  if (sessionError && lifecycleError) {
    throw new HostError('process_exit_unconfirmed', new AggregateError([sessionError, lifecycleError]));
  }
  if (sessionError || lifecycleError) throw sessionError || lifecycleError;
}

peer = new RPCPeer(process.stdin, process.stdout, async (method, params) => {
  requireValue(Object.hasOwn(handlers, method), 'unknown_host_method');
  return handlers[method](params);
}, closeHost);
function stopHost() {
  void peer.close().then(() => process.exit(0), () => { process.exitCode = 1; });
}
process.once('SIGTERM', stopHost);
process.once('SIGINT', stopHost);
process.on('unhandledRejection', () => { void peer.close().then(() => { process.exitCode = 1; },
  () => { process.exitCode = 1; }); });
