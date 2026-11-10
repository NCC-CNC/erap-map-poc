import type { IncomingMessage, ServerResponse } from 'node:http';
import type { Plugin } from 'vite';

/** Path the app reads its runtime config from, matching nginx in production. */
export const CONFIG_PATH = '/config.json';

/**
 * Body of `/config.json` for a CARTO API key, or `null` when there is no
 * key, in which case the server answers 404 and the app falls back to the
 * keyless basemap, as it does in production with an empty key.
 */
export function runtimeConfigBody(cartoApiKey: string | undefined): string | null {
  const key = cartoApiKey?.trim();
  return key ? JSON.stringify({ cartoApiKey: key }) : null;
}

type Next = () => void;

/** Connect-style middleware that serves the runtime config at `/config.json`. */
export function configMiddleware(cartoApiKey: string | undefined) {
  const body = runtimeConfigBody(cartoApiKey);

  return (req: IncomingMessage, res: ServerResponse, next: Next): void => {
    const pathname = (req.url ?? '').split('?')[0] ?? '';
    if (pathname !== CONFIG_PATH) {
      next();
      return;
    }
    res.setHeader('Cache-Control', 'no-store');
    if (body === null) {
      res.statusCode = 404;
      res.setHeader('Content-Type', 'text/plain; charset=utf-8');
      res.end('Not Found');
      return;
    }
    res.statusCode = 200;
    res.setHeader('Content-Type', 'application/json');
    res.end(req.method === 'HEAD' ? undefined : body);
  };
}

/**
 * Vite plugin: serve `/config.json` in the dev and preview servers from the
 * CARTO API key of the dev process, so the CARTO basemaps can be tried
 * locally. In the deployed app nginx writes the same file (#8).
 */
export function serveConfig(cartoApiKey: string | undefined): Plugin {
  return {
    name: 'erap-serve-config',
    configureServer(server) {
      server.middlewares.use(configMiddleware(cartoApiKey));
    },
    configurePreviewServer(server) {
      server.middlewares.use(configMiddleware(cartoApiKey));
    },
  };
}
