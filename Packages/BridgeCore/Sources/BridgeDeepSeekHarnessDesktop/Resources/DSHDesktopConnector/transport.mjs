import net from 'node:net';
import { randomBytes } from 'node:crypto';
import { PROTOCOL, transcript, signText, verifyText, pairingCode, SignedFrames } from './protocol.mjs';
import { fault, wireError } from './errors.mjs';

export async function listenConnector({ identity, profileID, instanceID, pairing, dispatch, disconnected, reconnected }) {
  const peers = new Set();
  const server = net.createServer(socket => {
    let buffer = '';
    let handshake;
    let key;
    let frames;
    let authenticated = false;
    let chain = Promise.resolve();
    const timeout = setTimeout(() => socket.destroy(), 10000);
    socket.setEncoding('utf8');
    const send = value => {
      if (!socket.destroyed) socket.write(`${JSON.stringify(frames ? frames.pack(value) : value)}\n`);
    };
    const peer = { get key() { return key; }, send, close: () => socket.destroy() };
    peers.add(peer);
    socket.on('close', () => {
      clearTimeout(timeout);
      peers.delete(peer);
      if (authenticated) disconnected(key);
    });
    socket.on('error', () => {});
    async function receive(message) {
      if (!handshake) {
        if (message.type !== 'hello' || message.protocol !== PROTOCOL) throw fault('invalid_handshake', 'Unsupported connector protocol');
        if (Buffer.from(message.clientNonce ?? '', 'base64').length !== 32) throw fault('invalid_handshake', 'Invalid client nonce');
        key = message.publicKey;
        const serverNonce = randomBytes(32).toString('base64');
        handshake = transcript(key, identity.publicKey, message.clientNonce, serverNonce, profileID, instanceID);
        send({ type: 'challenge', protocol: PROTOCOL, publicKey: identity.publicKey, clientNonce: message.clientNonce, serverNonce, profileID, instanceID, signature: signText(identity.privateKey, handshake) });
        return;
      }
      if (!authenticated) {
        if (message.type !== 'auth' || !verifyText(key, handshake, message.signature)) throw fault('invalid_handshake', 'Client identity proof failed');
        frames = new SignedFrames(identity, key, handshake, 'server');
        authenticated = true;
        clearTimeout(timeout);
        if (pairing.isGranted(key)) reconnected(key);
        return;
      }
      const request = frames.unpack(message);
      if (typeof request.id !== 'string' || typeof request.method !== 'string') throw fault('invalid_request', 'Expected correlated request');
      try {
        const allowed = pairing.isGranted(key);
        if (!allowed && !['pairing/state', 'pairing/request', 'run/observe', 'run/cancel'].includes(request.method)) throw fault('pairing_required', 'Confirm pairing in DSH Desktop');
        const result = await dispatch(request.method, request.params ?? {}, { key, code: pairingCode(handshake), peer });
        send({ id: request.id, result });
      } catch (error) {
        send({ id: request.id, error: wireError(error) });
      }
    }
    socket.on('data', chunk => {
      buffer += chunk;
      if (Buffer.byteLength(buffer) > 4 * 1024 * 1024) { socket.destroy(); return; }
      let offset;
      while ((offset = buffer.indexOf('\n')) >= 0) {
        const line = buffer.slice(0, offset);
        buffer = buffer.slice(offset + 1);
        chain = chain.then(() => receive(JSON.parse(line))).catch(() => socket.destroy());
      }
    });
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  return {
    port: server.address().port,
    revoke(key) { for (const peer of peers) if (peer.key === key) peer.close(); },
    async close() {
      for (const peer of peers) peer.close();
      await new Promise(resolve => server.close(resolve));
    },
  };
}
