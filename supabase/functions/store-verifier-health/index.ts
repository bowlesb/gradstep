import { createStoreVerifierHealthHandler } from '../_shared/store-verifier-health.ts';

Deno.serve(createStoreVerifierHealthHandler(name => Deno.env.get(name)));
