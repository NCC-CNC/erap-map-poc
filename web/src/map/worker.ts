import { setWorkerUrl } from 'maplibre-gl';
import workerUrl from 'maplibre-gl/dist/maplibre-gl-worker.mjs?url';

/**
 * Points MapLibre at its web worker before any map is created (#26).
 *
 * maplibre-gl builds the worker URL at runtime from `import.meta.url` and a
 * file name held in a variable, so Vite cannot see it and never emits the
 * worker into the build. The `?url` import makes Vite copy the
 * self-contained `maplibre-gl-worker.mjs` as is (a hashed file under
 * `assets/` in a build) and gives its URL, which `setWorkerUrl` hands to
 * MapLibre. Imported for its side effect by `createMap.ts`.
 */
setWorkerUrl(workerUrl);

export { workerUrl };
