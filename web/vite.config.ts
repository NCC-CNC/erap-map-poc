import { fileURLToPath } from 'node:url';
import react from '@vitejs/plugin-react';
import { loadEnv } from 'vite';
import { defineConfig } from 'vitest/config';
import { serveConfig } from './vite/serveConfig.ts';
import { serveTiles } from './vite/serveTiles.ts';

// Pipeline output, served at /tiles/ by `npm run dev` and `npm run preview`.
// In the deployed app nginx serves the same folder (see web/Dockerfile, #8).
const tilesDir =
  process.env.TILES_DIR ?? fileURLToPath(new URL('../data/tiles', import.meta.url));

// The repo root holds the git-ignored `.env` (see `.env.example`).
const repoRoot = fileURLToPath(new URL('..', import.meta.url));

export default defineConfig(({ mode }) => {
  // CARTO_API_KEY from the environment, or else from the repo root `.env`.
  // It is only served at /config.json by the dev and preview servers and is
  // never part of the build (ADR 0005).
  const { CARTO_API_KEY } = loadEnv(mode, repoRoot, 'CARTO_API_KEY');

  return {
    plugins: [react(), serveTiles(tilesDir), serveConfig(CARTO_API_KEY)],
    server: {
      // File events do not cross Windows bind mounts into a container, so
      // the web-dev compose service sets VITE_USE_POLLING=1.
      watch: { usePolling: process.env.VITE_USE_POLLING === '1' },
    },
    build: {
      // maplibre-gl alone is about 1 MB minified, so the default 500 kB warning
      // would always fire. Revisit if the app code itself grows large.
      chunkSizeWarningLimit: 1500,
    },
    test: {
      environment: 'node',
      include: ['src/**/*.test.ts', 'vite/**/*.test.ts'],
    },
  };
});
