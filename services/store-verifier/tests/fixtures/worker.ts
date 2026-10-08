// Never copied into the production image. Deliberately leaves live work after
// success so lifecycle tests prove termination, rather than just HTTP timeout.
import { parentPort, workerData } from 'node:worker_threads';
parentPort!.once('message', () => {
  if (workerData.mode === 'hang') while (true) { /* CPU-bound: AbortSignal is insufficient. */ }
  if (workerData.mode === 'throw') throw new Error('PRIVATE_WORKER_ERROR');
  if (workerData.mode === 'exit') process.exit(7);
  if (workerData.mode === 'malformed') parentPort!.postMessage({ status: 'verified', signed_payload: 'PRIVATE_JWS' });
  else parentPort!.postMessage({ status: 'verified', transaction: {
    environment: 'Sandbox', transaction_id: '2001', original_transaction_id: '2000', product_id: 'com.sciencereader.ios.credits400',
    type: 'Consumable', purchase_date: 1_700_000_000_000, signed_date: 1_700_000_000_001,
  } });
  setInterval(() => {}, 1000);
});
