import { createHash, createPrivateKey, createPublicKey, generateKeyPairSync, sign, verify } from 'node:crypto';

export const PROTOCOL = 'codex-bridge-dsh/1';
export const CONNECTOR_VERSION = '1.0.0';
const PUBLIC_PREFIX = Buffer.from('302a300506032b6570032100', 'hex');
const PRIVATE_PREFIX = Buffer.from('302e020100300506032b657004220420', 'hex');

export function identity(seed) {
  const privateKey = seed
    ? createPrivateKey({ key: Buffer.concat([PRIVATE_PREFIX, Buffer.from(seed, 'base64')]), format: 'der', type: 'pkcs8' })
    : generateKeyPairSync('ed25519').privateKey;
  const publicKey = createPublicKey(privateKey).export({ format: 'der', type: 'spki' }).subarray(-32).toString('base64');
  return { publicKey, seed: privateKey.export({ format: 'der', type: 'pkcs8' }).subarray(-32).toString('base64'), privateKey };
}

export function publicKeyOf(value) {
  const bytes = Buffer.from(value, 'base64');
  if (bytes.length !== 32 || bytes.toString('base64') !== value) throw new Error('Invalid Ed25519 public key');
  return createPublicKey({ key: Buffer.concat([PUBLIC_PREFIX, bytes]), format: 'der', type: 'spki' });
}

export function transcript(clientKey, serverKey, clientNonce, serverNonce, profileID, instanceID) {
  for (const field of [clientKey, serverKey, clientNonce, serverNonce, profileID, instanceID]) {
    if (typeof field !== 'string' || field.includes('\n') || !field) throw new Error('Invalid handshake field');
  }
  return [PROTOCOL, clientKey, serverKey, clientNonce, serverNonce, profileID, instanceID].join('\n');
}

export const hash = value => createHash('sha256').update(value).digest('hex');
export const signText = (key, value) => sign(null, Buffer.from(value), key).toString('base64');
export function verifyText(key, value, signature) {
  return typeof signature === 'string' && verify(null, Buffer.from(value), publicKeyOf(key), Buffer.from(signature, 'base64'));
}
export const pairingCode = value => String(parseInt(hash(value).slice(0, 12), 16) % 1000000).padStart(6, '0');

export class SignedFrames {
  constructor(identity, peerKey, handshake, direction) {
    this.identity = identity;
    this.peerKey = peerKey;
    this.handshakeHash = hash(handshake);
    this.direction = direction;
    this.sent = 0;
    this.received = 0;
  }
  pack(value) {
    const sequence = ++this.sent;
    const payload = Buffer.from(JSON.stringify(value)).toString('base64');
    const text = [this.handshakeHash, this.direction, sequence, payload].join('\n');
    return { type: 'frame', sequence, direction: this.direction, payload, signature: signText(this.identity.privateKey, text) };
  }
  unpack(frame) {
    const direction = this.direction === 'server' ? 'client' : 'server';
    if (frame.type !== 'frame' || frame.direction !== direction || frame.sequence !== this.received + 1) throw new Error('Frame sequence or direction mismatch');
    const text = [this.handshakeHash, direction, frame.sequence, frame.payload].join('\n');
    if (!verifyText(this.peerKey, text, frame.signature)) throw new Error('Frame signature mismatch');
    const bytes = Buffer.from(frame.payload, 'base64');
    if (bytes.toString('base64') !== frame.payload) throw new Error('Invalid frame encoding');
    const value = JSON.parse(bytes.toString('utf8'));
    this.received = frame.sequence;
    return value;
  }
}
