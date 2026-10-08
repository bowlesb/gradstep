// QR device approval, the new device's half (docs/architecture/PRIVACY_AND_SYNC.md#approving-a-new-device-qr).
// Port of ScienceReaderCore/DeviceApproval.swift; both are checked against its public device-approval-v1.json fixture,
// which scripts/check-wire.mjs computes independently in Node.
import { encode } from 'uqr';
import { type Bytes, concat, sha256, utf8, wireUUID } from './bytes';
import { WireError } from './wire';

export const APPROVAL_VERSION = 'GSDA1';
/** w: web browser, m: Mac, p: iPhone, t: iPad. Display only. */
export type DeviceKind = 'w' | 'm' | 'p' | 't';

export const toBase64Url = (bytes: Uint8Array): string => {
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
};

/** 16 bytes naming the account without putting its ID on screen. */
export async function accountTag(account: string): Promise<Bytes> {
  return (await sha256(utf8(`science-reader/device-approval/v1/account/${wireUUID(account)}`))).slice(0, 16);
}

/** The enrollment comparison fingerprint (ENCRYPTED_WIRE_FORMAT.md), as bytes. */
export async function fingerprint(account: string, deviceID: string, publicKey: Bytes, challenge: Bytes): Promise<Bytes> {
  if (publicKey.length !== 32 || challenge.length !== 32) throw new WireError('invalid_key');
  return sha256(concat(utf8(`science-reader/enrollment/v1/${wireUUID(account)}/${wireUUID(deviceID)}/`), publicKey, challenge));
}

/** Six digits from a domain-separated hash of the fingerprint: a check for people; the QR carries the full fingerprint. */
export async function comparisonCode(print: Bytes): Promise<string> {
  const digest = await sha256(concat(utf8('science-reader/device-approval/v1/code/'), print));
  return String(new DataView(digest.buffer).getUint32(0) % 1_000_000).padStart(6, '0');
}
export const displayCode = (code: string): string => code.length === 6 ? `${code.slice(0, 3)} ${code.slice(3)}` : code;

export interface ApprovalRecipient { requestID: string; account: string; deviceID: string; publicKey: Bytes; challenge: Bytes; kind: DeviceKind }

/** `GSDA1.<request id>.<account tag>.<fingerprint>.<kind>`, binary fields as unpadded base64url (97 characters). */
export async function approvalPayload(recipient: ApprovalRecipient): Promise<{ payload: string; code: string }> {
  const print = await fingerprint(recipient.account, recipient.deviceID, recipient.publicKey, recipient.challenge);
  const id = Uint8Array.from(wireUUID(recipient.requestID).replace(/-/g, '').match(/../g)!, pair => parseInt(pair, 16));
  const payload = [APPROVAL_VERSION, toBase64Url(id), toBase64Url(await accountTag(recipient.account)), toBase64Url(print), recipient.kind].join('.');
  return { payload, code: await comparisonCode(print) };
}

/** QR modules as one SVG path (dark squares), generated locally: no network, no canvas, no inline script or style. */
export function qrPath(text: string): { size: number; path: string } {
  const qr = encode(text, { ecc: 'M', border: 0 });
  let path = '';
  qr.data.forEach((row, y) => row.forEach((dark, x) => { if (dark) path += `M${x} ${y}h1v1h-1z`; }));
  return { size: qr.size, path };
}
