import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { createServer, type Server } from 'node:http';
import type { AddressInfo } from 'node:net';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { parseRange, tilesMiddleware } from './serveTiles';

describe('parseRange', () => {
  it('returns null when there is no usable range', () => {
    expect(parseRange(undefined, 100)).toBeNull();
    expect(parseRange('bytes=-', 100)).toBeNull();
    expect(parseRange('bytes=0-1,5-6', 100)).toBeNull();
    expect(parseRange('items=0-1', 100)).toBeNull();
  });

  it('parses closed, open-ended and suffix ranges', () => {
    expect(parseRange('bytes=0-9', 100)).toEqual({ start: 0, end: 9 });
    expect(parseRange('bytes=90-', 100)).toEqual({ start: 90, end: 99 });
    expect(parseRange('bytes=-10', 100)).toEqual({ start: 90, end: 99 });
    expect(parseRange('bytes=-500', 100)).toEqual({ start: 0, end: 99 });
    expect(parseRange('bytes=50-500', 100)).toEqual({ start: 50, end: 99 });
  });

  it('flags ranges outside the file', () => {
    expect(parseRange('bytes=100-', 100)).toBe('unsatisfiable');
    expect(parseRange('bytes=9-3', 100)).toBe('unsatisfiable');
    expect(parseRange('bytes=-0', 100)).toBe('unsatisfiable');
  });
});

describe('tilesMiddleware', () => {
  let root: string;
  let dir: string;
  let server: Server;
  let base: string;

  beforeAll(async () => {
    root = mkdtempSync(path.join(tmpdir(), 'tiles-test-'));
    dir = path.join(root, 'tiles');
    mkdirSync(dir);
    writeFileSync(path.join(dir, 'sample.pmtiles'), '0123456789');
    writeFileSync(path.join(root, 'outside.txt'), 'secret');
    const middleware = tilesMiddleware(dir);
    server = createServer((req, res) =>
      middleware(req, res, () => {
        res.statusCode = 299;
        res.end('next');
      }),
    );
    await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
    base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  });

  afterAll(async () => {
    await new Promise((resolve) => server.close(resolve));
    rmSync(root, { recursive: true, force: true });
  });

  it('serves a byte range with 206 and the PMTiles content type', async () => {
    const res = await fetch(`${base}/tiles/sample.pmtiles`, { headers: { Range: 'bytes=2-5' } });
    expect(res.status).toBe(206);
    expect(res.headers.get('content-type')).toBe('application/vnd.pmtiles');
    expect(res.headers.get('content-range')).toBe('bytes 2-5/10');
    expect(await res.text()).toBe('2345');
  });

  it('serves the whole file without a range', async () => {
    const res = await fetch(`${base}/tiles/sample.pmtiles`);
    expect(res.status).toBe(200);
    expect(res.headers.get('accept-ranges')).toBe('bytes');
    expect(await res.text()).toBe('0123456789');
  });

  it('returns 404 for missing files instead of falling through', async () => {
    const res = await fetch(`${base}/tiles/missing.pmtiles`);
    expect(res.status).toBe(404);
  });

  it('does not serve files outside the tiles folder', async () => {
    const res = await fetch(`${base}/tiles/..%2Foutside.txt`);
    expect(res.status).toBe(404);
  });

  it('passes other paths to the next handler', async () => {
    const res = await fetch(`${base}/index.html`);
    expect(res.status).toBe(299);
  });
});
