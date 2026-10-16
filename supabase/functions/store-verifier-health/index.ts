import { installEgressGuard } from '../_shared/egress.ts';
import { createStoreVerifierHealthHandler } from '../_shared/store-verifier-health.ts';
// No request from this function may reach arXiv (docs/architecture/ARXIV_DEVICE_ONLY.md); such requests are refused (EGRESS_ARXIV=block, the default).
installEgressGuard('store-verifier-health');

Deno.serve(createStoreVerifierHealthHandler(name => Deno.env.get(name)));
