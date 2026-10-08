import { describe, expect, it } from 'vitest';
import { e2eEnvironment } from '../e2e/environment';

describe('isolated browser fixture configuration', () => {
  it('keeps the existing defaults and routes every custom endpoint to the same loopback pair', () => {
    expect(e2eEnvironment({})).toEqual({ fixturePort: 54329, appPort: 4317,
      fixtureOrigin: 'http://127.0.0.1:54329', appOrigin: 'http://127.0.0.1:4317' });
    expect(e2eEnvironment({ WEB_E2E_FIXTURE_PORT: '54339', WEB_E2E_APP_PORT: '4327' })).toEqual({
      fixturePort: 54339, appPort: 4327, fixtureOrigin: 'http://127.0.0.1:54339', appOrigin: 'http://127.0.0.1:4327' });
    expect(e2eEnvironment({ FIXTURE_PORT: '54349' }).fixturePort).toBe(54349);
  });
  it('refuses overlapping servers, malformed ports and command text before starting a child process', () => {
    for (const value of ['', '0', '80', '65536', '-4327', '04327', '4327.1', '4327;echo bad', 'localhost:4327', ' 4327']) {
      expect(() => e2eEnvironment({ WEB_E2E_APP_PORT: value })).toThrow();
      expect(() => e2eEnvironment({ WEB_E2E_FIXTURE_PORT: value })).toThrow();
    }
    expect(() => e2eEnvironment({ WEB_E2E_FIXTURE_PORT: '4327', WEB_E2E_APP_PORT: '4327' })).toThrow('different ports');
  });
});
