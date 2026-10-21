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
    // A data: URL: the page's image policy allows data: images and refuses blob: (the preview and the editor show it).
    return { blob: output, url: await dataURL(output), mediaType, width, height };
  } finally { bitmap.close(); }
}

function dataURL(blob: Blob): Promise<string> {
  return new Promise((resolve, reject) => { const reader = new FileReader(); reader.onload = () => resolve(String(reader.result)); reader.onerror = () => reject(new BackendError('invalid_response')); reader.readAsDataURL(blob); });
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

/** A box on the screenshot, as fractions of its width and height. */
export interface ScreenshotBox { x: number; y: number; w: number; h: number }
export interface ScreenshotEdits { crop: ScreenshotBox | null; covers: ScreenshotBox[] }
/** Where the edited image comes from and where its covers go, in pixels (ReportComposer's ScreenshotEditor): the crop
 * (or the whole image) and each cover clipped to it. A crop of 1% or less of a side is refused. */
export function screenshotPlan(width: number, height: number, edits: ScreenshotEdits) {
  const crop = edits.crop ?? { x: 0, y: 0, w: 1, h: 1 };
  if (crop.w <= 0.01 || crop.h <= 0.01) throw new BackendError('crop_too_small');
  const sx = Math.round(crop.x * width), sy = Math.round(crop.y * height);
  const sw = Math.max(1, Math.round(crop.w * width)), sh = Math.max(1, Math.round(crop.h * height));
  const covers = edits.covers.map(c => {
    const x = Math.max(0, Math.round(c.x * width) - sx), y = Math.max(0, Math.round(c.y * height) - sy);
    const right = Math.min(sw, Math.round((c.x + c.w) * width) - sx), bottom = Math.min(sh, Math.round((c.y + c.h) * height) - sy);
    return { x, y, w: right - x, h: bottom - y };
  }).filter(c => c.w > 0 && c.h > 0);
  return { source: { x: sx, y: sy, w: sw, h: sh }, covers };
}
/** The screenshot as edited: cropped, private details covered in black, re-rendered without metadata and bounded
 * like any attachment. The preview shown is exactly what is uploaded. */
export async function editScreenshot(image: ScreenshotAttachment, edits: ScreenshotEdits): Promise<ScreenshotAttachment> {
  const plan = screenshotPlan(image.width, image.height, edits);
  let bitmap: ImageBitmap;
  try { bitmap = await createImageBitmap(image.blob); } catch { throw new BackendError('invalid_response'); }
  try {
    const canvas = document.createElement('canvas'); canvas.width = plan.source.w; canvas.height = plan.source.h;
    const context = canvas.getContext('2d'); if (!context) throw new BackendError('invalid_response');
    context.fillStyle = '#fff'; context.fillRect(0, 0, canvas.width, canvas.height);
    context.drawImage(bitmap, plan.source.x, plan.source.y, plan.source.w, plan.source.h, 0, 0, plan.source.w, plan.source.h);
    context.fillStyle = '#000';
    for (const c of plan.covers) context.fillRect(c.x, c.y, c.w, c.h);
    return await prepareScreenshot(await canvasBlob(canvas, 'image/png'));
  } finally { bitmap.close(); }
}

export function disposeScreenshot(image: ScreenshotAttachment | null): void { if (image?.url.startsWith('blob:')) URL.revokeObjectURL(image.url); }

export function captureErrorMessage(error: unknown): string {
  if (!(error instanceof BackendError)) return 'The screenshot could not be prepared. Choose a PNG or JPEG and try again.';
  switch (error.code) {
    case 'capture_cancelled': return 'Capture cancelled. You can choose an image file instead.';
    case 'capture_unavailable': return 'This browser cannot capture a screen directly. Choose a PNG or JPEG screenshot instead.';
    case 'payload_too_large': return 'This screenshot is still too large after resizing. Choose a smaller image.';
    default: return 'The screenshot could not be prepared. Choose a PNG or JPEG and try again.';
  }
}
