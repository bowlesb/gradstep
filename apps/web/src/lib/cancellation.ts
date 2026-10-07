/** Any parent can retire the work; local abort and disposal also release all parent listeners. */
export function cancellation(parents: (AbortSignal | null | undefined)[] = []) {
  const controller = new AbortController();
  const removals: (() => void)[] = [];
  const dispose = () => { for (const remove of removals.splice(0)) remove(); };
  controller.signal.addEventListener('abort', dispose, { once: true });
  for (const parent of parents) {
    if (!parent || controller.signal.aborted) continue;
    if (parent.aborted) { controller.abort(parent.reason); break; }
    const abort = () => controller.abort(parent.reason);
    parent.addEventListener('abort', abort, { once: true });
    removals.push(() => parent.removeEventListener('abort', abort));
  }
  return { signal: controller.signal, abort: (reason?: unknown) => controller.abort(reason), dispose };
}
