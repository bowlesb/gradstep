import { loadBundle, root, sha256 } from "./bundle.ts";

const artifacts = new URL(".artifacts/pdf-verifier/corpus/",root);
function assert(value:unknown): asserts value { if (!value) throw new Error("assertion_failed"); }
async function rejects(work:()=>Promise<unknown>, message:string) {
  try { await work(); } catch (error) { assert(error instanceof Error && error.message.includes(message)); return; }
  throw new Error("expected_rejection");
}
async function fixture() {
  const temp = await Deno.makeTempDir({dir:artifacts.pathname,prefix:"bundle-test-"});
  const store = new URL(`file://${temp}/builds/`);
  await Deno.mkdir(store);
  const encoder = new TextEncoder();
  const values:Record<string,Uint8Array> = {};
  const identity:Record<string,unknown> = {};
  for (const [file,key,content] of [
    ["runtime.ts","runtime_sha256","export const marker = 'archived-runtime';"],
    ["wasm.ts","memory_inspector_sha256","export const marker = 'archived-inspector';"],
    ["verifier.cpp","wrapper_sha256","captured-wrapper"],["build.py","build_recipe_sha256","captured-recipe"],
    ["dependencies.lock.json","dependencies_sha256","{}"],["verifier.mjs","javascript_sha256","export default {};"],
    ["verifier.wasm","wasm_sha256","test-wasm"],["libqpdf.a","qpdf_library_sha256","test-library"],
  ]) { values[file]=encoder.encode(content);identity[key]=await sha256(values[file]); }
  const profile={hosted_admitted:false};identity.profile=profile;
  values["profile.json"]=encoder.encode(JSON.stringify(profile));identity.profile_sha256=await sha256(values["profile.json"]);
  values["identity.json"]=encoder.encode(JSON.stringify(identity));
  const id=await sha256(values["identity.json"]);
  values["build.json"]=encoder.encode(JSON.stringify({...identity,build_identity_sha256:id}));
  const path=new URL(`${id}/`,store);await Deno.mkdir(path);
  const hashes:Record<string,string>={};
  for (const [name,raw] of Object.entries(values)) { await Deno.writeFile(new URL(name,path),raw);hashes[name]=await sha256(raw); }
  await Deno.writeTextFile(new URL("bundle.json",path),JSON.stringify({format:1,identity_sha256:id,files:hashes}));
  return {temp,store,path,id,hashes};
}
async function run(work:(f:Awaited<ReturnType<typeof fixture>>)=>Promise<void>) {
  const f=await fixture();try {await work(f);} finally {await Deno.remove(f.temp,{recursive:true});}
}

Deno.test("selected archived runtime executes independently of changed live source",()=>run(async f=>{
  const live=new URL(`file://${f.temp}/live/`);await Deno.mkdir(live);
  await Deno.writeTextFile(new URL("runtime.ts",live),"throw new Error('live_runtime_must_not_execute');");
  const selected=await loadBundle(f.id,f.store);
  assert((selected.runtime as unknown as Record<string,unknown>).marker==="archived-runtime");
}));
Deno.test("tampered source is refused even if bundle manifest is rewritten",()=>run(async f=>{
  const bytes=new TextEncoder().encode("throw new Error('tampered_code_executed');");
  await Deno.writeFile(new URL("runtime.ts",f.path),bytes);f.hashes["runtime.ts"]=await sha256(bytes);
  await Deno.writeTextFile(new URL("bundle.json",f.path),JSON.stringify({format:1,identity_sha256:f.id,files:f.hashes}));
  await rejects(()=>loadBundle(f.id,f.store),"bundle_source_mismatch");
}));
Deno.test("changed identity cannot retain selected identity name",()=>run(async f=>{
  await Deno.writeTextFile(new URL("identity.json",f.path),"{}");
  await rejects(()=>loadBundle(f.id,f.store),"bundle_identity_mismatch");
}));
Deno.test("symlink source cannot substitute live source",()=>run(async f=>{
  await Deno.remove(new URL("runtime.ts",f.path));
  await Deno.symlink(new URL("wasm.ts",f.path).pathname,new URL("runtime.ts",f.path).pathname);
  await rejects(()=>loadBundle(f.id,f.store),"invalid_bundle_file");
}));
Deno.test("unexpected bundle files fail closed",()=>run(async f=>{
  await Deno.writeTextFile(new URL("extra.ts",f.path),"export const unwanted = 1;");
  await rejects(()=>loadBundle(f.id,f.store),"bundle_file_set_mismatch");
}));
Deno.test("short or traversing build selectors are refused",()=>run(async f=>{
  await rejects(()=>loadBundle(f.id.slice(0,8),f.store),"invalid_build_identity");
  await rejects(()=>loadBundle("../other",f.store),"invalid_build_identity");
}));
