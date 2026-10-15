// The on-device PDF converter's entry for JavaScriptCore (global `GradstepDevicePDF`): the Swift host supplies
// the text layer, the layout's detections and the models' outputs; nothing here reads a file or the network.
import { composeDevicePDFReader, DEVICE_PDF_BUILD_SHA256 } from './device-pdf/bundle.ts';
import { encodeBase64 } from './device-pdf/base64.ts';
import { DEVICE_PDF_CONVERTER_VERSION, DEVICE_PDF_PORT_REVISION, DEVICE_PDF_RENDERER_ID, type DevicePDFHost, type DevicePDFInput } from './device-pdf/types.ts';
import { ReaderRenderError } from './util.ts';

export const identity = { renderer_id: DEVICE_PDF_RENDERER_ID, converter: DEVICE_PDF_CONVERTER_VERSION, revision: DEVICE_PDF_PORT_REVISION, build_sha256: DEVICE_PDF_BUILD_SHA256 };

/** Synchronous: returns the bundle (base64 members, canonical manifest) or throws `{ code }`. */
export function convert(input: DevicePDFInput, host: DevicePDFHost) {
  try {
    const bundle = composeDevicePDFReader(input, host);
    const members: Record<string, string> = {};
    for (const [path, bytes] of bundle.members) members[path] = encodeBase64(bytes);
    return { manifest: encodeBase64(bundle.manifestBytes), manifest_sha256: bundle.manifestSHA256, members, summary: bundle.summary,
      ...(bundle.trace ? { trace: JSON.stringify(bundle.trace) } : {}) };
  } catch (error) {
    const code = error instanceof ReaderRenderError ? error.code : error instanceof Error && /^[a-z_]+$/.test(error.message) ? error.message : 'device_pdf_internal';
    const detail = error instanceof Error ? String(error.message).slice(0, 200) : '';
    throw { code, detail };
  }
}
