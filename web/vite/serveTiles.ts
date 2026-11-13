import { createReadStream, stat } from 'node:fs';
import type { IncomingMessage, ServerResponse } from 'node:http';
import path from 'node:path';
import type { Plugin } from 'vite';

/** URL prefix the app requests tiles from, matching nginx in production. */
export const TILES_PREFIX = '/tiles/';

export interface ByteRange {
  start: number;
  end: number;
}

/**
 * Parses a single-range `Range` header against a file of `size` bytes.
 *
 * Returns `null` when the whole file should be sent (no header, or a form
 * this server does not support, such as multiple ranges, which RFC 9110
 * allows a server to ignore), `'unsatisfiable'` for a range outside the
 * file, or the inclusive byte range to send.
 */
export function parseRange(
  header: string | undefined,
  size: number,
): ByteRange | 'unsatisfiable' | null {
  if (!header) return null;
  const match = /^bytes=(\d*)-(\d*)$/.exec(header.trim());
  if (!match) return null;
  const [, startText = '', endText = ''] = match;
  if (startText === '' && endText === '') return null;

  if (startText === '') {
    // Suffix range: the last N bytes.
    const length = Number(endText);
    if (length === 0 || size === 0) return 'unsatisfiable';
    return { start: Math.max(0, size - length), end: size - 1 };
  }

  const start = Number(startText);
  const end = endText === '' ? size - 1 : Math.min(Number(endText), size - 1);
  if (start >= size || end < start) return 'unsatisfiable';
  return { start, end };
}

function contentType(file: string): string {
  switch (path.extname(file).toLowerCase()) {
    case '.pmtiles':
      return 'application/vnd.pmtiles';
    case '.tif':
      return 'image/tiff';
    case '.json':
      return 'application/json';
    default:
      return 'application/octet-stream';
  }
}

type Next = () => void;

/**
 * Connect-style middleware that serves files under `dir` at `/tiles/`, with
 * HTTP range support (PMTiles reads archives with range requests). Missing
 * files get a 404 rather than falling through to Vite's SPA fallback, so a
 * missing archive is reported as missing instead of returning index.html.
 */
export function tilesMiddleware(dir: string) {
  const root = path.resolve(dir);

  return (req: IncomingMessage, res: ServerResponse, next: Next): void => {
    const pathname = (req.url ?? '').split('?')[0] ?? '';
    if (!pathname.startsWith(TILES_PREFIX)) {
      next();
      return;
    }

    const send = (status: number, message: string) => {
      res.statusCode = status;
      res.setHeader('Content-Type', 'text/plain; charset=utf-8');
      res.end(message);
    };

    if (req.method !== 'GET' && req.method !== 'HEAD') {
      res.setHeader('Allow', 'GET, HEAD');
      send(405, 'Method Not Allowed');
      return;
    }

    let relative: string;
    try {
      relative = decodeURIComponent(pathname.slice(TILES_PREFIX.length));
    } catch {
      send(400, 'Bad Request');
      return;
    }
    const file = path.resolve(root, relative);
    if (!file.startsWith(root + path.sep)) {
      send(404, 'Not Found');
      return;
    }

    stat(file, (err, stats) => {
      if (err || !stats.isFile()) {
        send(404, 'Not Found');
        return;
      }

      res.setHeader('Accept-Ranges', 'bytes');
      res.setHeader('Content-Type', contentType(file));
      res.setHeader('Cache-Control', 'no-cache');

      const range = parseRange(req.headers.range, stats.size);
      if (range === 'unsatisfiable') {
        res.setHeader('Content-Range', `bytes */${stats.size}`);
        send(416, 'Range Not Satisfiable');
        return;
      }

      const { start, end } = range ?? { start: 0, end: stats.size - 1 };
      res.statusCode = range ? 206 : 200;
      if (range) res.setHeader('Content-Range', `bytes ${start}-${end}/${stats.size}`);
      res.setHeader('Content-Length', String(Math.max(0, end - start + 1)));

      if (req.method === 'HEAD' || stats.size === 0) {
        res.end();
        return;
      }
      createReadStream(file, { start, end })
        .on('error', () => res.destroy())
        .pipe(res);
    });
  };
}

/**
 * Vite plugin: serve pipeline output (`data/tiles/`) at `/tiles/` in the dev
 * and preview servers, so the app can be run against real PMTiles locally.
 */
export function serveTiles(dir: string): Plugin {
  return {
    name: 'erap-serve-tiles',
    configureServer(server) {
      server.middlewares.use(tilesMiddleware(dir));
    },
    configurePreviewServer(server) {
      server.middlewares.use(tilesMiddleware(dir));
    },
  };
}
