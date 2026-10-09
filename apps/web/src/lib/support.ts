import { BackendError } from './backend';

export interface ScreenshotAttachment { blob: Blob; url: string; mediaType: 'image/png' | 'image/jpeg'; width: number; height: number }

const MAX_PIXELS = 2_560;
const MAX_BYTES = 5 * 1024 * 1024;

/** Re-renders an image to strip metadata and keep support attachments bounded. */
export async function prepareScreenshot(source: Blob): Promise<ScreenshotAttachment> {
  if (!/^image\/(png|jpeg)$/.test(source.type) || source.size > 20 * 1024 * 1024) throw new BackendError('invalid_response');
  let bitmap: ImageBitmap;
  try { bitmap = await createImageBitmap(source); } catch { throw new BackendError('invalid_response'); }
  try {
    if (!bitmap.width || !bitmap.height) throw new BackendError('invalid_response');
    const scale = Math.min(1, MAX_PIXELS / Math.max(bitmap.width, bitmap.height));
    const width = Math.max(1, Math.floor(bitmap.width * scale)), height = Math.max(1, Math.floor(bitmap.height * scale));
    const canvas = document.createElement('canvas'); canvas.width = width; canvas.height = height;
    const context = canvas.getContext('2d'); if (!context) throw new BackendError('invalid_response');
    context.fillStyle = '#fff'; context.fillRect(0, 0, width, height); context.drawImage(bitmap, 0, 0, width, height);
    let output = await canvasBlob(canvas, 'image/png');
    let mediaType: ScreenshotAttachment['mediaType'] = 'image/png';
    if (output.size > MAX_BYTES) {
      mediaType = 'image/jpeg';
      for (const quality of [0.9, 0.78, 0.65, 0.5]) {
        output = await canvasBlob(canvas, mediaType, quality);
        if (output.size <= MAX_BYTES) break;
      }
    }
    if (output.size > MAX_BYTES) throw new BackendError('payload_too_large');
    return { blob: output, url: URL.createObjectURL(output), mediaType, width, height };
  } finally { bitmap.close(); }
}

function canvasBlob(canvas: HTMLCanvasElement, type: string, quality?: number): Promise<Blob> {
  return new Promise((resolve, reject) => canvas.toBlob(value => value ? resolve(value) : reject(new BackendError('invalid_response')), type, quality));
}

/** Captures an explicit browser/display selection. The browser chooser is intentional: a page may not silently capture the user's screen. */
export async function captureBrowserScreen(): Promise<ScreenshotAttachment> {
  if (!navigator.mediaDevices?.getDisplayMedia) throw new BackendError('capture_unavailable');
  let stream: MediaStream;
  try {
    stream = await navigator.mediaDevices.getDisplayMedia({
      video: { displaySurface: 'browser', frameRate: { ideal: 1, max: 5 } }, audio: false,
      // Chromium recognizes these hints; unknown members are ignored by other implementations.
      preferCurrentTab: true, selfBrowserSurface: 'include', surfaceSwitching: 'exclude',
    } as MediaStreamConstraints);
  } catch (error) {
    if (error instanceof DOMException && (error.name === 'AbortError' || error.name === 'NotAllowedError')) throw new BackendError('capture_cancelled');
    throw new BackendError('capture_unavailable');
  }
  try {
    const track = stream.getVideoTracks()[0]; if (!track) throw new BackendError('capture_unavailable');
    const video = document.createElement('video'); video.muted = true; video.playsInline = true; video.srcObject = stream;
    await video.play();
    await new Promise<void>(resolve => requestAnimationFrame(() => resolve()));
    const canvas = document.createElement('canvas');
    canvas.width = video.videoWidth || track.getSettings().width || 1280;
    canvas.height = video.videoHeight || track.getSettings().height || 720;
    const context = canvas.getContext('2d'); if (!context) throw new BackendError('capture_unavailable');
    context.drawImage(video, 0, 0, canvas.width, canvas.height);
    return await prepareScreenshot(await canvasBlob(canvas, 'image/png'));
  } finally { stream.getTracks().forEach(track => track.stop()); }
}

export function disposeScreenshot(image: ScreenshotAttachment | null): void { if (image) URL.revokeObjectURL(image.url); }

export function captureErrorMessage(error: unknown): string {
  if (!(error instanceof BackendError)) return 'The screenshot could not be prepared. Choose a PNG or JPEG and try again.';
  switch (error.code) {
    case 'capture_cancelled': return 'Capture cancelled. You can choose an image file instead.';
    case 'capture_unavailable': return 'This browser cannot capture a screen directly. Choose a PNG or JPEG screenshot instead.';
    case 'payload_too_large': return 'This screenshot is still too large after resizing. Choose a smaller image.';
    default: return 'The screenshot could not be prepared. Choose a PNG or JPEG and try again.';
  }
}
