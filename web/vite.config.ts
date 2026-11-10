import { fileURLToPath } from 'node:url';
import react from '@vitejs/plugin-react';
import { defineConfig } from 'vitest/config';
import { serveTiles } from './vite/serveTiles.ts';

// Pipeline output, served at /tiles/ by `npm run dev` and `npm run preview`.
// In the deployed app nginx serves the same folder (see web/Dockerfile, #8).
const tilesDir =
  process.env.TILES_DIR ?? fileURLToPath(new URL('../data/tiles', import.meta.url));

export default defineConfig({
  plugins: [react(), serveTiles(tilesDir)],
  build: {
    // maplibre-gl alone is about 1 MB minified, so the default 500 kB warning
    // would always fire. Revisit if the app code itself grows large.
    chunkSizeWarningLimit: 1500,
  },
  test: {
    environment: 'node',
    include: ['src/**/*.test.ts', 'vite/**/*.test.ts'],
  },
});
