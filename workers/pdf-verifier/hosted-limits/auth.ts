/** Only same-project Auth is contacted. Caller owns the five-second abort. */
export function createAuthenticate(project: string, anon: string, transport: typeof fetch = fetch) {
  if (project !== 'coxhjvqpflgxkleydati' || !anon) throw new Error('invalid_probe_environment');
  const url = `https://${project}.supabase.co/auth/v1/user`;
  return async (token: string, signal: AbortSignal): Promise<unknown> => {
    const response = await transport(url, {
      method: 'GET', redirect: 'error', signal,
      headers: { apikey: anon, Authorization: 'Bearer ' + token, Accept: 'application/json' },
    });
    const length = response.headers.get('content-length');
    if (response.status !== 200 || response.redirected || !response.body ||
        length !== null && (!/^\d+$/.test(length) || Number(length) > 65_536)) {
      void response.body?.cancel().catch(() => {});
      throw new Error('probe_auth_failed');
    }
    const reader = response.body.getReader();
    const bytes = new Uint8Array(65_536); let size = 0;
    try {
      while (true) {
        const { done, value } = await reader.read();
        if (signal.aborted) throw new Error('probe_auth_failed');
        if (done) break;
        if (size + value.byteLength > bytes.length) throw new Error('probe_auth_failed');
        bytes.set(value, size); size += value.byteLength;
      }
      if (signal.aborted || length !== null && Number(length) !== size) throw new Error('probe_auth_failed');
      return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes.subarray(0, size)));
    } finally { void reader.cancel().catch(() => {}); reader.releaseLock(); }
  };
}
