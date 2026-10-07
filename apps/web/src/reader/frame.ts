// Builds the sandboxed reader document from a verified bundle
// (docs/architecture/BROWSER_READER.md#reader-frame).
import frame from 'virtual:reader-frame';
import { toBase64 } from '../lib/bytes';
import { MAXIMUM_READER_HEADINGS, type VerifiedBundle } from '../lib/bundle';

export const FRAME_SCRIPT_HASH = frame.hash;

const REMOVE = 'script,base,meta[http-equiv],iframe,frame,frameset,object,embed,applet,form,link,noscript,template,portal';

export interface FrameOptions { parentOrigin: string; paperLine?: string | null; paperTags?: string[] | null; figureID?: string; fontSize?: number }

/** The bundle's HTML with app-owned presentation: no bundle scripts, inlined styles, verified images as data URIs. */
export function frameDocument(bundle: VerifiedBundle, options: FrameOptions): string {
  const html = new TextDecoder().decode(bundle.contents.get(bundle.manifest.entrypoint)!);
  const doc = new DOMParser().parseFromString(html, 'text/html');
  const styles = bundle.manifest.members.filter(m => m.role === 'style');
  const stylesheetHrefs = [...doc.querySelectorAll('link[rel~="stylesheet"]')].map(l => l.getAttribute('href'));
  doc.querySelectorAll(REMOVE).forEach(element => element.remove());
  for (const element of doc.querySelectorAll('*')) {
    for (const attribute of [...element.attributes]) {
      const name = attribute.name.toLowerCase(), value = attribute.value.trim().toLowerCase();
      if (name.startsWith('on') || name === 'srcset' || name === 'formaction' || name === 'ping'
        || (['href', 'src', 'xlink:href', 'action', 'background', 'poster'].includes(name) && /^(javascript|vbscript|data):/.test(value.replace(/[\s\u0000-\u001f]/g, '')))) {
        element.removeAttribute(attribute.name);
      }
    }
  }
  const images = new Map(bundle.manifest.members.filter(m => m.role === 'image').map(m => [m.path, m]));
  for (const img of doc.querySelectorAll('img')) {
    const member = images.get(img.getAttribute('src') ?? '');
    if (member) img.setAttribute('src', `data:${member.media_type};base64,${toBase64(bundle.contents.get(member.path)!)}`);
    else img.removeAttribute('src');
  }
  const head = doc.head;
  const csp = doc.createElement('meta');
  csp.setAttribute('http-equiv', 'Content-Security-Policy');
  csp.setAttribute('content', `default-src 'none'; img-src data:; style-src 'unsafe-inline'; script-src '${frame.hash}'; base-uri 'none'; form-action 'none'; connect-src 'none'; frame-src 'none'; font-src 'none'`);
  head.prepend(csp);
  // Stylesheets in the bundle's own link order, then any remaining style members.
  const ordered = [...stylesheetHrefs.map(href => styles.find(s => s.path === href)).filter(Boolean), ...styles.filter(s => !stylesheetHrefs.includes(s.path))];
  for (const member of new Set(ordered)) {
    const style = doc.createElement('style');
    style.textContent = new TextDecoder().decode(bundle.contents.get(member!.path)!);
    head.append(style);
  }
  const configBlock = doc.createElement('script');
  configBlock.setAttribute('type', 'application/json');
  configBlock.setAttribute('data-gradstep-config', '');
  const config = {
    parent_origin: options.parentOrigin, paper_line: options.paperLine ?? null, paper_tags: options.paperTags ?? null, font_size: options.fontSize ?? null,
    bundle: { ...bundle.index, manifest_sha256: bundle.manifestSHA256, ...(options.figureID ? { figure_id: options.figureID } : {}) },
  };
  // `<` escaped so no text in the index can end the data block.
  configBlock.textContent = JSON.stringify(config).replace(/</g, '\\u003c');
  const script = doc.createElement('script');
  script.textContent = frame.script;
  doc.body.append(configBlock, script);
  return '<!doctype html>\n' + doc.documentElement.outerHTML;
}

/** Messages from the frame, validated with the native coordinator's bounds. */
export type FrameMessage =
  | { type: 'headings'; items: { id: string; title: string }[] }
  | { type: 'position'; block: number; fraction: number; height: number; y: number; progress: number }
  | { type: 'citation'; state: 'jumped' | 'ended' }
  | { type: 'selection'; empty: boolean }
  | { type: 'reference' } | { type: 'figure'; id: string } | { type: 'tags' } | { type: 'invalid' };

export function readFrameMessage(value: unknown): FrameMessage | null {
  const v = value as Record<string, unknown>;
  if (!v || typeof v !== 'object' || typeof v.type !== 'string') return null;
  const finite = (x: unknown) => typeof x === 'number' && Number.isFinite(x);
  switch (v.type) {
    case 'headings':
      if (!Array.isArray(v.items) || v.items.length > MAXIMUM_READER_HEADINGS) return null;
      return { type: 'headings', items: (v.items as { id?: unknown; title?: unknown }[]).filter(i => typeof i?.id === 'string' && i.id && i.id.length <= 2048
        && typeof i.title === 'string' && i.title && i.title.length <= 8000).map(i => ({ id: i.id as string, title: i.title as string })) };
    case 'position':
      return [v.block, v.fraction, v.height, v.y, v.progress].every(finite) && Number.isInteger(v.block)
        ? { type: 'position', block: v.block as number, fraction: v.fraction as number, height: v.height as number, y: v.y as number, progress: Math.min(1, Math.max(0, v.progress as number)) } : null;
    case 'citation': return v.state === 'jumped' || v.state === 'ended' ? { type: 'citation', state: v.state } : null;
    case 'selection': {
      const parts = (v.selection as { parts?: unknown })?.parts;
      return { type: 'selection', empty: !Array.isArray(parts) || parts.length === 0 };
    }
    case 'reference': return { type: 'reference' };
    case 'figure': return typeof v.id === 'string' && /^[0-9A-Za-z_-]{1,200}$/.test(v.id) ? { type: 'figure', id: v.id } : null;
    case 'tags': return { type: 'tags' };
    case 'invalid': return { type: 'invalid' };
  }
  return null;
}
