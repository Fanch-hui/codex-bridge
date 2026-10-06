import { randomUUID } from 'node:crypto';
import { writeFile, rename, unlink } from 'node:fs/promises';
import path from 'node:path';
import { PROTOCOL, CONNECTOR_VERSION } from './protocol.mjs';
import { hostVersion } from './host-version.mjs';
import { loadPairing } from './pairing.mjs';
import { listenConnector } from './transport.mjs';
import { ProjectGrants } from './project-grants.mjs';
import { NativeServices } from './native-services.mjs';
import { RunStore } from './run-store.mjs';
import { Runs } from './runs.mjs';
import { Interactions } from './interactions.mjs';
import { UiChannel } from './ui-channel.mjs';
import { fault, text } from './errors.mjs';

export async function createConnector(ctx, config) {
  if (!path.isAbsolute(config.descriptorPath)) throw fault('invalid_configuration', 'descriptorPath must be absolute');
  const desktopVersion = await hostVersion(ctx.profileContext?.installAnchor);
  const pairing = await loadPairing(ctx.credentials);
  const native = new NativeServices(ctx);
  const grants = new ProjectGrants();
  const store = new RunStore(`${config.descriptorPath}.runs.json`);
  await store.load();
  const runs = new Runs(native, grants, store);
  const interactions = new Interactions(runs);
  const ui = new UiChannel();
  const instanceID = randomUUID();
  const state = peer => ({ paired: pairing.isGranted(peer.key), profileID: pairing.profileID, instanceID });
  async function dispatch(method, params, peer) {
    if (method === 'pairing/state') return state(peer);
    if (method === 'pairing/request') return pairing.isGranted(peer.key) ? state(peer) : { ...pairing.request(peer.key, peer.code), pairingCode: peer.code };
    if (method === 'pairing/revoke') return pairing.revoke(peer.key);
    if (method === 'models/list') return native.catalog();
    if (method === 'models/defaults') return native.defaults();
    if (method === 'models/set-defaults') return native.setDefaults(params);
    if (method === 'project/sync') return grants.sync(peer.key, params.projectPaths);
    if (method === 'run/start') return runs.start(params, peer.key);
    if (method === 'run/observe') return runs.observe(params, peer.key);
    if (method === 'run/cancel') return runs.cancel(params, peer.key);
    if (method === 'run/steer') return runs.steer(params, peer.key);
    if (method === 'interaction/answer') return interactions.answer(params, peer.key);
    if (method === 'session/list') return { sessions: await native.list(await grants.require(peer.key, params.projectPath)) };
    if (['session/read', 'session/rename', 'session/open'].includes(method)) {
      const { summary } = await grants.requireSession(peer.key, params.projectPath, text(params.sessionID, 'sessionID'), native);
      if (method === 'session/read') return native.read(params.sessionID, params.offset, params.limit);
      if (method === 'session/open') return ui.open(params.sessionID);
      if (summary.running) throw fault('native_session_busy', 'Cannot rename a running session');
      return native.rename(params.sessionID, text(params.title, 'title'));
    }
    throw fault('operation_unsupported', 'Unsupported Desktop Connector operation');
  }
  const transport = await listenConnector({ identity: pairing.identity, profileID: pairing.profileID, instanceID, pairing, dispatch, disconnected: key => runs.disconnected(key), reconnected: key => runs.reconnected(key) });
  pairing.setRevoker(async key => { grants.revoke(key); await runs.cancelOwned(key); setTimeout(() => transport.revoke(key), 50); });
  const descriptor = { protocol: PROTOCOL, host: '127.0.0.1', port: transport.port, profileID: pairing.profileID, instanceID, publicKey: pairing.identity.publicKey, pid: process.pid, executablePath: process.execPath, desktopVersion, connectorVersion: CONNECTOR_VERSION };
  await writeFile(`${config.descriptorPath}.tmp`, JSON.stringify(descriptor), { mode: 0o600 });
  await rename(`${config.descriptorPath}.tmp`, config.descriptorPath);
  const disposers = [
    ctx.on('session/event', (session, event) => { void runs.onEvent(session, event).catch(error => ctx.logger.warn(error.message)); }),
    ctx.on('approval/request', (request, next) => interactions.ask('approval', request, next), { prepend: true }),
    ctx.on('user-questions/request', (request, next) => interactions.ask('question', request, next), { prepend: true }),
  ];
  function clientRpc(method, params, signal) {
    if (method === 'state') return pairing.view();
    if (method === 'approve') return pairing.approve(text(params.publicKey, 'publicKey'), text(params.code, 'code'));
    if (method === 'revoke') return pairing.revoke(text(params.publicKey, 'publicKey'));
    if (method === 'poll') return ui.poll(signal);
    if (method === 'acknowledge') return ui.acknowledge(params);
    throw fault('operation_unsupported', 'Unsupported connector UI operation');
  }
  return {
    descriptor, clientRpc, dispatch, pairing, runs,
    async close() {
      interactions.close();
      ui.close();
      await runs.close();
      for (const dispose of disposers) dispose();
      await store.writes;
      await transport.close();
      await unlink(config.descriptorPath).catch(error => { if (error.code !== 'ENOENT') throw error; });
    },
  };
}
