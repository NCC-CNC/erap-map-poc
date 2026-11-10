import { createServer, type Server } from 'node:http';
import type { AddressInfo } from 'node:net';
import { afterEach, describe, expect, it } from 'vitest';
import { configMiddleware, runtimeConfigBody } from './serveConfig';

describe('runtimeConfigBody', () => {
  it('returns the key as JSON', () => {
    expect(runtimeConfigBody('abc')).toBe('{"cartoApiKey":"abc"}');
  });

  it('returns null without a key', () => {
    expect(runtimeConfigBody(undefined)).toBeNull();
    expect(runtimeConfigBody('')).toBeNull();
    expect(runtimeConfigBody('  ')).toBeNull();
  });
});

describe('configMiddleware', () => {
  let server: Server | undefined;

  async function start(key: string | undefined): Promise<string> {
    const middleware = configMiddleware(key);
    server = createServer((req, res) =>
      middleware(req, res, () => {
        res.statusCode = 299;
        res.end('next');
      }),
    );
    await new Promise<void>((resolve) => server?.listen(0, '127.0.0.1', resolve));
    return `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  }

  afterEach(async () => {
    await new Promise((resolve) => server?.close(resolve));
    server = undefined;
  });

  it('serves the key at /config.json', async () => {
    const base = await start('abc');
    const res = await fetch(`${base}/config.json?t=1`);
    expect(res.status).toBe(200);
    expect(res.headers.get('content-type')).toBe('application/json');
    expect(res.headers.get('cache-control')).toBe('no-store');
    expect(await res.json()).toEqual({ cartoApiKey: 'abc' });
  });

  it('answers 404 without a key instead of falling through', async () => {
    const base = await start(undefined);
    const res = await fetch(`${base}/config.json`);
    expect(res.status).toBe(404);
  });

  it('passes other paths to the next handler', async () => {
    const base = await start('abc');
    const res = await fetch(`${base}/index.html`);
    expect(res.status).toBe(299);
  });
});
