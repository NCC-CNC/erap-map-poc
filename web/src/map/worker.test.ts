import { afterEach, describe, expect, it, vi } from 'vitest';

const { setWorkerUrl } = vi.hoisted(() => ({ setWorkerUrl: vi.fn() }));
vi.mock('maplibre-gl', () => ({ setWorkerUrl }));

afterEach(() => {
  vi.resetModules();
  setWorkerUrl.mockClear();
});

describe('worker', () => {
  it('sets the MapLibre worker URL to the bundled worker on import', async () => {
    const { workerUrl } = await import('./worker');
    expect(setWorkerUrl).toHaveBeenCalledTimes(1);
    expect(setWorkerUrl).toHaveBeenCalledWith(workerUrl);
    expect(workerUrl).toMatch(/maplibre-gl-worker.*\.mjs/);
  });
});
