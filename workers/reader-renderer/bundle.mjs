import { readFileSync } from 'node:fs';
import { profile, sha256, jsonBytes, requireThat, pathIsSafe, idIsSafe, decodeUTF8, escapeText, boundedText } from './common.mjs';
import { decodePNG } from './png.mjs';
import { renderMMD } from './renderer.mjs';
import { parseHTML, elements, serialize, sanitizeAndValidate } from './dom.mjs';
import { captureRendererIdentity } from './build-identity.mjs';

export const CSP = "default-src 'none'; img-src 'self'; style-src 'self' 'unsafe-inline'; font-src 'self'; base-uri 'none'; form-action 'none'; object-src 'none'; frame-src 'none'; connect-src 'none'";
const importedIdentity = captureRendererIdentity();
export function rendererIdentity() {
  requireThat(captureRendererIdentity() === importedIdentity, 'renderer_source_changed'); return importedIdentity;
}
export function buildBundle({ sourceBytes, assets = new Map(), provenance }) {
  const identity = rendererIdentity();
  const source = Buffer.from(sourceBytes); requireThat(source.length > 0 && source.length <= profile.max_source_bytes, 'source_limit');
  const inputImages = new Map(), imageMembers = new Map(); let pixels = 0;
  requireThat(assets instanceof Map && assets.size <= profile.max_figures, 'asset_limit');
  const names = new Set();
  for (const [path, value] of assets) {
    requireThat(pathIsSafe(path) && path.startsWith('assets/') && path.endsWith('.png') && !names.has(path.toLowerCase()), 'asset_path'); names.add(path.toLowerCase());
    const image = decodePNG(Buffer.from(value)); pixels += image.width * image.height; requireThat(pixels <= profile.max_total_image_pixels, 'image_total_limit');
    inputImages.set(path, image); imageMembers.set(path, image.bytes);
  }
  const rendered = renderMMD(decodeUTF8(source), inputImages);
  const used = new Set(rendered.index.figures.flatMap(f => f.asset_paths)); requireThat(used.size === assets.size && [...assets.keys()].every(path => used.has(path)), 'unused_asset');
  const css = readFileSync(new URL('./reader.css', import.meta.url));
  requireThat(!/url\s*\(|@import|@font-face/i.test(decodeUTF8(css)), 'stylesheet_resource');
  const html = Buffer.from(`<!doctype html>\n<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="${CSP}"><title>${escapeText(rendered.index.title)}</title><link rel="stylesheet" href="reader.css"></head><body>${rendered.html}</body></html>\n`);
  requireThat(html.length <= profile.max_html_bytes, 'html_limit');
  const index = jsonBytes(rendered.index); requireThat(index.length <= profile.max_index_bytes, 'index_limit');
  requireThat(provenance && typeof provenance === 'object' && !Array.isArray(provenance), 'provenance_required');
  const provenanceBytes = jsonBytes({ ...provenance, format: 'reader-provenance-v1', kind: 'authored-fixture', source_sha256: sha256(source), image_inputs: [...assets].map(([path, bytes]) => ({ path, sha256: sha256(bytes), published_sha256: sha256(imageMembers.get(path)) })).sort((a, b) => a.path < b.path ? -1 : a.path > b.path ? 1 : 0) });
  requireThat(provenanceBytes.length <= profile.max_manifest_bytes, 'provenance_limit');
  const members = new Map([['index.html', html], ['reader.json', index], ['reader.css', css], ['provenance.json', provenanceBytes], ['NOTICE.txt', readFileSync(new URL('./NOTICE.txt', import.meta.url))], ...imageMembers]);
  const roles = { 'index.html': ['html', 'text/html'], 'reader.json': ['index', 'application/json'], 'reader.css': ['style', 'text/css'], 'provenance.json': ['provenance', 'application/json'], 'NOTICE.txt': ['notice', 'text/plain'] };
  const manifest = { format: profile.format, renderer: { id: profile.id, build_sha256: identity }, source: { kind: profile.source_kind, sha256: sha256(source), provenance_path: 'provenance.json' }, entrypoint: 'index.html', index_path: 'reader.json', members: [...members].sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0).map(([path, bytes]) => ({ path, role: roles[path]?.[0] ?? 'image', media_type: roles[path]?.[1] ?? 'image/png', bytes: bytes.length, sha256: sha256(bytes), ...(inputImages.has(path) ? { width: inputImages.get(path).width, height: inputImages.get(path).height } : {}) })) };
  const manifestBytes = jsonBytes(manifest); const manifestSHA = sha256(manifestBytes);
  validateBundle(manifestBytes, members, manifestSHA);
  rendererIdentity();
  return { manifest, manifestBytes, manifestSHA, members, index: rendered.index };
}
// Checks the generated artifact independently from the rendering pass. Callers
// still need an independently trusted manifest hash, not one from an upload.
export function validateBundle(manifestBytes, members, expectedSHA) {
  requireThat(Buffer.byteLength(manifestBytes) <= profile.max_manifest_bytes && /^[a-f0-9]{64}$/.test(expectedSHA) && sha256(manifestBytes) === expectedSHA, 'manifest_integrity');
  const manifest = JSON.parse(decodeUTF8(manifestBytes));
  requireThat(jsonBytes(manifest).equals(Buffer.from(manifestBytes)), 'manifest_canonical');
  requireThat(manifest.format === profile.format && manifest.renderer?.id === profile.id && /^[a-f0-9]{64}$/.test(manifest.renderer?.build_sha256) && manifest.source?.kind === profile.source_kind && /^[a-f0-9]{64}$/.test(manifest.source.sha256), 'manifest_format');
  requireThat(Array.isArray(manifest.members) && manifest.members.length > 0 && manifest.members.length <= profile.max_members && members.size === manifest.members.length, 'member_count');
  const paths = new Set(); let total = 0, totalPixels = 0;
  const media = { html: ['text/html'], index: ['application/json'], provenance: ['application/json'], style: ['text/css'], notice: ['text/plain'], image: ['image/png'] };
  for (const member of manifest.members) {
    requireThat(pathIsSafe(member.path) && member.path.toLowerCase() !== 'manifest.json' && !paths.has(member.path.toLowerCase()), 'member_path'); paths.add(member.path.toLowerCase());
    const bytes = members.get(member.path); requireThat(bytes && Number.isSafeInteger(member.bytes) && member.bytes > 0 && member.bytes <= profile.max_member_bytes && bytes.length === member.bytes && sha256(bytes) === member.sha256, 'member_integrity');
    requireThat(media[member.role]?.includes(member.media_type), 'member_role');
    total += bytes.length; requireThat(total <= profile.max_bundle_bytes, 'bundle_limit');
    if (member.role === 'image') { const image = decodePNG(bytes); requireThat(image.width === member.width && image.height === member.height, 'member_image'); totalPixels += image.width * image.height; requireThat(totalPixels <= profile.max_total_image_pixels, 'image_total_limit'); }
    else requireThat(member.width === undefined && member.height === undefined, 'unexpected_dimensions');
  }
  const entry = manifest.members.find(m => m.path === manifest.entrypoint), indexEntry = manifest.members.find(m => m.path === manifest.index_path), provenanceEntry = manifest.members.find(m => m.path === manifest.source.provenance_path);
  requireThat(entry?.role === 'html' && entry.bytes <= profile.max_html_bytes && indexEntry?.role === 'index' && indexEntry.bytes <= profile.max_index_bytes && provenanceEntry?.role === 'provenance', 'entrypoint');
  requireThat(['html', 'index', 'provenance'].every(role => manifest.members.filter(m => m.role === role).length === 1), 'entrypoint');
  const index = JSON.parse(decodeUTF8(members.get(manifest.index_path))); requireThat(index.format === profile.index_format && jsonBytes(index).equals(members.get(manifest.index_path)), 'index_format'); boundedText(index.title);
  requireThat(index.title.length > 0 && Buffer.byteLength(index.title) <= profile.max_heading_bytes, 'index_title');
  const limits = { blocks: profile.max_blocks, headings: profile.max_headings, equations: profile.max_equations, figures: profile.max_figures };
  for (const [key, limit] of Object.entries(limits)) requireThat(Array.isArray(index[key]) && index[key].length <= limit && index[key].every(row => idIsSafe(row.id)) && new Set(index[key].map(row => row.id)).size === index[key].length, 'index_collection');
  const blocks = new Map(index.blocks.map(b => [b.id, b])), kinds = new Set(['heading', 'paragraph', 'equation', 'figure', 'table', 'list', 'code']);
  requireThat(index.blocks.every(b => kinds.has(b.kind) && boundedText(b.text) === b.text), 'index_block');
  requireThat(index.headings.every(h => blocks.get(h.id)?.kind === 'heading' && Number.isInteger(h.level) && h.level >= 1 && h.level <= 6 && typeof h.title === 'string' && h.title.length > 0 && Buffer.byteLength(h.title) <= profile.max_heading_bytes && boundedText(h.title) === h.title), 'index_heading');
  requireThat(index.equations.every(e => !blocks.has(e.id) && blocks.has(e.block_id) && typeof e.display === 'boolean' && ['body', 'environment'].includes(e.source_form) && (e.source_form !== 'environment' || e.display) && boundedText(e.latex) === e.latex), 'index_equation');
  const imagePaths = new Set(manifest.members.filter(m => m.role === 'image').map(m => m.path));
  requireThat(index.figures.every(f => f.id === f.block_id && blocks.get(f.block_id)?.kind === 'figure' && Array.isArray(f.asset_paths) && f.asset_paths.length > 0 && f.asset_paths.every(p => imagePaths.has(p)) && new Set(f.asset_paths).size === f.asset_paths.length && boundedText(f.caption) === f.caption && boundedText(f.alt) === f.alt && f.alt.length > 0), 'index_figure');
  const figureAssets = new Set(index.figures.flatMap(f => f.asset_paths)); requireThat(figureAssets.size === imagePaths.size && [...imagePaths].every(p => figureAssets.has(p)), 'unused_asset');
  const doc = parseHTML(decodeUTF8(members.get(manifest.entrypoint)));
  const htmls = elements(doc, n => n.name === 'html'), heads = elements(doc, n => n.name === 'head'), bodies = elements(doc, n => n.name === 'body');
  requireThat(htmls.length === 1 && heads.length === 1 && bodies.length === 1 && heads[0].parent === htmls[0] && bodies[0].parent === htmls[0], 'html_structure');
  const rootChildren = doc.children.filter(n => n.type !== 'text' || n.data.trim()), htmlChildren = htmls[0].children.filter(n => n.type !== 'text' || n.data.trim());
  requireThat(rootChildren.length === 2 && rootChildren[0].type === 'directive' && rootChildren[0].data === '!doctype html' && rootChildren[1] === htmls[0] && htmlChildren.length === 2 && htmlChildren[0] === heads[0] && htmlChildren[1] === bodies[0] && JSON.stringify(htmls[0].attribs) === '{"lang":"en"}' && Object.keys(heads[0].attribs).length === 0 && Object.keys(bodies[0].attribs).length === 0, 'html_structure');
  const bodyHTML = bodies[0].children.map(serialize).join(''); sanitizeAndValidate(bodyHTML, imagePaths);
  const headChildren = heads[0].children.filter(n => n.type !== 'text' || n.data.trim());
  requireThat(headChildren.length === 5 && headChildren.every(n => n.type === 'tag' && ['meta', 'title', 'link'].includes(n.name)), 'html_head');
  requireThat(headChildren.filter(n => n.name === 'title').length === 1 && Object.keys(headChildren.find(n => n.name === 'title').attribs).length === 0 && headChildren.find(n => n.name === 'title').children.every(n => n.type === 'text') && headChildren.find(n => n.name === 'title').children.map(n => n.data).join('') === index.title, 'html_title');
  const metadata = headChildren.filter(n => n.name === 'meta'); requireThat(metadata.length === 3 && metadata.every(n => JSON.stringify(Object.keys(n.attribs).sort()) === JSON.stringify(n.attribs.charset ? ['charset'] : n.attribs.name ? ['content', 'name'] : ['content', 'http-equiv'])) && metadata.some(n => n.attribs.charset === 'utf-8') && metadata.some(n => n.attribs.name === 'viewport' && n.attribs.content === 'width=device-width,initial-scale=1'), 'html_metadata');
  const ids = new Set(); for (const node of elements(doc, n => 'id' in n.attribs)) { requireThat(!ids.has(node.attribs.id), 'duplicate_dom_id'); ids.add(node.attribs.id); }
  requireThat(elements(doc, n => n.name === 'meta' && n.attribs['http-equiv'] === 'Content-Security-Policy' && n.attribs.content === CSP).length === 1, 'csp');
  requireThat(elements(doc, n => n.name === 'script' || n.name === 'iframe' || n.name === 'object').length === 0, 'active_content');
  const stylesheet = readFileSync(new URL('./reader.css', import.meta.url));
  for (const node of elements(doc, n => n.name === 'link')) requireThat(Object.keys(node.attribs).sort().join(',') === 'href,rel' && node.attribs.rel === 'stylesheet' && manifest.members.some(m => m.path === node.attribs.href && m.role === 'style' && members.get(m.path).equals(stylesheet)), 'style_reference');
  requireThat(manifest.members.filter(m => m.role === 'style').length === 1, 'style_reference');
  for (const node of elements(doc, n => n.name === 'img')) requireThat(manifest.members.some(m => m.path === node.attribs.src && m.role === 'image'), 'image_reference');
  for (const node of elements(doc, n => n.name === 'a' || n.name === 'use')) requireThat([node.attribs.href, node.attribs['xlink:href']].filter(v => v !== undefined).every(v => v.startsWith('#') && ids.has(v.slice(1))), 'fragment_reference');
  for (const [collection, attr] of [['blocks', 'data-reader-block'], ['equations', 'data-reader-equation'], ['figures', 'data-reader-figure']]) {
    const nodes = elements(doc, n => attr in n.attribs); requireThat(Array.isArray(index[collection]) && nodes.length === index[collection].length && new Set(index[collection].map(v => v.id)).size === nodes.length, 'index_identity');
    for (const value of index[collection]) requireThat(nodes.some(n => n.attribs.id === value.id && n.attribs[attr] === value.id), 'index_identity');
  }
  for (const equation of index.equations) {
    const node = elements(doc, n => n.attribs['data-reader-equation'] === equation.id)[0];
    let parent = node.parent; while (parent && !parent.attribs?.['data-reader-block']) parent = parent.parent;
    requireThat(parent?.attribs['data-reader-block'] === equation.block_id, 'equation_parent');
    const latex = elements(node, n => n.attribs.class === 'reader-latex');
    requireThat(latex.length === 1 && latex[0].children.every(n => n.type === 'text') && latex[0].children.map(n => n.data).join('') === equation.latex && elements(node, n => n.name === 'math').length === 1 && elements(node, n => n.name === 'svg').length >= 1, 'equation_representation');
  }
  for (const figure of index.figures) { const node = elements(doc, n => n.attribs['data-reader-figure'] === figure.id)[0]; requireThat(node.attribs['data-reader-block'] === figure.block_id && JSON.stringify(elements(node, n => n.name === 'img').map(n => n.attribs.src)) === JSON.stringify(figure.asset_paths), 'figure_assets'); }
  return manifest;
}
