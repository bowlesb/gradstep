import { profile } from './common.mjs';

// This additive source profile deliberately shares every authored reader limit.
// It does not broaden the admitted Markdown, math, image or HTML feature set.
export const mathpixReaderProfile = Object.freeze({
  ...profile, id: 'timestep-mathpix-mmd-v1', source_kind: 'mathpix-mmd',
});
export function readerProfileFor(rendererID, sourceKind) {
  if (rendererID === profile.id && sourceKind === profile.source_kind) return profile;
  if (rendererID === mathpixReaderProfile.id && sourceKind === mathpixReaderProfile.source_kind) return mathpixReaderProfile;
  throw new Error('manifest_format');
}
