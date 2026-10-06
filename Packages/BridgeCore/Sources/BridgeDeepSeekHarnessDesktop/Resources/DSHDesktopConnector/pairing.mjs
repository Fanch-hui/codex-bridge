import { randomUUID } from 'node:crypto';
import { identity, hash } from './protocol.mjs';
import { fault } from './errors.mjs';

const RECORD = 'codex-bridge-dsh-desktop/identity';
export async function loadPairing(credentials) {
  const record = await credentials.modifyRecord(RECORD, async current => {
    if (current?.kind === 'grant') return undefined;
    return { kind: 'grant', payload: { profileID: randomUUID(), seed: identity().seed, grants: [] } };
  });
  const state = record.payload;
  const key = identity(state.seed);
  const pending = new Map();
  let onRevoke = () => {};
  const save = async mutate => {
    const next = await credentials.modifyRecord(RECORD, async current => {
      if (current?.kind !== 'grant') throw fault('connector_identity_missing', 'Connector identity was removed');
      const payload = { ...current.payload, grants: [...current.payload.grants] };
      mutate(payload);
      return { kind: 'grant', payload };
    });
    state.grants = next.payload.grants;
  };
  return {
    identity: key,
    profileID: state.profileID,
    isGranted(publicKey) { return state.grants.some(grant => grant.publicKey === publicKey); },
    request(publicKey, code) {
      const value = { publicKey, code, fingerprint: hash(Buffer.from(publicKey, 'base64')), expiresAt: Date.now() + 120000 };
      pending.set(publicKey, value);
      return { paired: false, code, expiresAt: value.expiresAt };
    },
    view() {
      for (const [key, item] of pending) if (item.expiresAt < Date.now()) pending.delete(key);
      return { pending: [...pending.values()], grants: state.grants.map(({ publicKey, pairedAt }) => ({ publicKey, pairedAt, fingerprint: hash(Buffer.from(publicKey, 'base64')) })) };
    },
    async approve(publicKey, code) {
      const request = pending.get(publicKey);
      if (!request || request.expiresAt < Date.now() || request.code !== code) throw fault('pairing_expired', 'Pairing request expired');
      await save(value => { value.grants = value.grants.filter(item => item.publicKey !== publicKey); value.grants.push({ publicKey, pairedAt: Date.now() }); });
      pending.delete(publicKey);
      return { paired: true };
    },
    async revoke(publicKey) {
      await save(value => { value.grants = value.grants.filter(item => item.publicKey !== publicKey); });
      pending.delete(publicKey);
      await onRevoke(publicKey);
      return { paired: false };
    },
    setRevoker(callback) { onRevoke = callback; },
  };
}
