// Immutable inventory is committed before any physical upload. An uncertain
// Storage response is never treated as proof that no bytes were written.
import { sha256 } from './http.ts';
import type { PipelineDeps } from './pipeline.ts';

export interface AssetClaim { p_paper_id: string; p_claim_id: string; p_generation: number }
export interface PlannedAsset { path: string; bytes: Uint8Array; mediaType: string }
interface UploadPlan { upload_id: string; objects: { id: string; path: string; verified: boolean }[] }

export async function uploadInventoried(deps: PipelineDeps, claim: AssetClaim, kind: 'original' | 'raw' | 'reader',
  objects: PlannedAsset[], pages?: number): Promise<void> {
  const uploadID = deps.uuid();
  const identities = await Promise.all(objects.map(async o => ({ path: o.path, sha256: await sha256(o.bytes), bytes: o.bytes.length, media_type: o.mediaType })));
  const plan = await deps.rpc<UploadPlan>('worker_pipeline_asset_plan', { ...claim, p_upload_id: uploadID, p_kind: kind,
    p_objects: identities, p_pages: pages ?? null });
  if (!plan || plan.upload_id !== uploadID || !Array.isArray(plan.objects) || plan.objects.length !== objects.length
    || new Set(plan.objects.map(o => o.path)).size !== objects.length) throw new Error('asset_plan_invalid');
  const byPath = new Map(plan.objects.map(o => [o.path, o]));
  for (const object of objects) {
    const planned = byPath.get(object.path);
    if (!planned || typeof planned.id !== 'string' || typeof planned.verified !== 'boolean') throw new Error('asset_plan_invalid');
    if (planned.verified) continue;
    const attemptID = deps.uuid();
    const grant = await deps.rpc<{ write: boolean; verified: boolean }>('worker_pipeline_asset_write', {
      ...claim, p_upload_id: uploadID, p_object_id: planned.id, p_attempt_id: attemptID });
    if (!grant || (!grant.write && !grant.verified)) throw new Error('asset_write_uncertain');
    if (grant.verified) continue;
    // Exactly one upload per durably admitted attempt. The adapter never
    // silently retries or overwrites an existing physical object.
    await deps.storage.upload(object.path, object.bytes, object.mediaType);
    let recorded = false;
    for (let i = 0; i < 3; i++) {
      try { await deps.rpc('worker_pipeline_asset_written', { p_attempt_id: attemptID, p_verified: true }); recorded = true; break; }
      catch { if (i < 2) await deps.sleep(250 * (i + 1)); }
    }
    if (!recorded) throw new Error('asset_write_uncertain');
  }
}
