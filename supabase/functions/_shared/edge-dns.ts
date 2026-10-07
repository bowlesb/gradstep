// Host resolution for Edge functions that fetch reader-supplied or third-party links: the runtime
// resolver, else DNS over HTTPS. Throws (the hop is refused) when neither answers. Same behaviour as
// the paper worker's resolver; every address must then be public (web-source `checkHost`).
export async function edgeResolveHost(host: string): Promise<string[]> {
  const resolveDns = (Deno as { resolveDns?: typeof Deno.resolveDns }).resolveDns;
  if (typeof resolveDns === 'function') {
    const answers = await Promise.allSettled([(async () => resolveDns(host, 'A'))(), (async () => resolveDns(host, 'AAAA'))()]);
    const addresses = answers.flatMap(answer => answer.status === 'fulfilled' ? answer.value : []);
    if (addresses.length) return addresses;
    const reason = (answers.find(answer => answer.status === 'rejected') as PromiseRejectedResult | undefined)?.reason;
    if (reason instanceof Error && reason.name === 'NotFound') throw new Error('dns_unresolved');
  }
  const addresses: string[] = [];
  for (const type of ['A', 'AAAA']) {
    try {
      const response = await fetch(`https://cloudflare-dns.com/dns-query?name=${encodeURIComponent(host)}&type=${type}`,
        { headers: { accept: 'application/dns-json' }, redirect: 'error', signal: AbortSignal.timeout(5_000) });
      const body = await response.json() as { Answer?: { type?: number; data?: unknown }[] };
      for (const answer of body.Answer ?? []) if ((answer.type === 1 || answer.type === 28) && typeof answer.data === 'string') addresses.push(answer.data);
    } catch { /* none */ }
  }
  if (!addresses.length) throw new Error('dns_unresolved');
  return addresses;
}
