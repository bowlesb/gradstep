import { validateMathpixRenderInput } from '../../supabase/functions/_shared/mathpix-result.ts';
import { profile, requireThat, decodeUTF8, jsonBytes, sha256 } from './common.mjs';
import { pngHeaderMetadata, decodePNG } from './png.mjs';
import { renderMathpixMMD } from './renderer.mjs';
import { assembleBundle, rendererIdentity } from './bundle.mjs';
import { mathpixReaderProfile } from './mathpix-profile.mjs';

// No provider client or fetch callback is accepted here. A retry consumes the
// exact retained raw content identity, independent of paid submission authority.
export async function buildMathpixBundle(input) {
  const identity = rendererIdentity();
  const checked = await validateMathpixRenderInput(input);
  requireThat(identity === rendererIdentity(), 'renderer_source_changed');
  const raw = checked.manifest, archive = checked.archiveMembers;
  const source = Buffer.from(archive.get(raw.render_source.path));
  requireThat(source.length > 0 && source.length <= profile.max_source_bytes, 'source_limit');

  // Inventory-only entries are retained in the raw result, not decoded or
  // published. Header metadata only lets the parser emit the dimensions of
  // candidate images; every actually referenced image is fully admitted below.
  const candidates = [], candidateImages = new Map();
  for (const entry of raw.archive_entries) {
    if (entry.path === raw.render_source.path) continue;
    let dimensions;
    try { dimensions = pngHeaderMetadata(archive.get(entry.path)); }
    catch { continue; }
    const path = `assets/${entry.sha256}.png`;
    const previous = candidateImages.get(path);
    requireThat(!previous || (previous.width === dimensions.width && previous.height === dimensions.height), 'image_mapping');
    candidateImages.set(path, dimensions); candidates.push([entry.path, path]);
  }
  const mapping = { source_path: raw.render_source.path, candidates };
  const rendered = renderMathpixMMD(decodeUTF8(source), candidateImages, mapping);
  const inventory = new Map(raw.archive_entries.map(entry => [entry.path, entry]));
  const destinations = new Map(candidates), imageMembers = new Map(), inputImages = new Map();
  const imageInputs = []; let pixels = 0;
  for (const archivePath of rendered.image_paths) {
    const entry = inventory.get(archivePath), publishedPath = destinations.get(archivePath);
    requireThat(entry && publishedPath && archive.has(archivePath), 'image_mapping');
    let image = inputImages.get(publishedPath);
    if (!image) {
      const decoded = decodePNG(archive.get(archivePath));
      const header = candidateImages.get(publishedPath);
      requireThat(decoded.width === header.width && decoded.height === header.height, 'image_dimensions');
      pixels += decoded.width * decoded.height;
      requireThat(pixels <= profile.max_total_image_pixels, 'image_total_limit');
      image = { width: decoded.width, height: decoded.height };
      inputImages.set(publishedPath, image); imageMembers.set(publishedPath, decoded.bytes);
    }
    imageInputs.push({ archive_path: archivePath, input_sha256: entry.sha256,
      published_path: publishedPath, published_sha256: sha256(imageMembers.get(publishedPath)), ...image });
  }
  const used = new Set(rendered.index.figures.flatMap(figure => figure.asset_paths));
  requireThat(used.size === imageMembers.size && [...imageMembers.keys()].every(path => used.has(path)), 'unused_asset');
  const provenanceBytes = jsonBytes({ format: 'mathpix-reader-provenance-v1',
    raw_result_sha256: checked.expectedRawManifestSHA256,
    document: { sha256: raw.document.sha256, bytes: raw.document.bytes, page_count: raw.document.page_count },
    ocr: { ...raw.ocr },
    source: { archive_path: raw.render_source.path, bytes: raw.render_source.bytes, sha256: raw.render_source.sha256 },
    image_inputs: imageInputs,
  });
  return assembleBundle({ source, rendered, inputImages, imageMembers, provenanceBytes,
    rendererID: mathpixReaderProfile.id, sourceKind: mathpixReaderProfile.source_kind, identity });
}
