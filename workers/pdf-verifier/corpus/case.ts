/** One isolated read-only Deno case; verifier imports come only from its checked bundle. */
import { identifier, loadBundle, read, root, sha256 } from "./bundle.ts";

const expectedIdentity = identifier(Deno.args[0]);
const paperID = Deno.args[1];
const expectedManifest = identifier(Deno.args[2]);
const started = performance.now();
const bundle = await loadBundle(expectedIdentity);
if (bundle.profile.hosted_admitted !== false) throw new Error("unreviewed_profile");
const factory = (await import(new URL("verifier.mjs",bundle.url).href)).default;
const verifier = await bundle.runtime.createVerifier({ factory, wasm:bundle.wasm,
  wasmSHA256:bundle.identity.wasm_sha256, profile:bundle.profile, profileSHA256:bundle.identity.profile_sha256 });
const coldLoadMS = performance.now()-started;
const manifestRaw = await read(new URL("workers/pdf-verifier/corpus/manifest.json",root),262144);
if (await sha256(manifestRaw) !== expectedManifest) throw new Error("corpus_manifest_changed");
const manifest = JSON.parse(new TextDecoder().decode(manifestRaw));
if (!/^v[0-9]+-[a-z]+[0-9]+[a-z]$/.test(paperID)) throw new Error("invalid_corpus_id");
const entry = manifest.papers.find((row:{id:string}) => row.id === paperID);
if (!entry || entry.file !== `pdf/${paperID}.pdf` || entry.bytes > 33554432) throw new Error("invalid_corpus_entry");
const bytes = await read(new URL(`.artifacts/pdf-verifier/corpus/${entry.file}`,root),33554432);
if (bytes.length !== entry.bytes || await sha256(bytes) !== entry.sha256) throw new Error("corpus_binding_mismatch");
const measurement = await verifier.verify(bytes,{sha256:entry.sha256,bytes:entry.bytes});
if (measurement.outcome !== "verified" && measurement.pages !== undefined) throw new Error("failure_exposed_page_count");
console.log(JSON.stringify({id:paperID,buildIdentitySHA256:expectedIdentity,manifestSHA256:expectedManifest,
  artifactSHA256:entry.sha256,coldLoadMS,measurement,memoryPostRunSnapshot:Deno.memoryUsage(),memoryIsPeak:false}));
