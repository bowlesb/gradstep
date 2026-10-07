// A keyring for the fixture's "returning" account, made by the independent Node implementation
// (tests/backend/wire-crypto.mjs, verified against Swift by scripts/check-wire.mjs) as an iPhone would.
// Public test values only.
import { randomBytes, randomUUID } from 'node:crypto';
import { encode, hex, publicBytes, recoveryAAD, recoveryKey, seal, wrapDevice } from '../../../tests/backend/wire-crypto.mjs';

export const RECOVERY_CODE = '0f1e2d3c-4b5a6978-8796a5b4-c3d2e1f0-0f1e2d3c-4b5a6978-8796a5b4-c3d2e1f0';
const ACCOUNT = '11111111-2222-4333-8444-555555555555';

export function returningKeyring() {
  const keys = { accountID: ACCOUNT.toUpperCase(), epoch: 1, contentKeys: { '1': randomBytes(32).toString('base64') }, managementToken: randomBytes(32).toString('base64') };
  const raw = randomBytes(32), challenge = randomBytes(32), deviceID = randomUUID();
  return {
    deviceID, managementToken: Buffer.from(keys.managementToken, 'base64'),
    recoveryPackage: hex(seal(recoveryKey(RECOVERY_CODE, ACCOUNT), encode(keys), recoveryAAD(ACCOUNT))),
    publicKey: hex(publicBytes(raw)), challenge: hex(challenge),
    envelope: hex(wrapDevice(keys, deviceID, publicBytes(raw), challenge)),
  };
}
