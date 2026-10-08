// One loopback-only configuration for each isolated Playwright worktree. Values used in shell commands
// are parsed as bounded integers before interpolation; origins never come from arbitrary environment URLs.
export function e2eEnvironment(env: Record<string, string | undefined> = process.env) {
  const port = (name: string, fallback: string): number => {
    const value = env[name] ?? fallback;
    if (!/^[1-9][0-9]{3,4}$/.test(value) || Number(value) < 1024 || Number(value) > 65535) {
      throw new Error(`${name} must be a port from 1024 to 65535`);
    }
    return Number(value);
  };
  const fixturePort = port('WEB_E2E_FIXTURE_PORT', env.FIXTURE_PORT ?? '54329');
  const appPort = port('WEB_E2E_APP_PORT', '4317');
  if (fixturePort === appPort) throw new Error('The fixture and app need different ports');
  return { fixturePort, appPort, fixtureOrigin: `http://127.0.0.1:${fixturePort}`, appOrigin: `http://127.0.0.1:${appPort}` };
}
export const { fixturePort, appPort, fixtureOrigin, appOrigin } = e2eEnvironment();
