// The approval QR's modules (docs/architecture/PRIVACY_AND_SYNC.md#approving-a-new-device-qr), apart from approval.ts so
// the QR encoder loads only when this browser shows the code (C5).
import { encode } from 'uqr';

/** QR modules as one SVG path (dark squares), generated locally: no network, no canvas, no inline script or style. */
export function qrPath(text: string): { size: number; path: string } {
  const qr = encode(text, { ecc: 'M', border: 0 });
  let path = '';
  qr.data.forEach((row, y) => row.forEach((dark, x) => { if (dark) path += `M${x} ${y}h1v1h-1z`; }));
  return { size: qr.size, path };
}
