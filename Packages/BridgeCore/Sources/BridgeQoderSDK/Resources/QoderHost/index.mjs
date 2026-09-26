import { RPCPeer } from './rpc.mjs';
import { QoderSession } from './session.mjs';
import { manageNativeHistory } from './native-history.mjs';
import { loadSDK } from './sdk.mjs';
import { queryAccountScope } from './account-scope.mjs';
import { validateConfiguration } from './session.mjs';
import { requireValue } from './validation.mjs';

let peer;
const session = new QoderSession(value => peer.notify('qoder/event', value),
  (method, params, signal) => peer.request(method, params, signal));
const handlers = {
  'qoder/open': value => session.open(value),
  'qoder/account_scope': async value => {
    const config = validateConfiguration(value);
    const { sdk } = await loadSDK(config);
    return { digest: await queryAccountScope(sdk, config) };
  },
  'qoder/input': value => session.dispatchInput(value),
  'qoder/interrupt': value => session.interrupt(value.continuation),
  'qoder/history': value => session.history(value),
  'qoder/native_history': async value => {
    const config = validateConfiguration(value);
    requireValue(config.expectedAccountScope, 'session_account_mismatch');
    return manageNativeHistory(value, async parameters => {
      const loaded = await loadSDK(parameters);
      const current = await queryAccountScope(loaded.sdk, parameters);
      requireValue(current === config.expectedAccountScope, 'session_account_mismatch');
      return loaded;
    });
  },
  'qoder/usage': () => session.usage(),
  'qoder/close': async () => { await session.close(); return { closed: true }; },
};
peer = new RPCPeer(process.stdin, process.stdout, async (method, params) => {
  requireValue(Object.hasOwn(handlers, method), 'unknown_host_method');
  return handlers[method](params);
}, () => session.close());
process.once('SIGTERM', () => { void peer.close().finally(() => process.exit(0)); });
process.once('SIGINT', () => { void peer.close().finally(() => process.exit(0)); });
process.on('unhandledRejection', () => { void peer.close().finally(() => { process.exitCode = 1; }); });
