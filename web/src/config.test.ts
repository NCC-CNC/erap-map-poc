import { describe, expect, it } from 'vitest';
import { configUrl, loadRuntimeConfig, parseRuntimeConfig } from './config';

const URL_ = 'http://app.test/config.json';

function fakeFetch(respond: () => Response | Promise<Response>): typeof fetch {
  return (async () => respond()) as typeof fetch;
}

describe('parseRuntimeConfig', () => {
  it('reads a string key, trimmed', () => {
    expect(parseRuntimeConfig({ cartoApiKey: 'abc' })).toEqual({ cartoApiKey: 'abc' });
    expect(parseRuntimeConfig({ cartoApiKey: ' abc \n' })).toEqual({ cartoApiKey: 'abc' });
  });

  it('treats anything else as no key', () => {
    for (const json of [null, 'abc', 42, [], {}, { cartoApiKey: 1 }, { cartoApiKey: null }]) {
      expect(parseRuntimeConfig(json)).toEqual({ cartoApiKey: '' });
    }
  });
});

describe('configUrl', () => {
  it('resolves config.json under the base URL', () => {
    expect(configUrl('/', 'http://app.test/some/page')).toBe('http://app.test/config.json');
    expect(configUrl('/map/', 'http://app.test/map/')).toBe('http://app.test/map/config.json');
  });
});

describe('loadRuntimeConfig', () => {
  it('returns the key from a valid file', async () => {
    const fetch = fakeFetch(() => Response.json({ cartoApiKey: 'abc' }));
    await expect(loadRuntimeConfig({ url: URL_, fetch })).resolves.toEqual({ cartoApiKey: 'abc' });
  });

  it('returns no key for a missing file', async () => {
    const fetch = fakeFetch(() => new Response('Not Found', { status: 404 }));
    await expect(loadRuntimeConfig({ url: URL_, fetch })).resolves.toEqual({ cartoApiKey: '' });
  });

  it('returns no key for invalid JSON', async () => {
    const fetch = fakeFetch(() => new Response('<!doctype html>', { status: 200 }));
    await expect(loadRuntimeConfig({ url: URL_, fetch })).resolves.toEqual({ cartoApiKey: '' });
  });

  it('returns no key for an empty key', async () => {
    const fetch = fakeFetch(() => Response.json({ cartoApiKey: '' }));
    await expect(loadRuntimeConfig({ url: URL_, fetch })).resolves.toEqual({ cartoApiKey: '' });
  });

  it('returns no key when the request fails', async () => {
    const fetch = fakeFetch(() => Promise.reject(new TypeError('network')));
    await expect(loadRuntimeConfig({ url: URL_, fetch })).resolves.toEqual({ cartoApiKey: '' });
  });

  it('passes an abort on', async () => {
    const controller = new AbortController();
    controller.abort();
    const fetch = fakeFetch(() => Promise.reject(new DOMException('aborted', 'AbortError')));
    await expect(
      loadRuntimeConfig({ url: URL_, fetch, signal: controller.signal }),
    ).rejects.toThrow('aborted');
  });
});
