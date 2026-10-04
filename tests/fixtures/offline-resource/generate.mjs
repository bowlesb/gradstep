// Local fixture authoring only. The measured app launch never executes this
// script, constructs pixels, imports Node code or regenerates a reader bundle.
import { readFileSync, writeFileSync, mkdirSync, existsSync, readdirSync, lstatSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { join, resolve } from 'node:path';
import { captureRendererIdentity } from '../../../workers/reader-renderer/build-identity.mjs';
import { runProcessGroup } from '../../../workers/reader-renderer/process-group.mjs';

const here = fileURLToPath(new URL('.', import.meta.url));
const output = fileURLToPath(new URL('../../../apps/apple/ScienceReader/Resources/offline-resource/', import.meta.url));
const ensure = (condition, code) => { if (!condition) throw new Error(code); };

async function generate() {
  const identity = captureRendererIdentity();
  const { buildBundle, validateBundle, rendererIdentity } = await import('../../../workers/reader-renderer/bundle.mjs');
  const { encodePNG } = await import('../../../workers/reader-renderer/png.mjs');
  const { sha256 } = await import('../../../workers/reader-renderer/common.mjs');
  ensure(rendererIdentity() === identity, 'renderer_changed');
  const width = 4000, height = 4000;
  const pixels = Buffer.alloc(width * height * 4);
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const p = (y * width + x) * 4;
      const dark = ((Math.floor(x / 250) + Math.floor(y / 250)) & 1) === 0;
      pixels[p] = dark ? 80 : 220;
      pixels[p + 1] = dark ? 88 : 230;
      pixels[p + 2] = dark ? 185 : 247;
      pixels[p + 3] = 255;
    }
  }
  const sourceBytes = readFileSync(join(here, 'sample.mmd'));
  const result = buildBundle({
    sourceBytes,
    assets: new Map([['assets/resource-grid.png', encodePNG(width, height, pixels)]]),
    provenance: {
      title: 'Offline resource measurement',
      authorship: 'Original synthetic fixture authored for Science Reader resource measurements.',
      purpose: 'Simulator measurement only; no provider input or research-paper attribution.',
      image_recipe_sha256: sha256(readFileSync(fileURLToPath(import.meta.url))),
    },
  });
  validateBundle(result.manifestBytes, result.members, result.manifestSHA);
  ensure(rendererIdentity() === identity, 'renderer_changed');
  const destination = join(output, result.manifestSHA);
  mkdirSync(destination, { recursive: true });
  const expected = new Map([...result.members, ['manifest.json', result.manifestBytes]]);
  for (const [path, bytes] of expected) {
    const target = join(destination, path);
    mkdirSync(resolve(target, '..'), { recursive: true });
    if (existsSync(target)) {
      ensure(lstatSync(target).isFile() && !lstatSync(target).isSymbolicLink() && readFileSync(target).equals(bytes), 'fixture_changed');
    } else { writeFileSync(target, bytes, { flag: 'wx' }); }
  }
  function walk(root, prefix = '') {
    return readdirSync(root, { withFileTypes: true }).flatMap(entry => {
      ensure(!entry.isSymbolicLink(), 'fixture_symlink');
      const path = prefix + entry.name;
      return entry.isDirectory() ? walk(join(root, entry.name), path + '/') : [path];
    });
  }
  ensure(JSON.stringify(walk(destination).sort()) === JSON.stringify([...expected.keys()].sort()), 'fixture_members');
  return { manifest_sha256: result.manifestSHA, renderer_build_sha256: identity,
    payload_bytes: [...result.members.values()].reduce((n, bytes) => n + bytes.length, 0),
    pixels: width * height, equations: result.index.equations.length, figures: result.index.figures.length,
    directory: destination };
}

if (process.argv.length === 3 && process.argv[2] === '--worker') {
  process.stdout.write(JSON.stringify(await generate()) + '\n');
} else {
  ensure(process.argv.length === 2, 'unsupported_arguments');
  // Reuse the renderer's bounded process-group watchdog. Large PNG buffers are
  // native allocations; this local authoring step is not a memory admission.
  process.stdout.write(await runProcessGroup(process.execPath,
    ['--max-old-space-size=256', fileURLToPath(import.meta.url), '--worker']));
}
